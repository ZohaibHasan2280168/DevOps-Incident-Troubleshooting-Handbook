# 🚨 INC-008: HTTP 502 Bad Gateway & 504 Gateway Timeout in Reverse Proxy Upstream

| Metadata | Details |
| :--- | :--- |
| **Incident ID** | INC-008 |
| **Severity** | P1 (Total Service Degradation / Ingress Failure) |
| **Subsystems** | Nginx Reverse Proxy, AWS ALB, FastAPI / Uvicorn Upstream Workers, Linux Sockets |
| **Branch Reference** | `incident-08/http-502-504-bad-gateway` |
| **Resolution Status** | 🟢 Resolved |

---

## 1. 🔍 Incident Summary & Symptoms

During a high-concurrency document ingestion window on the production cluster, external users communicating with the public API gateway began encountering intermittent **HTTP 502 Bad Gateway** and **HTTP 504 Gateway Timeout** errors.

Public ingress telemetry showed that while the Nginx edge reverse proxy remained active on ports 80/443, downstream client requests were abruptly aborted before receiving valid application payloads.

### User & Client Symptoms:
Engineers probing the public entrypoints observed two distinct failure modes:

```bash
# Failure Mode A: Instantaneous 502 Error (< 15ms)
$ curl -i http://api.smartdoc.io/api/v1/documents/process
HTTP/1.1 502 Bad Gateway
Server: nginx/1.24.0
Date: Wed, 08 Oct 2026 17:15:20 GMT
Content-Type: text/html
Content-Length: 157
Connection: keep-alive

<html>
<head><title>502 Bad Gateway</title></head>
<body>
<center><h1>502 Bad Gateway</h1></center>
<hr><center>nginx/1.24.0</center>
</body>
</html>

# Failure Mode B: Silent Stall followed by 504 Error exactly 60 seconds later
$ curl -i http://api.smartdoc.io/api/v1/analytics
# ... [60.00 seconds hanging] ...
HTTP/1.1 504 Gateway Time-out
Server: nginx/1.24.0
Date: Wed, 08 Oct 2026 17:15:45 GMT
Content-Type: text/html
Content-Length: 169
Connection: keep-alive

<html>
<head><title>504 Gateway Time-out</title></head>
<body>
<center><h1>504 Gateway Time-out</h1></center>
<hr><center>nginx/1.24.0</center>
</body>
</html>
```

Simultaneously, AWS CloudWatch metrics for the Application Load Balancer recorded sudden spikes in `HTTPCode_Target_5XX_Count` alongside elevated `TargetResponseTime` percentiles.

---

## 2. 🧠 Root Cause Analysis (RCA)

### Understanding the Proxy-to-Upstream Lifecycle

To understand the breakdown, we must analyze the exact boundary between the **Reverse Proxy (Nginx/ALB)** and the **Upstream Backend (Uvicorn/FastAPI)**:

```
[ Client ] ──(HTTP)──► [ Nginx / ALB (Gateway) ] ──(Proxy Pass)──► [ FastAPI Backend (Upstream) ]
                                  │
                                  ├─► TCP Connect Fails (Port closed / Process dead) ──► 💥 502 Bad Gateway
                                  └─► TCP Connect OK, but App takes > 60s to reply   ──► 💥 504 Gateway Timeout
```

### Deep-Dive Failure Mechanisms:

#### Failure Mode A: The 502 Root Trigger (Connection Refused & TCP RST)
* **Single-Worker Bottleneck:** The backend container was running Uvicorn with a single worker process (`--workers 1`).
* Under heavy concurrent document parsing, an unhandled native memory exception caused the single Python process to terminate abruptly.
* When Nginx attempted to initiate a TCP 3-way handshake (`SYN`) to `172.17.0.3:8000`, the destination port was closed.
* The Linux kernel network stack immediately responded with a `TCP RST` packet (`111: Connection refused`):

```text
Nginx (Proxy)                Linux Kernel (Backend Namespace)
    │                                    │
    │ ─── TCP SYN (Port 8000) ─────────► │ (No process listening!)
    │ ◄── TCP RST / ACK (Refused) ────── │
    ▼
Nginx generates HTTP 502 Bad Gateway immediately!
```

#### Failure Mode B: The 504 Root Trigger (Gateway Timeout & Thread Exhaustion)
* **Synchronous Query Execution:** A complex analytics report endpoint (`/api/v1/analytics`) triggered an unindexed multi-table join and document vector calculation in PostgreSQL that took **75 seconds** to complete.
* **Proxy Read Timeout Exceeded:** Nginx maintains a default directive: `proxy_read_timeout 60s;`.
* The TCP handshake succeeded, and Nginx forwarded the HTTP request. However, after waiting exactly 60,000 milliseconds without receiving the HTTP response headers from FastAPI, Nginx closed the client socket and issued an internal **HTTP 504 Gateway Timeout**:

```text
Nginx (Proxy)                      FastAPI Backend
    │                                     │
    │ ─── TCP SYN ──────────────────────► │ (Handshake OK)
    │ ◄── TCP SYN-ACK ─────────────────── │
    │ ─── POST /api/v1/analytics ───────► │ (Starts 75s computation...)
    │                                     │
    │ ... [Waiting 60 seconds] ...        │ (Still busy calculating...)
    ▼                                     │
[ proxy_read_timeout 60s expires! ]       │
    │ ─── TCP FIN/RST ──────────────────► │ (Terminates connection)
    ▼
Nginx returns HTTP 504 Gateway Timeout to Client!
```

---

## 3. 🔬 SRE Diagnostic Triage Tree

### Step 1: Differentiate Connect vs Read Timeouts with `curl`
Execute a formatted `curl` request to isolate whether latency occurs during the TCP handshake (`time_connect`) or during response generation (`time_starttransfer` / TTFB):

```bash
curl -w "Connect: %{time_connect}s | TTFB: %{time_starttransfer}s | Total: %{time_total}s | Status: %{http_code}\n" \
  -o /dev/null -s "http://localhost/api/v1/documents/process"
```

#### Diagnostic Output Signatures:
```text
# Signature 1: 502 Bad Gateway (Instant failure at socket level)
Connect: 0.000s | TTFB: 0.002s | Total: 0.002s | Status: 502

# Signature 2: 504 Gateway Timeout (Failure after prolonged hang)
Connect: 0.001s | TTFB: 60.002s | Total: 60.003s | Status: 504
```

---

### Step 2: Inspect Nginx Error Log Signatures
Examine the Nginx error log to extract the exact POSIX error code:

```bash
sudo tail -n 20 /var/log/nginx/error.log
```

#### Observed Output:
```log
2026/10/08 17:15:20 [error] 1422#1422: *892 connect() failed (111: Connection refused) while connecting to upstream, client: 198.51.100.42, server: api.smartdoc.io, request: "POST /api/v1/documents/process HTTP/1.1", upstream: "http://172.17.0.3:8000/api/v1/documents/process"
2026/10/08 17:15:45 [error] 1422#1422: *895 upstream timed out (110: Connection timed out) while reading response header from upstream, client: 198.51.100.42, server: api.smartdoc.io, request: "GET /api/v1/analytics HTTP/1.1", upstream: "http://172.17.0.3:8000/api/v1/analytics"
```
* `111: Connection refused` ➔ Backend process is down, crashed, or bound to the wrong IP (e.g. `127.0.0.1` inside container).
* `110: Connection timed out` ➔ Backend accepted connection but stalled exceeding `proxy_read_timeout`.

---

### Step 3: Inspect Backend Process Concurrency & Socket State
Check whether the backend is bound to `0.0.0.0` and how many worker processes exist:

```bash
# Check running processes inside the backend container
docker top smartdoc-backend

# Check host socket listening status
ss -tulpn | grep 8000
```

#### Observed Output:
```text
UID   PID     PPID    C  STIME TTY   TIME     CMD
root  18420   18400   0  17:00 ?     00:00:01 uvicorn app.main:app --host 0.0.0.0 --port 8000
# Smoking Gun: Only 1 single worker PID exists! A single CPU-bound task blocks the entire server.
```

---

## 4. 🛠️ The Production Fix & Remediation Runbook

### Step 1: Scale Uvicorn Process Workers
Never run a single Uvicorn worker in production. Multi-worker processes allow concurrent request handling even if one worker is busy or restarting:

Update the container startup command in Dockerfile or Docker Compose:

```dockerfile
# Multi-worker Uvicorn startup with keep-alive alignment
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "4", "--timeout-keep-alive", "75"]
```

* `--workers 4`: Spawns 4 independent OS worker processes managed by Uvicorn master.
* `--timeout-keep-alive 75`: Set slightly higher than Nginx/ALB idle timeout (60s) to prevent race-condition connection closures.

---

### Step 2: Harden Nginx Reverse Proxy Configuration
Apply the hardened production configuration in [`nginx.fixed.conf`](./nginx.fixed.conf):

```nginx
# /etc/nginx/conf.d/smartdoc.conf

upstream smartdoc_backend_cluster {
    server smartdoc-backend-1:8000 max_fails=3 fail_timeout=10s;
    server smartdoc-backend-2:8000 max_fails=3 fail_timeout=10s;

    # Persistent connection pool to upstream
    keepalive 32;
}

server {
    listen 80;
    server_name api.smartdoc.io;

    location /api/ {
        proxy_pass http://smartdoc_backend_cluster;
        proxy_http_version 1.1;
        proxy_set_header Connection ""; # Required for HTTP/1.1 keepalive
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # ----------------------------------------------------------------------
        # Timeout Hardening
        # ----------------------------------------------------------------------
        proxy_connect_timeout 5s;   # Fail fast on dead upstream
        proxy_read_timeout    120s; # Generous read window for heavy document analytics
        proxy_send_timeout    120s;

        # ----------------------------------------------------------------------
        # Self-Healing Automatic Failover
        # ----------------------------------------------------------------------
        # If one replica crashes (502) or hangs (504), immediately retry alternate replica
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 10s;
    }
}
```

---

### Step 3: Test and Gracefully Reload Nginx
```bash
# 1. Validate Nginx syntax
sudo nginx -t

# 2. Perform zero-downtime graceful configuration reload
sudo nginx -s reload
```

---

## 5. 🧪 Automated Verification & Health Probe

### 1. Verify HTTP 200 OK Response
```bash
curl -I -s http://localhost/api/v1/health | head -n 1
```
**Expected Output:**
```text
HTTP/1.1 200 OK
```

### 2. High-Concurrency Upstream Load Benchmark
Simulate concurrent requests to verify zero 502/504 errors:

```bash
for i in {1..20}; do 
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost/api/v1/health; 
done | sort | uniq -c
```

**Expected Output:**
```text
     20 200
```
*(Zero 502 Bad Gateway and zero 504 Gateway Timeout errors detected!)*

---

## 6. 🛡️ Prevention & Production Best Practices

1. **Keepalive Timeout Hierarchy:** Ensure upstream backend keepalive timeout (`--timeout-keep-alive 75`) is strictly greater than the reverse proxy / ALB idle timeout (`60s`). If the backend closes the connection first, Nginx may send a request across a half-closed socket, generating a 502.
2. **Asynchronous Task Offloading:** Never execute long-running computations (OCR, AI embeddings, heavy reports) synchronously in an HTTP request. Return an immediate `HTTP 202 Accepted` with a task ID and offload execution to Celery/Redis Queue.
3. **Active Health Checks & Circuit Breakers:** Configure Nginx/ALB to remove unhealthy backend targets within 5 seconds of failure using `max_fails` and `fail_timeout`.
