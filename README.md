# 🛡️ DevOps Incident & Troubleshooting Handbook

[![Docker](https://img.shields.io/badge/Docker-24.0+-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![AWS](https://img.shields.io/badge/AWS-EC2%20%7C%20ECR-FF9900?logo=amazon-aws&logoColor=white)](https://aws.amazon.com/)
[![FastAPI](https://img.shields.io/badge/FastAPI-Tier%202-009688?logo=fastapi&logoColor=white)](https://fastapi.tiangolo.com/)
[![Next.js](https://img.shields.io/badge/Next.js-14.2%20App%20Router-000000?logo=next.js&logoColor=white)](https://nextjs.org/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![Redis](https://img.shields.io/badge/Redis-7%20Cache-DC382D?logo=redis&logoColor=white)](https://redis.io/)

> **A curated, production-tested repository of real-world Site Reliability Engineering (SRE) post-mortems, root-cause analyses (RCA), and incident resolution runbooks.**

---

## 📌 Executive Summary

Modern cloud-native applications frequently encounter production failures that cannot be caught in toy environments. This handbook documents actual operational hurdles diagnosed and resolved across containerized microservices architectures hosted on **AWS EC2**, orchestrated with **Docker**, and managed with zero-downtime deployment patterns.

Each incident follows the standard **SRE Incident Response Lifecycle**:
1. **Detection & Triage** (Symptoms & Live Log Forensics)
2. **Root Cause Analysis (RCA)** (Kernel / Namespace / Framework Level)
3. **Remediation & Runbooks** (Exact fix & rollback scripts)
4. **Prevention & Architectural Hardening** (Configuration drift elimination)

---

## 📑 Incident Directory

| Incident ID | Incident Name | Severity | Impacted Subsystem | Resolution Status | Branch Reference |
| :--- | :--- | :---: | :--- | :---: | :--- |
| **[INC-001](./incidents/01-docker-bridge-networking/)** | **Inter-Container Network Isolation & Connection Refused (Error 111)** | `P1 - High` | Docker Engine / User-defined Bridge / Linux Namespaces | `RESOLVED 🟢` | [`incident-01/docker-bridge-networking`](https://github.com/ZohaibHasan2280168/DevOps-Incident-Troubleshooting-Handbook/tree/incident-01/docker-bridge-networking) |
| **[INC-002](./incidents/02-nextjs-stale-build-invalidation/)** | **Next.js 14 Server Action Mismatch & Stale Container Cache Invalidation** | `P2 - Medium` | Next.js SSR / ECR Container Lifecycle / Cache-Busting | `RESOLVED 🟢` | [`incident-02/nextjs-stale-build-invalidation`](https://github.com/ZohaibHasan2280168/DevOps-Incident-Troubleshooting-Handbook/tree/incident-02/nextjs-stale-build-invalidation) |

---

## 🏗️ Reference Microservices Topology

```
                  +-----------------------------------+
                  |         Client Browser            |
                  +-----------------+-----------------+
                                    |
                            HTTP/80 | (Public Web)
                                    v
+-----------------------------------------------------------------------------+
| AWS EC2 Virtual Machine (Linux 6.8.0 / Ubuntu 24.04 LTS)                     |
|                                                                             |
|  +------------------------+      User-defined Bridge      +--------------+  |
|  | smartdoc-frontend      |<=============================>| smartdoc-    |  |
|  | (Next.js 14 SSR)       |       Network: smartdoc-net   | backend      |  |
|  | Port: 3000 -> Host: 80 |                               | (FastAPI)    |  |
|  +------------------------+                               | Port: 8000   |  |
|                                                           +-------+------+  |
|                                                                   |         |
|                     +---------------------------------------------+         |
|                     |                                             |         |
|                     v                                             v         |
|         +-----------------------+                     +------------------+  |
|         | smartdoc-redis        |                     | smartdoc-postgres|  |
|         | (Redis 7 In-Memory)   |                     | (Postgres 16 DB) |  |
|         | Port: 6379            |                     | Port: 5432       |  |
|         +-----------------------+                     +------------------+  |
+-----------------------------------------------------------------------------+
```

---

## 🛠️ Global Diagnostic Toolset

When troubleshooting production incidents across this cluster, the following triage commands are used:

```bash
# 1. Inspect running container health & port bindings
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 2. Inspect inter-container bridge network membership
docker network inspect smartdoc-net --format '{{range .Containers}}{{.Name}} -> {{.IPv4Address}}{{"\n"}}{{end}}'

# 3. Stream real-time container standard error & output
docker logs --tail 100 -f <container_name>

# 4. Probe service health check directly inside the container namespace
docker exec -it smartdoc-backend curl -s http://localhost:8000/api/v1/health
```

---

## 🤝 Contributing & Incident Submissions

Encountered an intriguing edge case? Follow the template in [`incidents/TEMPLATE.md`](./incidents/TEMPLATE.md) to submit a pull request with reproducible Docker Compose files and post-mortem analysis.

---

## 📜 License
MIT License. Created by **Zohaib Hasan** for the DevOps & Cloud Engineering Community.
