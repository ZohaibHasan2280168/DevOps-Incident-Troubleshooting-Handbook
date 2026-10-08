# 🚨 INC-008: HTTP 502 Bad Gateway & 504 Gateway Timeout in Reverse Proxy Upstream

| Metadata | Details |
| :--- | :--- |
| **Incident ID** | INC-008 |
| **Severity** | P1 (Total Service Degradation / Ingress Failure) |
| **Subsystems** | Nginx Reverse Proxy, AWS ALB, FastAPI / Node.js Upstream Workers |
| **Branch Reference** | `incident-08/http-502-504-bad-gateway` |
| **Resolution Status** | 🟡 OPEN / UNDER ACTIVE TRIAGE |

---

## 1. 🔍 Incident Summary & Symptoms

End-users attempting to access the platform through the public domain are intermittently receiving **HTTP 502 Bad Gateway** and **HTTP 504 Gateway Timeout** errors. 

Public-facing reverse proxy (Nginx / Load Balancer) logs show upstream connection drops and socket exhaustion:

```log
2026/10/08 17:15:20 [error] 1422#1422: *892 connect() failed (111: Connection refused) while connecting to upstream, client: 198.51.100.42, server: api.smartdoc.io, request: "POST /api/v1/documents/process HTTP/1.1", upstream: "http://172.17.0.3:8000/api/v1/documents/process"
2026/10/08 17:15:45 [error] 1422#1422: *895 upstream timed out (110: Connection timed out) while reading response header from upstream, client: 198.51.100.42, server: api.smartdoc.io, request: "GET /api/v1/analytics HTTP/1.1", upstream: "http://172.17.0.3:8000/api/v1/analytics"
```

Simultaneously, AWS Application Load Balancer (ALB) CloudWatch metrics indicate a surge in `HTTPCode_Target_5XX_Count`.

---

## 2. 🧠 Hypothesized Root Causes (Under Investigation)

1. **Upstream Worker Crash / OOM Silent Death:** The backend Python Uvicorn worker process died under heavy load, causing Nginx to attempt TCP handshakes against a closed port (`Connection refused` ➔ **502 Bad Gateway**).
2. **Slow Query / Gateway Timeout Mismatch:** Nginx `proxy_read_timeout` is configured to 60s, but heavy PDF analytics queries exceed 75s, triggering premature proxy severance (➔ **504 Gateway Timeout**).
3. **Keepalive & Socket Exhaustion:** Lack of upstream persistent connection pooling (`keepalive 32;`) leading to ephemeral port exhaustion during concurrent request surges.

---

## 3. 🔬 Active Triage Plan

- [ ] Inspect upstream container process status (`docker top smartdoc-backend`).
- [ ] Profile slow API response times using `curl -w "@curl-format.txt"` to differentiate 502 vs 504 thresholds.
- [ ] Align Nginx `proxy_read_timeout` and Uvicorn `timeout-keep-alive` parameters.
- [ ] Implement upstream healthcheck retries and fallback buffers.

*(Full root cause analysis and verified remediation scripts will be finalized upon resolution).*
