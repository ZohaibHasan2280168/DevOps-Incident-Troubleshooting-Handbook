# 🚨 INC-001: Inter-Container Network Isolation & Connection Refused (Error 111)

| Metadata | Details |
| :--- | :--- |
| **Incident ID** | INC-001 |
| **Severity** | P1 (Service Degradation) |
| **Subsystems** | Docker Network Engine, Linux Namespaces, FastAPI, Redis, PostgreSQL |
| **Branch Reference** | `incident-01/docker-bridge-networking` |
| **Resolution Status** | 🟢 Resolved |

---

## 1. 🔍 Incident Summary & Symptoms

During the live deployment of a 3-tier microservices application on an AWS EC2 instance, the FastAPI backend reported health status `degraded`. 

While the application process booted up successfully, all API endpoints relying on session caching and persistent storage failed with runtime connection errors:

```log
ERROR:    [FastAPI] Redis probe failed: Error 111 connecting to localhost:6379. Connection refused.
ERROR:    [Database] asyncpg.exceptions.CannotConnectNowError: could not translate host name "localhost" to address: Connection refused
WARNING:  [HealthEndpoint] Overall service status degraded. Redis=Degraded, PostgreSQL=Degraded.
```

---

## 2. 🧠 Root Cause Analysis (RCA)

### The "Localhost" Trap in Linux Network Namespaces
In standard non-containerized environments, services running on the same host bind to `127.0.0.1` (`localhost`) and communicate over the loopback interface (`lo`).

However, by default, Docker runs each container inside an **isolated Linux network namespace**:
1. When `smartdoc-backend` attempts to connect to `redis://localhost:6379`, the networking stack looks for a process listening on port 6379 **inside its own container namespace**.
2. Because Redis is running in a **different container** (`smartdoc-redis`) with its own distinct network namespace, there is no socket listening at port 6379 inside the backend container.
3. The kernel immediately sends a `TCP RST` (Reset) packet, producing `POSIX Error 111: Connection Refused`.

```
[ Container: smartdoc-backend ]
  PID 1 (uvicorn) ---> connects to localhost:6379 ---> [ lo interface inside backend ] ---> ❌ (Nothing listening! Error 111)

[ Container: smartdoc-redis ]
  PID 1 (redis-server) listening on 0.0.0.0:6379 ---> [ Separate network namespace ]
```

Furthermore, in Docker's **Default Bridge (`bridge`)**:
- Containers are assigned random private IPs (e.g., `172.17.0.2`, `172.17.0.3`).
- **Embedded DNS resolution is disabled** on the default bridge! Containers cannot discover each other by container name (e.g. `ping smartdoc-redis` will fail).

---

## 3. 🛠️ The Production Fix: User-Defined Bridge Network

Docker's **User-Defined Bridge Network** activates the built-in 127.0.0.11 embedded DNS server, enabling automatic service discovery via container names.

### Step-by-Step Remediation:

#### 1. Create a Dedicated Bridge Network
```bash
docker network create smartdoc-net
```

#### 2. Launch Redis attached to the network
```bash
docker run -d \
  --name smartdoc-redis \
  --network smartdoc-net \
  -p 6379:6379 \
  --restart always \
  redis:7-alpine
```

#### 3. Launch PostgreSQL attached to the network
```bash
docker run -d \
  --name smartdoc-postgres \
  --network smartdoc-net \
  -e POSTGRES_DB=smartdoc_db \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  --restart always \
  postgres:16-alpine
```

#### 4. Launch Backend with Container DNS Names
Notice that `localhost` is replaced with the container name `smartdoc-redis` and `smartdoc-postgres`:
```bash
docker run -d \
  --name smartdoc-backend \
  --network smartdoc-net \
  -p 8000:8000 \
  -e REDIS_URL="redis://smartdoc-redis:6379" \
  -e DATABASE_URL="postgresql://postgres:postgres@smartdoc-postgres:5432/smartdoc_db" \
  --restart always \
  <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/smartdoc-backend:latest
```

---

## 4. 🧪 Automated Verification & Health Probe

Verify that all containers are resolved and communicating:

```bash
# Verify network membership
docker network inspect smartdoc-net --format '{{json .Containers}}'

# Health check probe
curl -s http://localhost:8000/api/v1/health | jq .
```

### Expected Output:
```json
{
  "status": "healthy",
  "dependencies": {
    "redis": "connected",
    "postgresql": "connected",
    "s3_bucket": "accessible"
  },
  "uptime_seconds": 128
}
```

---

## 5. 🛡️ Prevention & Best Practices
1. **Never hardcode `localhost` in containerized service configs.** Always use environment variables defaults pointing to service names.
2. **Use Docker Compose in development and user-defined networks in production** to ensure DNS service discovery is guaranteed.
3. **Include healthcheck probes in CI/CD pipelines** that validate inter-service TCP handshakes before marking deployments ready.
