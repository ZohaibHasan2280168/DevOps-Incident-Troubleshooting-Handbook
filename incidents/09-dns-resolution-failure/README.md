# 🚨 INC-009: DNS Resolution Failures & CoreDNS Packet Throttling

| Metadata | Details |
| :--- | :--- |
| **Incident ID** | INC-009 |
| **Severity** | P1 (Inter-Service Communication Breakdown / External API Loss) |
| **Subsystems** | Linux Resolver (`/etc/resolv.conf`), Kubernetes CoreDNS, AWS Route 53 Resolver, Linux Netfilter / Conntrack |
| **Branch Reference** | `incident-09/dns-resolution-failure` |
| **Resolution Status** | 🟢 Resolved |

---

## 1. 🔍 Incident Summary & Symptoms

During a production scaling event, backend microservices and worker pods deployed across a Kubernetes cluster began experiencing intermittent domain name resolution failures and severe latency spikes. Outbound communication to external APIs (OpenAI, Stripe, AWS S3) as well as internal cluster services (`smartdoc-postgres.production.svc.cluster.local`) degraded across all nodes.

### Terminal & Application Symptoms:
Engineers inspecting application pods discovered that standard HTTP requests were failing with name resolution timeouts:

```bash
$ kubectl exec -it smartdoc-backend-78bc9d4f-x8k2l -n production -- curl -I https://api.openai.com/v1/models
curl: (6) Could not resolve host: api.openai.com
```

Application logs captured repeated connection retry storms:

```log
urllib3.exceptions.MaxRetryError: HTTPSConnectionPool(host='api.openai.com', port=443): Max retries exceeded with url: /v1/chat/completions (Caused by NameResolutionError("<urllib3.connection.HTTPSConnection object at 0x7f4e8c1a2d90>: Failed to resolve 'api.openai.com' ([Errno -3] Temporary failure in name resolution)"))

asyncpg.exceptions.CannotConnectNowError: could not translate host name "smartdoc-postgres" to address: Name or service not known

Post "https://s3.us-east-1.amazonaws.com/": dial tcp: lookup s3.us-east-1.amazonaws.com on 10.96.0.10:53: i/o timeout
```

### Critical Latency Anomaly:
When running `dig` inside troubled pods, queries were found to stall for **exactly 5,000 milliseconds (5.0 seconds)**:

```bash
$ kubectl exec -it smartdoc-backend-78bc9d4f-x8k2l -n production -- dig api.openai.com
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 41829
;; flags: qr rd ra; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1

;; Query time: 5003 msec
;; SERVER: 10.96.0.10#53(10.96.0.10)
;; WHEN: Wed Oct 08 17:35:12 UTC 2026
;; MSG SIZE  rcvd: 114
```

---

## 2. 🧠 Root Cause Analysis (RCA)

Our investigation revealed three interlocking architectural bottlenecks spanning glibc resolution behavior, Linux kernel packet filtering, and AWS VPC rate limits:

```
[ Application Pod ] 
       │
       │ (1) ndots:5 creates 4 NXDOMAIN queries for every external FQDN
       ▼
[ Glibc Resolver ] ────(Concurrent A & AAAA UDP Queries)────► [ Linux Netfilter (Conntrack) ]
                                                                       │
                                                                       ▼ 💥 Race Condition: insert_failed
                                                                (UDP Packet Dropped!)
                                                                       │
                                                                       ▼ (Glibc waits 5.0s Timeout)
[ CoreDNS Cluster ] ◄──────────────────────────────────────────────────┘
       │
       │ (2) CoreDNS pods CPU-throttled & forward to AWS VPC
       ▼
[ AWS VPC Resolver (10.0.0.2) ] ──► 💥 Exceeds 1024 packets/sec per ENI limit!
```

---

### Deep-Dive Failure Mechanisms:

#### 1. The `ndots:5` Resolution Multiplier Penalty
By default, Kubernetes populates `/etc/resolv.conf` in every container with:

```conf
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local ec2.internal
options ndots:5
```

* **The Rule of `ndots`:** Glibc counts the number of periods (`.`) in the target hostname. If the dot count is strictly less than `ndots` (5), the resolver treats the name as **relative** and attempts to resolve it by appending every search domain sequentially before finally querying the absolute domain.
* **The Mathematical Explosion:** For `api.openai.com` (which contains only 2 dots, `2 < 5`), glibc executes:
  1. `api.openai.com.default.svc.cluster.local.` ➔ **NXDOMAIN** (Not Found)
  2. `api.openai.com.svc.cluster.local.` ➔ **NXDOMAIN** (Not Found)
  3. `api.openai.com.cluster.local.` ➔ **NXDOMAIN** (Not Found)
  4. `api.openai.com.ec2.internal.` ➔ **NXDOMAIN** (Not Found)
  5. `api.openai.com.` ➔ **NOERROR** (Success)
* Every single outbound HTTP request generated **5 separate DNS lookups**, multiplying cluster DNS traffic by 500%!

---

#### 2. Linux Kernel Netfilter Conntrack Collision & 5-Second Latency Spikes
* Glibc executes parallel lookups for IPv4 (`A`) and IPv6 (`AAAA`) records concurrently over UDP using the exact same local source port.
* The Linux kernel's Netfilter connection tracking subsystem (`nf_conntrack`) manages Network Address Translation (NAT) for pod networking.
* When two UDP packets with identical source port, destination IP (`10.96.0.10`), and destination port (`53`) are inserted into the kernel conntrack table across multiple CPU cores simultaneously, `nf_conntrack_confirm()` encounters a lock race condition.
* The kernel rejects the second packet (`insert_failed`), silently dropping the UDP packet.
* Because UDP is connectionless, glibc waits for its internal hardcoded retransmission timer: **exactly 5,000ms (5.0s)**. This was the exact cause of the mysterious 5-second latency spikes!

---

#### 3. CoreDNS Pod CPU Throttling & AWS Route 53 1024 PPS Limit
* **CoreDNS CPU Quotas:** Due to the 5x query explosion from `ndots:5`, CoreDNS pods hit their Kubernetes Completely Fair Scheduler (CFS) CPU limit (`cpu: 100m`) and experienced throttling.
* **AWS VPC DNS Rate Limit:** AWS EC2 enforces a hard hypervisor quota of **1024 packets per second (PPS)** per Elastic Network Interface (ENI) for DNS queries to the VPC `.2` resolver (`10.0.0.2`). Uncached external lookups exceeded this threshold, causing the AWS hypervisor to drop DNS packets silently.

---

## 3. 🔬 SRE Diagnostic Triage Tree

### Step 1: Trace Search Domain Traversal with `dig`
Run `dig` with `+search` and `+stats` to inspect search domain traversal:

```bash
kubectl exec -it smartdoc-backend-78bc9d4f-x8k2l -n production -- dig +search +stats api.openai.com
```

#### Observed Output:
```text
;; Question section:
;api.openai.com.default.svc.cluster.local. IN A
;; Got answer: status: NXDOMAIN, Query time: 12 msec

;; Question section:
;api.openai.com.svc.cluster.local. IN A
;; Got answer: status: NXDOMAIN, Query time: 10 msec

;; Question section:
;api.openai.com.cluster.local. IN A
;; Got answer: status: NXDOMAIN, Query time: 11 msec

;; Question section:
;api.openai.com.ec2.internal. IN A
;; Got answer: status: NXDOMAIN, Query time: 15 msec

;; Question section:
;api.openai.com. IN A
;; Got answer: status: NOERROR, Query time: 14 msec
```
*(Proves 4 wasted round-trips occurred before resolving the external domain!)*

---

### Step 2: Check Kernel Conntrack Collision Drops
Inspect connection tracking statistics on the Kubernetes worker node:

```bash
sudo conntrack -S
```

#### Observed Output:
```text
cpu=0   found=12848 invalid=0 insert=14203 insert_failed=482 drop=482 early_drop=0
cpu=1   found=11920 invalid=0 insert=13840 insert_failed=395 drop=395 early_drop=0
```
* **Smoking Gun:** `insert_failed` and `drop` counters incrementing directly proves the Linux kernel is dropping UDP DNS replies due to conntrack collisions.

---

### Step 3: Check AWS ENI Link-Local DNS Rate Limit Drops
Check if the physical network interface is dropping DNS packets destined for the VPC resolver:

```bash
sudo ethtool -S eth0 | grep -i allowance_exceeded
```

#### Observed Output:
```text
linklocal_allowance_exceeded: 3419
```
* Any non-zero value indicates that DNS query volume exceeded AWS's 1024 PPS limit.

---

### Step 4: Inspect CoreDNS Prometheus Metrics
Query CoreDNS response codes and latency percentiles in Prometheus:

```promql
# 99th percentile CoreDNS latency
histogram_quantile(0.99, sum(rate(coredns_dns_request_duration_seconds_bucket[5m])) by (le))

# NXDOMAIN response rate
sum(rate(coredns_dns_responses_total{rcode="NXDOMAIN"}[5m]))
```

---

## 4. 🛠️ The Production Fix & Remediation Runbook

### Step 1: Optimize Pod DNS Configuration (`dnsConfig`)
Update Kubernetes Deployment manifests with optimized `dnsConfig` options:

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: smartdoc-backend
  namespace: production
spec:
  replicas: 4
  template:
    metadata:
      labels:
        app: smartdoc-backend
    spec:
      dnsPolicy: "ClusterFirst"
      dnsConfig:
        options:
          # If domain has >= 2 dots, query directly without appending search path
          - name: ndots
            value: "2"
          # Forces glibc to use separate sockets for A and AAAA queries (eliminates conntrack race)
          - name: single-request-reopen
          # Reduce retransmit timeout from 5s down to 1s with 2 retry attempts
          - name: timeout
            value: "1"
          - name: attempts
            value: "2"
      containers:
        - name: backend
          image: smartdoc-backend:latest
```

> **Developer Quick-Win:** In application code and environment variables, append a trailing dot to external URLs (e.g. `https://api.openai.com./v1`). A trailing dot signifies a Fully Qualified Domain Name (FQDN), instructing glibc to bypass search paths immediately.

---

### Step 2: Deploy `NodeLocal DNSCache` DaemonSet
Deploy `NodeLocal DNSCache` to run a local DNS caching agent on every Kubernetes worker node (`169.254.20.10`):

```bash
kubectl apply -f nodelocal-dns.yaml
```

#### Architectural Advantages:
1. **Local Node Caching:** Pods query `169.254.20.10` on the local node interface, eliminating inter-node network hops.
2. **TCP Upstream:** NodeLocal DNSCache communicates with CoreDNS via **TCP**, completely eliminating UDP packet drops and kernel conntrack collisions.
3. **Absorbs Route 53 Traffic:** Caching absorbs >80% of external queries, keeping outbound traffic well below AWS's 1024 PPS limit.

---

### Step 3: Autoscale CoreDNS & Remove Strict CPU Limits
Patch CoreDNS resources to prevent CFS scheduling throttling:

```yaml
# coredns-patch.yaml
resources:
  limits:
    memory: 256Mi
    # Omit strict CPU limit to avoid CFS throttling
  requests:
    cpu: 200m
    memory: 128Mi
```

```bash
kubectl patch deployment coredns -n kube-system --patch-file coredns-patch.yaml
```

---

## 5. 🧪 Automated Verification & Health Probe

### 1. Benchmark DNS Lookup Latency Inside the Pod
Execute 100 consecutive DNS lookups inside the container to verify latency consistency:

```bash
kubectl exec -it smartdoc-backend-78bc9d4f-x8k2l -n production -- python3 -c '
import socket, time
times = []
for _ in range(50):
    t0 = time.time()
    socket.gethostbyname("api.openai.com")
    times.append((time.time() - t0) * 1000)
print(f"Average: {sum(times)/len(times):.2f} ms | Max: {max(times):.2f} ms")
'
```

#### Expected Output:
```text
Average: 1.42 ms | Max: 4.80 ms
```
*(Query latency reduced from 5,000ms down to 1.42ms—zero 5-second stalls!)*

---

### 2. Verify Zero Conntrack Collision Drops
```bash
sudo conntrack -S | grep insert_failed
```

#### Expected Output:
```text
cpu=0   found=28410 invalid=0 insert=29800 insert_failed=0 drop=0 early_drop=0
cpu=1   found=27950 invalid=0 insert=28400 insert_failed=0 drop=0 early_drop=0
```

---

## 6. 🛡️ Prevention & Production Best Practices

1. **Standardize `single-request-reopen`:** Always include `single-request-reopen` in containerized workloads running on Linux kernels prior to 6.2.
2. **Deploy NodeLocal DNSCache by Default:** Treat NodeLocal DNSCache as a mandatory component for any production Kubernetes cluster (EKS, GKE, or bare-metal).
3. **Monitor Cloud Provider ENI Limits:** Create CloudWatch / Datadog alarms on `linklocal_allowance_exceeded` to detect VPC resolver saturation before it impacts end-users.
4. **Use FQDNs for Third-Party APIs:** Use `api.stripe.com.` or `sqs.us-east-1.amazonaws.com.` with a trailing dot in application connection strings.
