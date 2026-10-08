# 🚨 INC-007: Kubernetes Pod CrashLoopBackOff Caused by Startup Failures & Probe Misconfiguration

| Metadata | Details |
| :--- | :--- |
| **Incident ID** | INC-007 |
| **Severity** | P1 (Service Unavailability / Deployment Stall) |
| **Subsystems** | Kubernetes Kubelet, Pod Lifecycle, Container Runtime, Liveness/Readiness Probes |
| **Branch Reference** | `incident-07/kubernetes-crashloopbackoff` |
| **Resolution Status** | 🟢 Resolved |

---

## 1. 🔍 Incident Summary & Symptoms

Following an automated deployment roll-out in a Kubernetes cluster, newly created microservice pods failed to transition to a `Ready` state. The cluster ingress began serving HTTP 503 Service Unavailable errors to end-users.

Running `kubectl get pods` revealed that the backend deployment was stuck in a restart storm:

```bash
$ kubectl get pods -n production
NAME                                  READY   STATUS             RESTARTS      AGE
smartdoc-backend-6d4b9f78cc-4x2lm     0/1     CrashLoopBackOff   8 (45s ago)   14m
smartdoc-backend-6d4b9f78cc-9j8kn     0/1     CrashLoopBackOff   9 (20s ago)   16m
```

The restart counter kept incrementing, and the deployment roll-out was permanently blocked.

---

## 2. 🧠 Root Cause Analysis (RCA)

### Understanding the `CrashLoopBackOff` State Machine
`CrashLoopBackOff` is not an application error itself; it is a **Kubelet backoff algorithm**:
1. When a container inside a pod terminates with a non-zero exit code (or fails its liveness probe), Kubelet attempts to restart it based on the pod's `restartPolicy: Always`.
2. To avoid consuming 100% of the node's CPU and disk I/O in an infinite immediate restart loop, Kubelet introduces an **exponential backoff delay** between restarts:
   $$\text{Backoff Interval}: 10\text{s} \longrightarrow 20\text{s} \longrightarrow 40\text{s} \longrightarrow 80\text{s} \longrightarrow 160\text{s} \longrightarrow 300\text{s (Max 5 mins)}$$
3. During this delay period, Kubelet assigns the pod status: `CrashLoopBackOff`.

```
[ Container Starts ] ───> [ Encounters Fatal Error / Exit Code != 0 ]
         ▲                                     │
         │                                     v
         │                            [ Container Terminates ]
         │                                     │
         │                                     v
[ Backoff Delay (10s -> 300s) ] <── [ Kubelet Records Restart Count ]
(Status: CrashLoopBackOff)
```

### The Two Underlying Root Triggers:
In this incident, post-mortem forensics identified two compounding triggers:

#### Trigger A: Missing Secret / Environment Variable (Exit Code 1)
The backend container required a database connection string from a Kubernetes Secret (`smartdoc-db-secrets`). A newly introduced secret key (`DATABASE_SSL_MODE`) was missing from the Secret manifest, causing Python to throw an unhandled `KeyError` during startup and exit with **Code 1**.

#### Trigger B: Premature Liveness Probe Murder
The microservice required 25 seconds to run database schema migrations on cold start. However, the deployment manifest configured:
```yaml
livenessProbe:
  initialDelaySeconds: 5   # <-- Way too short!
  periodSeconds: 5
  failureThreshold: 2      # <-- Killed after only 15 seconds!
```
Before the app could finish connecting to PostgreSQL, Kubelet assumed the container was dead, dispatched `SIGKILL`, and restarted it, compounding into `CrashLoopBackOff`.

---

## 3. 🔬 SRE Diagnostic Triage Tree

### Step 1: Inspect Pod Details & Exit Reason
```bash
kubectl describe pod <pod-name> -n production
```
Look at the **Last State** section:
```yaml
Last State:     Terminated
  Reason:       Error
  Exit Code:    1
  Started:      Wed, 08 Oct 2026 12:00:10 +0000
  Finished:     Wed, 08 Oct 2026 12:00:15 +0000
```

### Step 2: Retrieve Logs of the Terminated Instance (`--previous`)
Because the container is in a restart loop, standard `kubectl logs` often returns empty or only the new initializing instance. The golden SRE command is `--previous`:

```bash
kubectl logs <pod-name> -n production --previous
```
**Output:**
```log
Traceback (most recent call last):
  File "/app/main.py", line 18, in <module>
    ssl_mode = os.environ["DATABASE_SSL_MODE"]
KeyError: 'DATABASE_SSL_MODE'
```
*(Instantly pinpointed the missing configuration!)*

---

## 4. 🛠️ The Production Fix & Remediation Runbook

### Step 1: Update the Kubernetes Secret
Provide the missing environment variable in the cluster secret:
```bash
kubectl create secret generic smartdoc-db-secrets \
  --from-literal=DATABASE_SSL_MODE=require \
  -n production --dry-run=client -o yaml | kubectl apply -f -
```

---

### Step 2: Implement a Kubernetes `startupProbe`
Never rely solely on `livenessProbe` for slow-starting applications. Introduce a `startupProbe` to grant the application up to 60 seconds to initialize before liveness probes activate:

```yaml
# deployment.yaml
spec:
  containers:
    - name: backend
      image: <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/smartdoc-backend:latest
      envFrom:
        - secretRef:
            name: smartdoc-db-secrets
      # Startup Probe protects slow initialization
      startupProbe:
        httpGet:
          path: /api/v1/health
          port: 8000
        failureThreshold: 12
        periodSeconds: 5
      # Liveness Probe only monitors health AFTER startup probe succeeds
      livenessProbe:
        httpGet:
          path: /api/v1/health
          port: 8000
        periodSeconds: 10
        failureThreshold: 3
```

---

## 5. 🧪 Automated Verification

Apply the patched deployment and verify pod stability:

```bash
kubectl rollout restart deployment smartdoc-backend -n production
kubectl rollout status deployment smartdoc-backend -n production
kubectl get pods -n production -l app=smartdoc-backend
```

### Expected Output:
```
deployment "smartdoc-backend" successfully rolled out
NAME                                  READY   STATUS    RESTARTS   AGE
smartdoc-backend-7c9b8f6d5e-2b1cd     1/1     Running   0          45s
smartdoc-backend-7c9b8f6d5e-8k4la     1/1     Running   0          42s
```

---

## 6. 🛡️ Prevention & Production Best Practices

1. **Pre-flight Helm / Kustomize Validation:** Run `helm lint` and `kubeval` in CI pipelines to ensure all referenced configMap and secret keys exist before deploying.
2. **Distinct Startup vs Liveness Probes:** Always configure `startupProbe` for microservices that execute database schema migrations or load heavy machine learning models on boot.
3. **Graceful Termination Handlers:** Implement `SIGTERM` listeners in application code to complete in-flight transactions before shutting down.
