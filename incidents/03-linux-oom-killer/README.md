# 🚨 INC-003: Linux Kernel OOM Killer & Container Silent Crash (Exit Code 137)

| Metadata | Details |
| :--- | :--- |
| **Incident ID** | INC-003 |
| **Severity** | P1 (Container Termination / Service Outage) |
| **Subsystems** | Linux Kernel (`cgroups`, `vm.oom_kill`), Docker Engine, FastAPI, EC2 |
| **Branch Reference** | `incident-03/linux-oom-killer` |
| **Resolution Status** | 🟢 Resolved |

---

## 1. 🔍 Incident Summary & Symptoms

During peak workload (such as processing large PDF document embeddings or heavy concurrent API traffic) on an AWS EC2 instance (`t3.micro`/`t3.small`), the `smartdoc-backend` container suddenly vanished from running processes.

Operators checking `docker ps` observed that the container had terminated abruptly:

```bash
$ docker ps -a
CONTAINER ID   IMAGE              COMMAND                  CREATED         STATUS                       PORTS     NAMES
a1b2c3d4e5f6   smartdoc-backend   "uvicorn app.main:ap…"   2 hours ago     Exited (137) 12 seconds ago            smartdoc-backend
```

Crucially, inspecting standard application logs yielded zero clues:
```bash
$ docker logs --tail 50 smartdoc-backend
INFO:     172.17.0.1:48210 - "POST /api/v1/documents/process HTTP/1.1" 200 OK
INFO:     [FastAPI] Ingesting multi-page PDF document...
# <No traceback! No Python unhandled exception! Process vanished.>
```

---

## 2. 🧠 Root Cause Analysis (RCA)

### Understanding Linux Exit Code 137
In POSIX operating systems, when a process is killed by an external operating system signal, its exit code follows the formula:
$$\text{Exit Code} = 128 + \text{Signal Number}$$

Exit Code **137** translates directly to:
$$137 - 128 = 9 \implies \text{SIGKILL}$$

`SIGKILL` (Signal 9) cannot be caught, handled, or logged by the application runtime (Python/Node.js). The process is instantly wiped from memory by the Linux kernel.

### The Out-Of-Memory (OOM) Killer Mechanism
1. **Unbounded Container Memory**: By default, Docker containers run without memory constraints (`--memory` flag not specified). They are free to consume 100% of the host system's physical RAM.
2. **Exhaustion of Host Memory**: When concurrent document ingestion spiked RAM consumption to 100%, the host had zero swap space allocated.
3. **Kernel Protection**: To prevent the entire Linux operating system from kernel-panicking, the Linux kernel's **OOM Killer** (`vm.oom_kill`) was invoked.
4. The kernel examined all processes, calculated their `oom_score`, selected the containerized Python process with the highest memory footprint, and dispatched an unblockable `SIGKILL`.

```
[ Application Process ] ---> Allocates 900MB RAM ---> [ EC2 1GB RAM Full ]
                                                             |
                                                             v
[ Linux Kernel OOM Killer ] ======================> Sends SIGKILL (Signal 9)
                                                             |
                                                             v
[ Container State ] <------------------------------- Process Exits (Code 137)
```

---

## 3. 🔬 Forensics: Verifying Kernel OOM Events

To prove that the container was indeed terminated by the kernel rather than internal application logic:

### 1. Inspect Docker Container Metadata
```bash
docker inspect smartdoc-backend --format 'OOMKilled: {{.State.OOMKilled}}, ExitCode: {{.State.ExitCode}}'
```
**Output:**
```
OOMKilled: true, ExitCode: 137
```

### 2. Inspect Linux Kernel Ring Buffer (`dmesg`)
```bash
sudo dmesg -T | grep -i -E "oom|killed process"
```
**Output:**
```
[Tue Oct 06 14:15:22 2026] Out of memory: Killed process 28419 (uvicorn) total-vm:1042816kB, anon-rss:812404kB, file-rss:0kB, shmem-rss:0kB, UID:0 pgtables:1724kB oom_score_adj:0
[Tue Oct 06 14:15:22 2026] oom_reaper: reaped process 28419 (uvicorn), now anon-rss:0kB, file-rss:0kB, shmem-rss:0kB
```

---

## 4. 🛠️ The Production Fix & Remediation Runbook

### Step 1: Provision a 1GB/2GB Linux Swap Space Buffer
EC2 instances often launch without swap. Creating a virtual swap space prevents sudden kernel panics during momentary traffic spikes:

```bash
# Allocate 1GB swapfile
sudo fallocate -l 1G /swapfile

# Secure file permissions (owner read/write only)
sudo chmod 600 /swapfile

# Format as swap area
sudo mkswap /swapfile

# Activate swap
sudo swapon /swapfile

# Persist swap across server reboots in /etc/fstab
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Verify allocation
free -h
```

### Step 2: Enforce Hard & Soft Container Memory Boundaries
Never run production containers without resource constraints. Re-launch the container with explicit memory boundaries:

```bash
docker run -d \
  --name smartdoc-backend \
  --network smartdoc-net \
  --memory=512m \
  --memory-swap=1g \
  --memory-reservation=256m \
  -p 8000:8000 \
  --restart on-failure:5 \
  479537131188.dkr.ecr.us-east-1.amazonaws.com/smartdoc-backend:latest
```

* `--memory=512m`: Hard physical RAM limit.
* `--memory-swap=1g`: Total memory + swap combined limit (gives 512MB RAM + 512MB Swap buffer).
* `--memory-reservation=256m`: Soft limit that gives warnings before throttling.
* `--restart on-failure:5`: Automatically restarts container if an unexpected crash occurs.

---

## 5. 🛡️ Prevention & Production Best Practices

1. **Docker Compose Limits**: Always define resource blocks in `docker-compose.yml`:
   ```yaml
   services:
     backend:
       deploy:
         resources:
           limits:
             cpus: '0.75'
             memory: 512M
           reservations:
             memory: 256M
   ```
2. **CloudWatch Alarm for Memory**: Set up an AWS CloudWatch metric filter for EC2 `MemoryUtilization > 85%` to trigger auto-scaling or alerts before OOM occurs.
3. **Chunked Processing in Code**: In Python FastAPI, stream files in chunks (e.g. 64KB blocks) rather than loading entire multi-megabyte PDFs into memory buffers all at once.
