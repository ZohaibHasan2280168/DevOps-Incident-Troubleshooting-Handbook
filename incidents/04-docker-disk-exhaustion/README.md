# 🚨 INC-004: Docker Host Disk Exhaustion & Unrotated Container Logs ("No space left on device")

| Metadata | Details |
| :--- | :--- |
| **Incident ID** | INC-004 |
| **Severity** | P1 (Cluster Freeze / Deployment Failure) |
| **Subsystems** | Docker Storage (`overlay2`), JSON-file Logging Driver, Linux VFS, systemd |
| **Branch Reference** | `incident-04/docker-disk-exhaustion` |
| **Resolution Status** | 🟢 Resolved |

---

## 1. 🔍 Incident Summary & Symptoms

After running containerized microservices continuously for several days on an AWS EC2 instance, CI/CD pipeline deployments suddenly began failing during the image pull and container startup stages:

```log
ERROR: failed to register layer: write /var/lib/docker/overlay2/...: no space left on device
ERROR: Docker daemon failed to create container: exit status 1: write /var/lib/docker/... no space left on device
```

Furthermore, basic shell commands (like tab-completion or creating temporary files) failed across the EC2 host:
```bash
$ touch /tmp/test.txt
touch: cannot touch '/tmp/test.txt': No space left on device
```

Running `df -h` confirmed that the root filesystem (`/dev/root`) was at **100% utilization**:
```bash
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/root        30G   30G     0 100% /
```

---

## 2. 🧠 Root Cause Analysis (RCA)

### The Unrotated `json-file` Docker Logging Pitfall
When applications write logs to `stdout` and `stderr` (e.g. Uvicorn web requests, Redis commands, Next.js telemetry), Docker intercepts these streams using its default logging driver: `json-file`.

By default:
1. Docker stores every log line in `/var/lib/docker/containers/<container-id>/<container-id>-json.log`.
2. **There is NO default maximum file size (`max-size`) and NO file rotation (`max-file`) limit!**
3. If a container receives thousands of requests or outputs chatty health probe logs every 5 seconds, this single JSON file grows infinitely until it exhausts every available byte on the root partition.

```
+-------------------------------------------------------------------------+
| Docker Engine Host                                                      |
|                                                                         |
|  [ smartdoc-backend ] --- (stdout/stderr) ---> [ Docker Logging Daemon] |
|                                                        |                |
|                                                        v Writes         |
|  [ /var/lib/docker/containers/<id>/<id>-json.log ]                     |
|  (Grows indefinitely: 500MB -> 5GB -> 25GB -> DISK FULL 100% 💥)       |
+-------------------------------------------------------------------------+
```

### Dangerous Anti-Pattern: Deleting Open Log Files with `rm`
A common rookie mistake is running `rm /var/lib/docker/containers/*/*-json.log`.
Because the Docker daemon still holds the **open file descriptor (FD)** to the file, Linux does **NOT** release the disk space! The space remains occupied in `(deleted)` state until the Docker daemon itself is killed.

The correct, production-safe method is **truncating** the file descriptor (`truncate -s 0`).

---

## 3. 🔬 Forensics: Locating Bloated Disk Consumers

### 1. Identify Docker Disk Breakdown
```bash
docker system df
```
**Output:**
```
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          8         3         4.2GB     2.8GB (66%)
Containers      3         3         18.6GB    0B (0%)  <--- Massive containers footprint!
Local Volumes   3         3         120MB     0B (0%)
Build Cache     14        0         2.1GB     2.1GB
```

### 2. Locate the Exact Massive Log Files
```bash
sudo du -sh /var/lib/docker/containers/*/*-json.log | sort -hr | head -n 5
```
**Output:**
```
16G     /var/lib/docker/containers/4a7f8e.../4a7f8e...-json.log  <--- smartdoc-backend log!
2.1G    /var/lib/docker/containers/9c2d1b.../9c2d1b...-json.log  <--- smartdoc-frontend log!
```

---

## 4. 🛠️ The Production Fix & Remediation Runbook

### Step 1: Emergency Disk Recovery (Safe In-Place Log Truncation)
Safely truncate the active JSON logs without stopping containers or causing broken pipe errors:

```bash
# Safely zero-out all Docker JSON log files
sudo find /var/lib/docker/containers/ -name "*-json.log" -exec truncate -s 0 {} +

# Immediate disk reclamation check
df -h /
```

### Step 2: Configure Global Daemon Log-Rotation (`/etc/docker/daemon.json`)
To ensure logs never consume more than 30MB per container, configure Docker's global daemon configuration:

Create or update `/etc/docker/daemon.json`:
```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

* `"max-size": "10m"`: Individual log files are rotated once they reach 10 Megabytes.
* `"max-file": "3"`: Docker retains at most 3 historical files (`*-json.log`, `*-json.log.1`, `*-json.log.2`).
* Maximum footprint per container is capped deterministically at $10\text{MB} \times 3 = 30\text{MB}$.

### Step 3: Reload Docker Daemon
Apply the configuration dynamically:
```bash
sudo systemctl reload docker || sudo systemctl restart docker
```

### Step 4: Prune Dangling Build Layers & Images
Reclaim space from old unreferenced image layers:
```bash
# Prune stopped containers, unused networks, and dangling images
docker system prune -f

# (Optional) Prune all unused images
docker image prune -a -f
```

---

## 5. 🛡️ Prevention & Production Best Practices

1. **Automated Weekly Prune Cron**: Set up a weekly root cron job to eliminate dangling layers:
   ```bash
   0 3 * * 0 /usr/bin/docker image prune -f >> /var/log/docker-prune.log 2>&1
   ```
2. **Centralized Log Forwarding**: In enterprise multi-node environments, forward logs out-of-band to **AWS CloudWatch Logs**, **Datadog**, or **Grafana Loki** using the `awslogs` or `loki` log drivers instead of local disk storage.
3. **Disk Alerting**: Provision CloudWatch / Prometheus alarms when root EBS disk utilization exceeds 80%.
