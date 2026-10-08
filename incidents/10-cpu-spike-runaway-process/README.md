# 🚨 INC-010: Host 100% CPU Saturation & Runaway Worker Thread Throttling

| Metadata | Details |
| :--- | :--- |
| **Incident ID** | INC-010 |
| **Severity** | P1 (Host Unresponsiveness / Request Queue Backlog) |
| **Subsystems** | Linux Kernel Scheduler, CPU cgroups, Python Uvicorn / AsyncIO Workers |
| **Branch Reference** | `incident-10/cpu-spike-runaway-process` |
| **Resolution Status** | 🟡 OPEN / UNDER ACTIVE TRIAGE |

---

## 1. 🔍 Incident Summary & Symptoms

AWS CloudWatch alarms triggered for the production EC2 cluster after average CPU utilization surged to **100%** and remained pinned at maximum capacity for over 20 consecutive minutes.

Platform symptoms include:
* API response latencies spiking from **80ms to over 14,000ms (14s)**.
* SSH sessions to the EC2 host experiencing severe terminal lag and dropped keystrokes.
* Healthcheck probes failing across all microservice containers due to CPU starvation.

Executing `uptime` and `top` reveals an alarming Linux Load Average:

```bash
$ uptime
 17:30:12 up 14 days,  3:12,  2 users,  load average: 9.84, 8.92, 7.15
# (On a 2-vCPU machine, load average of 9.84 indicates 8 processes permanently queued for CPU execution!)
```

---

## 2. 🧠 Hypothesized Root Causes (Under Investigation)

1. **CPU Intensive Synchronous Processing in Async Loop:** A CPU-bound document regex parsing operation running inside FastAPI's main `asyncio` event loop without offloading to a thread pool executor, starving the event loop.
2. **Missing Database Table Indexes (Sequential Scan):** A complex analytics query performing full-table sequential scans on 500,000+ document chunks, driving PostgreSQL CPU to 100%.
3. **Absence of Container CPU Quotas:** Lack of Docker `--cpus` limits allowing a single rogue worker thread to consume 100% of all available host CPU cores.

---

## 3. 🔬 Active Triage Plan

- [ ] Profile top CPU-consuming thread PIDs using `top -H` and `pidstat -u 1 5`.
- [ ] Trace system calls of rogue processes using `strace -p <PID> -c`.
- [ ] Enforce CPU bandwidth quotas using Linux cgroups (`--cpus="1.5"` or Kubernetes `resources.limits.cpu`).
- [ ] Offload blocking CPU-heavy tasks to background Celery / Redis worker queues.

*(Full root cause analysis and verified remediation scripts will be finalized upon resolution).*
