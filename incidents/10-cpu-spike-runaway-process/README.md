# 🚨 INC-010: Host 100% CPU Saturation & Runaway Worker Thread Throttling

| Metadata | Details |
| :--- | :--- |
| **Incident ID** | INC-010 |
| **Severity** | P1 (Host Unresponsiveness / Request Queue Backlog) |
| **Subsystems** | Linux Kernel Scheduler (CFS), cgroups v2, Python Uvicorn / AsyncIO Workers, PostgreSQL |
| **Branch Reference** | `incident-10/cpu-spike-runaway-process` |
| **Resolution Status** | 🟢 Resolved |

---

## 1. 🔍 Incident Summary & Symptoms

AWS CloudWatch alarms triggered for the production EC2 cluster after average host CPU utilization surged to **100%** and remained pinned at maximum capacity for over 20 consecutive minutes.

Platform symptoms included:
* **Severe API Latency Degradation:** Public API response latencies skyrocketed from **80ms to over 14,000ms (14s)**.
* **Terminal Lag & SSH Drops:** Operations engineers attempting to SSH into the host experienced severe terminal latency, dropped keystrokes, and connection timeouts.
* **Cascading Healthcheck Failures:** Container orchestration and reverse proxy healthcheck probes timed out, triggering erroneous container restarts and compounding the service degradation.

### Terminal & Metric Evidence:
Executing `uptime` on the troubled host revealed an alarming Linux Load Average:

```bash
$ uptime
 17:30:12 up 14 days,  3:12,  2 users,  load average: 9.84, 8.92, 7.15
```

> **Understanding Load Average on a 2-vCPU Host:** In Linux, Load Average represents the average number of threads in the `R` (Running) and `D` (Uninterruptible Sleep / Disk I/O) states. On a 2-core host, a load average of `9.84` indicates that nearly **8 runnable processes were permanently queued waiting for CPU execution time slices on every scheduler tick!**

Probing the application health endpoint demonstrated extreme degradation:

```bash
$ curl -w "Time: %{time_total}s | Status: %{http_code}\n" -o /dev/null -s http://localhost:8000/api/v1/healthz
Time: 14.215s | Status: 200
```

---

## 2. 🧠 Root Cause Analysis (RCA)

Our investigation identified three compounding factors that starved the host of CPU cycles:

```
[ Inbound HTTP Traffic ] ──► [ Uvicorn Main Thread (Single-Threaded AsyncIO Event Loop) ]
                                            │
                                            ▼ 💥 BLOCKING EXECUTION (CPU Bound)
                             [ Synchronous Regex & PDF Tokenizer ] 
                                            │
                      (Event Loop Froze for 8-12 seconds per request!)
                                            │
             ┌──────────────────────────────┴──────────────────────────────┐
             ▼                                                             ▼
[ Docker Container (No CPU Quota) ]                       [ PostgreSQL Full Table Scan ]
 100% Host CPU Consumption                                ILIKE '%pattern%' on 500k Rows
 Starved dockerd, sshd, and OS Daemons                   Pinned DB CPU Worker Cores
```

---

### Deep-Dive Failure Mechanisms:

#### 1. Blocking Synchronous CPU Operations in AsyncIO Event Loop
* FastAPI and Uvicorn rely on a single-threaded asynchronous event loop (`asyncio` / `uvloop`).
* A newly deployed document processing endpoint (`/api/v1/documents/parse`) was implemented as:
  ```python
  @router.post("/parse")
  async def parse_document(file: UploadFile):
      # Synchronous CPU-bound parsing running directly on the event loop thread!
      text = extract_and_regex_clean_pdf(file.file.read())
      return {"text": text}
  ```
* Because CPU computation cannot cooperatively yield control via `await`, the entire Python main thread was locked executing regex computations for 8–12 seconds per document.
* While the thread was locked, the event loop could not process socket I/O, accept new TCP handshakes, or respond to `/healthz` endpoints.
* Unprocessed requests filled the Linux socket listen backlog (`somaxconn`), causing reverse proxies (Nginx/ALB) to time out and clients to aggressively retry, creating a **thundering herd avalanche**.

---

#### 2. Absence of Container cgroup CPU Bandwidth Quotas
* Docker containers were launched without `--cpus` or `cpu_quota` limits.
* When multiple concurrent file parsing requests were processed across multi-worker setups, the worker processes consumed 100% of all vCPU cores available on the physical virtual machine.
* Crucial Linux host operating system daemons (`sshd`, `dockerd`, `systemd-journald`, and monitoring agents) were starved of CPU scheduling slices.

---

#### 3. Unindexed PostgreSQL Sequential Table Scans
* Concurrently, a background analytics job executed:
  ```sql
  SELECT * FROM document_chunks WHERE chunk_text ILIKE '%quarterly_revenue%';
  ```
* Without a trigram or full-text GIN index, PostgreSQL initiated a sequential scan across 500,000+ text rows, spinning database worker processes to 100% CPU and creating lock contention.

---

## 3. 🔬 SRE Diagnostic Triage Tree

### Step 1: Thread-Level CPU Profiling (`top -H` and `pidstat`)
Identify whether CPU is consumed by multiple threads or a single runaway thread:

```bash
# Sample user vs system CPU consumption per thread every 1 second
pidstat -u -t -p $(pgrep -f uvicorn | head -n 1) 1 3
```

#### Observed Output:
```text
Linux 6.8.0-aws (ip-10-0-1-45)    10/08/2026      _x86_64_        (2 CPU)

17:32:01      UID      TGID       TID    %usr %system  %guest   %wait    %CPU   CPU  Command
17:32:02     1000     28419         -   99.80    0.20    0.00    0.00  100.00     0  uvicorn
17:32:02     1000         -     28419   99.80    0.20    0.00    0.00  100.00     0  |__uvicorn
```
* **Findings:** `%usr` was 99.8% and `%system` was 0.2%. This proved the CPU spike was driven entirely by user-space algorithmic computation (not kernel lock contention or excessive system calls).

---

### Step 2: System Call Tracing via `strace`
Verify whether the runaway process is issuing system calls or locked in user-space execution:

```bash
sudo strace -c -p 28419
```

#### Observed Output:
```text
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
  0.00    0.000000           0         0           [no syscalls recorded]
------ ----------- ----------- --------- --------- ----------------
100.00    0.000000                     0           total
```
* **Analysis:** During a 5-second capture window, `strace` recorded **0 system calls**. The process was trapped in pure Python bytecode execution (regex backtracking loops).

---

### Step 3: Zero-Overhead Python Stack Profiling via `py-spy`
Sample the live Python call stack without stopping or restarting the running container:

```bash
sudo py-spy dump --pid 28419
```

#### Observed Output:
```text
Thread 0x7f9a12b4: (active)
    re.findall (re.py:240)
    clean_text (app/services/parser.py:84)
    extract_and_regex_clean_pdf (app/services/parser.py:112)
    parse_document (app/api/v1/endpoints.py:45)
    run_endpoint_function (starlette/routing.py:42)
    app (fastapi/applications.py:1054)
```
* **Smoking Gun:** The stack dump pinpointed line 84 in `app/services/parser.py` (`re.findall`) as the exact bottleneck locking the main event loop thread!

---

### Step 4: Identify Active PostgreSQL Long-Running Scans
Inspect database query execution states:

```sql
SELECT pid, now() - query_start AS duration, query, state 
FROM pg_stat_activity 
WHERE state = 'active' AND (now() - query_start) > interval '5 seconds'
ORDER BY duration DESC;
```

#### Observed Output:
```text
  pid  |    duration     |                                query                                 | state  
-------+-----------------+----------------------------------------------------------------------+--------
 14820 | 00:01:14.281902 | SELECT * FROM document_chunks WHERE chunk_text ILIKE '%revenue%'     | active
```

---

## 4. 🛠️ The Production Fix & Remediation Runbook

### Step 1: Enforce cgroup CPU Quotas (`docker-compose.yml`)
Restrict container CPU consumption to prevent any individual container from starving the host OS:

```yaml
# docker-compose.yml
version: '3.8'

services:
  smartdoc-backend:
    image: smartdoc-backend:latest
    deploy:
      resources:
        limits:
          # On a 2-vCPU node, cap container at 1.5 cores (75% host max)
          # Linux Completely Fair Scheduler (CFS) enforces bandwidth quota,
          # leaving 0.5 cores permanently guaranteed for SSH, dockerd, and host daemons.
          cpus: '1.50'
          memory: 2048M
        reservations:
          cpus: '0.50'
          memory: 512M
```

> **Kubernetes Equivalent:** Set `resources.limits.cpu: "1500m"` and `resources.requests.cpu: "500m"`.

---

### Step 2: Offload CPU-Intensive Tasks to Thread Pool / Worker Queue
Refactor the FastAPI route to ensure CPU-bound parsing never blocks the main AsyncIO event loop:

```python
# app/api/v1/endpoints.py
from fastapi import APIRouter, UploadFile
from fastapi.concurrency import run_in_threadpool
from app.services.parser import extract_and_regex_clean_pdf

router = APIRouter()

@router.post("/parse")
async def parse_document(file: UploadFile):
    file_bytes = await file.read()
    
    # FIX: Offload CPU-heavy computation to Starlette's AnyIO worker thread pool.
    # The main asyncio event loop immediately resumes servicing other HTTP requests!
    cleaned_text = await run_in_threadpool(extract_and_regex_clean_pdf, file_bytes)
    
    return {"status": "success", "text": cleaned_text}
```

For long-running tasks (>2 seconds), offload execution asynchronously to a dedicated Celery / Redis background worker queue.

---

### Step 3: Optimize Regex Patterns & Add Trigram Database Index
1. **Fix Catastrophic Regex Backtracking:** Replaced polynomial nested quantifiers with atomic groups / non-capturing pre-compiled patterns (`re.compile(r'...')`).
2. **PostgreSQL Trigram Index:**
   ```sql
   CREATE EXTENSION IF NOT EXISTS pg_trgm;
   CREATE INDEX CONCURRENTLY idx_document_chunks_content_trgm 
   ON document_chunks USING gin (chunk_text gin_trgm_ops);
   ```

---

## 5. 🧪 Automated Verification & Health Probe

### 1. Concurrency Benchmark Under Heavy Load
Execute benchmark requests using `wrk` to simulate heavy concurrent file submissions:

```bash
wrk -t4 -c50 -d30s http://localhost:8000/api/v1/healthz
```

#### Expected Output:
```text
Running 30s test @ http://localhost:8000/api/v1/healthz
  4 threads and 50 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     4.12ms    1.85ms  24.10ms   82.14%
    Req/Sec     1.21k   142.10     1.50k    74.50%
  144210 requests in 30.05s, 22.42MB read
Requests/sec:   4798.24
Transfer/sec:    764.12KB
```

### 2. Verify Linux Load Average & CPU Utilization
```bash
$ uptime
 17:45:10 up 14 days,  3:27,  2 users,  load average: 1.42, 1.65, 1.80

$ mpstat 1 3
Average:     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
Average:     all   68.50    0.00    6.20    0.10    0.00    0.20    0.00    0.00    0.00   25.00
```
* **Telemetric Confirmation:** 
  - Host CPU strictly capped at **75%** (leaving 25% idle capacity for host OS and SSH).
  - Load average dropped from **9.84 down to 1.42**.
  - Health check endpoint `/healthz` latency stabilized at **4.12ms**!

---

## 6. 🛡️ Prevention & Production Best Practices

1. **Mandatory cgroup Limits:** Never deploy containers to production without explicit CPU and Memory resource limits (`limits.cpu`, `limits.memory`).
2. **Asynchronous Architecture Guardrails:** Use Python static analysis rules (e.g. `flake8-async`) and code reviews to strictly prohibit blocking CPU routines inside `async def` route handlers.
3. **CFS Throttling Telemetry:** Alert on Prometheus metric `container_cpu_cfs_throttled_periods_total`. If throttling exceeds 15% of periods, scale replicas horizontally.
4. **Database Indexing Gates:** Ensure all `LIKE` or `ILIKE` queries against text columns in production databases have supporting GIN trigram indexes.
