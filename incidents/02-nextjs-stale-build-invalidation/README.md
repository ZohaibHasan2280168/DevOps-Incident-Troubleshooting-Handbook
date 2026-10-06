# 🚨 INC-002: Next.js 14 Server Action Mismatch & Stale Container Cache Invalidation

| Metadata | Details |
| :--- | :--- |
| **Incident ID** | INC-002 |
| **Severity** | P2 (Intermittent User-Facing Error) |
| **Subsystems** | Next.js 14 App Router, Docker Container Lifecycle, AWS ECR, Browser Caching |
| **Branch Reference** | `incident-02/nextjs-stale-build-invalidation` |
| **Resolution Status** | 🟢 Resolved |

---

## 1. 🔍 Incident Summary & Symptoms

Following a fresh CI/CD image build pushed to AWS ECR, the frontend container was restarted on the production EC2 host.

While initial page views rendered normally, dynamic user actions (such as document ingestion and AI analysis dispatches) failed intermittently with runtime application exceptions:

```log
ERROR:    Error: Failed to find Server Action "a8f9b2c3d4e5...". 
          This request might be from an older or newer deployment.
          at resolveServerAction (node_modules/next/dist/server/app-render/action-handler.js:142:15)
          at process.processTicksAndRejections (node:internal/process/task_queues:95:5)
```

Browser consoles recorded HTTP 500 responses accompanied by silent failure in UI interactive forms.

---

## 2. 🧠 Root Cause Analysis (RCA)

### Next.js Build-Time Action Hashing & Container Stale State
In Next.js 14 (App Router), every `use server` function / Server Action is assigned a cryptographic action hash during the **production build phase** (`next build`). This hash is compiled into:
1. The **server-side action manifest** (`.next/server/server-reference-manifest.json`).
2. The **client-side JavaScript chunks** served to users.

When a client browser triggers an action, it dispatches an HTTP POST request containing `Next-Action: <hash>`.

The incident occurred because of two compounding factors:

#### Factor A: Incomplete Container Lifecycle (`docker restart` vs `docker run`)
If an operator runs `docker restart smartdoc-frontend` without pulling the new image, or re-runs the container without deleting the old container layer (`docker rm`), Docker reuses the existing container filesystem layer. The running Node.js process remains pinned to the **old build manifest**, while clients receive new chunks (or vice versa).

#### Factor B: Aggressive Browser Caching of Static Chunks
If the client browser holds cached `.js` bundles from Build `v1`, but the backend container was updated to Build `v2`, the client sends an Action ID that only existed in Build `v1`. Next.js strictly verifies the hash against its active runtime manifest. When the hash is not found, Next.js aborts execution with:
`"Failed to find Server Action. This request might be from an older or newer deployment."`

```
[ Client Browser (Holding Cached Build v1) ]
         |
         | HTTP POST [Next-Action: Hash_v1]
         v
[ Docker Container: smartdoc-frontend (Running Build v2) ]
         |
         +---> Checks server-reference-manifest.json
         |
         x---> Hash_v1 NOT FOUND! Only Hash_v2 exists.
         |
         +---> 💥 500 Internal Server Error (Mismatch)
```

---

## 3. 🛠️ The Production Fix: Deterministic Container Recreation & Cache Busting

### Step-by-Step Remediation:

#### 1. Inspect Live Logs to Identify the Mismatched Hash
```bash
docker logs --tail 50 -f smartdoc-frontend
```

#### 2. Deterministic Clean Deployment (Purge Stale Container & Pull Fresh Layers)
Instead of a simple restart, explicitly stop, remove, and instantiate a new container bound to the fresh ECR image digest:

```bash
# Authenticate with ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com

# Pull the latest image explicitly
docker pull <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/smartdoc-frontend:latest

# Remove stale container instance completely
docker stop smartdoc-frontend || true
docker rm smartdoc-frontend || true

# Launch fresh container instance with explicit port mapping and network binding
docker run -d \
  --name smartdoc-frontend \
  --network smartdoc-net \
  -p 80:3000 \
  --restart always \
  <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/smartdoc-frontend:latest
```

#### 3. Enforce Client-Side Cache Invalidation
- Instruct clients to perform a **Hard Refresh** (`Ctrl + Shift + R` or `Cmd + Shift + R`) to purge cached scripts.
- In `next.config.mjs`, configure strict cache-control headers for static chunks:
```javascript
// next.config.mjs
const nextConfig = {
  async headers() {
    return [
      {
        source: '/_next/static/:path*',
        headers: [
          { key: 'Cache-Control', value: 'public, max-age=31536000, immutable' },
        ],
      },
    ];
  },
};
export default nextConfig;
```

---

## 4. 🧪 Automated Verification

Run automated probe against the frontend container health endpoint:

```bash
# 1. Verify container status and uptime
docker ps --filter "name=smartdoc-frontend" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"

# 2. Check HTTP status code returned by root and health paths
curl -I -s http://localhost/ | head -n 5

# 3. Stream logs to verify zero runtime unhandled exceptions
docker logs --tail 20 smartdoc-frontend
```

### Expected Output:
```
NAMES               STATUS          IMAGE
smartdoc-frontend   Up 2 minutes    479537131188.dkr.ecr.us-east-1.amazonaws.com/smartdoc-frontend:latest

HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
```

---

## 5. 🛡️ Prevention & Production Best Practices
1. **Immutable Image Tags**: Avoid deploying with `:latest`. Use Git commit SHAs (e.g., `:sha-8f92b1a`) to ensure absolute deployment determinism.
2. **Blue/Green Deployment**: When operating at scale, run old and new containers concurrently behind an Application Load Balancer (ALB) until all inflight browser sessions expire.
3. **Automate Container Cleanup in CI/CD**: Ensure the deployment script always performs `docker stop && docker rm` before `docker run` to prevent stale state retention.
