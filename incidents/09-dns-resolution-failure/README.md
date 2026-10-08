# 🚨 INC-009: DNS Resolution Failures & CoreDNS Packet Throttling

| Metadata | Details |
| :--- | :--- |
| **Incident ID** | INC-009 |
| **Severity** | P1 (Inter-Service Communication Breakdown / External API Loss) |
| **Subsystems** | Linux resolver (`/etc/resolv.conf`), Kubernetes CoreDNS, AWS VPC Route53 |
| **Branch Reference** | `incident-09/dns-resolution-failure` |
| **Resolution Status** | 🟡 OPEN / UNDER ACTIVE TRIAGE |

---

## 1. 🔍 Incident Summary & Symptoms

Containerized backend microservices and Kubernetes pods are experiencing intermittent domain name resolution failures when communicating with external APIs (OpenAI, Stripe, S3) and peer microservices (`postgres.production.svc.cluster.local`).

Application error logs report standard name resolution exceptions:

```log
urllib3.exceptions.MaxRetryError: HTTPSConnectionPool(host='api.openai.com', port=443): Max retries exceeded with url: /v1/chat/completions (Caused by NameResolutionError("<urllib3.connection.HTTPSConnection object at 0x7f...>: Failed to resolve 'api.openai.com' ([Errno -3] Temporary failure in name resolution)"))
asyncpg.exceptions.CannotConnectNowError: could not translate host name "smartdoc-postgres" to address: Name or service not known
```

Intermittent DNS queries also suffer from massive latency spikes—taking up to **5,000ms (5 seconds)** to resolve a single domain name before timing out.

---

## 2. 🧠 Hypothesized Root Causes (Under Investigation)

1. **The `ndots:5` Resolution Penalty:** Default Linux `/etc/resolv.conf` in containers appends 5 search domains sequentially for external FQDNs (e.g. `api.openai.com.default.svc.cluster.local`), creating multiple NXDOMAIN round-trips and hitting 5s timeout limits.
2. **CoreDNS Pod CPU Throttling / Conntrack Exhaustion:** High query volumes overwhelming CoreDNS instances in Kubernetes, triggering UDP packet drops under Linux kernel conntrack table saturation.
3. **AWS Route53 VPC Resolver 1024 Packets/sec Limit:** EC2 instance network interfaces hit the hard AWS 1024 packets/second limit for the `.2` VPC DNS resolver (`10.0.0.2`).

---

## 3. 🔬 Active Triage Plan

- [ ] Run latency benchmarks with `dig +trace +stats` inside container namespaces.
- [ ] Inspect CoreDNS logs and Prometheus metrics (`coredns_dns_request_duration_seconds`).
- [ ] Implement `NodeLocal DNSCache` daemonset to cache DNS queries directly on worker nodes.
- [ ] Optimize container `dnsConfig` options (`ndots: 2` and `single-request-reopen`).

*(Full root cause analysis and verified remediation scripts will be finalized upon resolution).*
