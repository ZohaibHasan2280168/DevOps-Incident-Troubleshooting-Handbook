#!/usr/bin/env bash
# ==============================================================================
# SRE Triage Script: Diagnose Reverse Proxy 502 / 504 Gateway Errors
# Incident: INC-008
# ==============================================================================
set -euo pipefail

TARGET_URL="${1:-http://localhost/api/v1/health}"
UPSTREAM_HOST="${2:-127.0.0.1}"
UPSTREAM_PORT="${3:-8000}"

echo "=========================================================="
echo "🚨 INC-008 DIAGNOSTIC: 502 / 504 UPSTREAM ROOT CAUSE ISOLATION"
echo "Target URL:      ${TARGET_URL}"
echo "Upstream Target: ${UPSTREAM_HOST}:${UPSTREAM_PORT}"
echo "Timestamp:       $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "=========================================================="

# 1. Check Layer 4 TCP Socket Connectivity to Upstream
echo -e "\n[Step 1] Checking direct TCP Socket reachability..."
if nc -z -w 3 "${UPSTREAM_HOST}" "${UPSTREAM_PORT}" 2>/dev/null; then
    echo "  [OK] Upstream socket ${UPSTREAM_HOST}:${UPSTREAM_PORT} is accepting connections."
else
    echo "  [FAIL 💥] Cannot establish TCP connection to ${UPSTREAM_HOST}:${UPSTREAM_PORT}!"
    echo "  -> ROOT CAUSE FOR 502: Upstream process is crashed or bound to wrong interface (e.g. 127.0.0.1 inside container)."
fi

# 2. Inspect Running Python/Uvicorn Workers
echo -e "\n[Step 2] Inspecting running upstream worker processes..."
if command -v docker &> /dev/null && docker ps &> /dev/null; then
    CONTAINER_ID=$(docker ps -q --filter "ancestor=smartdoc-backend" 2>/dev/null || true)
    if [ -n "$CONTAINER_ID" ]; then
        echo "  Found backend container: $CONTAINER_ID"
        docker top "$CONTAINER_ID"
    else
        echo "  [INFO] No Docker container matching 'smartdoc-backend' found on local host."
    fi
fi

# 3. High-Precision Latency Breakdown via cURL
echo -e "\n[Step 3] Running High-Precision cURL Latency Benchmark..."
CURL_FORMAT='
  HTTP Status Code:    %{http_code}\n
  DNS Lookup Time:     %{time_namelookup}s\n
  TCP Connect Time:    %{time_connect}s\n
  App Connect Time:    %{time_appconnect}s\n
  Pre-transfer Time:   %{time_pretransfer}s\n
  Start-transfer Time: %{time_starttransfer}s (Time To First Byte - TTFB)\n
  Total Response Time: %{time_total}s\n
'

curl -w "$CURL_FORMAT" -o /dev/null -s -k "$TARGET_URL" || true

echo -e "\n[Triage Decision Tree]:"
echo "  - If HTTP Status == 502 & TTFB < 0.05s: Upstream crashed or connection refused."
echo "  - If HTTP Status == 504 & TTFB >= 60.0s: Nginx proxy_read_timeout exceeded by slow app logic."
echo "  - If HTTP Status == 200 & TTFB < 0.2s: Upstream is fully healthy."
echo "=========================================================="
