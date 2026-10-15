#!/usr/bin/env bash
# ==============================================================================
# SRE Triage Script: Host & Container CPU Profiling & Thread Analysis
# Incident: INC-010
# ==============================================================================
set -euo pipefail

echo "=========================================================="
echo "🚨 INC-010 DIAGNOSTIC: HOST CPU SATURATION & THREAD PROFILER"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "=========================================================="

# 1. System Load Average & Core Count
CORES=$(nproc)
echo -e "\n[Step 1] Inspecting CPU capacity and load average..."
echo "  Total logical CPU cores: ${CORES}"
uptime

# 2. Top 5 CPU Consuming Processes
echo -e "\n[Step 2] Identifying top CPU-consuming processes..."
ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu | head -n 6

# 3. Process & Thread-level Analysis
TARGET_PID=$(ps -eo pid,%cpu,comm --sort=-%cpu | awk 'NR==2 {print $1}')
echo -e "\n[Step 3] Analyzing threads for highest consumer (PID: ${TARGET_PID})..."

if command -v pidstat &> /dev/null; then
    echo "  Sampling thread CPU activity with pidstat (3 seconds)..."
    pidstat -u -t -p "${TARGET_PID}" 1 3 || true
else
    echo "  [INFO] 'pidstat' not installed. Falling back to ps thread listing:"
    ps -To pid,tid,class,rtprio,ni,pri,psr,pcpu,stat,wchan:14,comm -p "${TARGET_PID}" || true
fi

# 4. Check for cgroup CPU Throttling
echo -e "\n[Step 4] Checking Docker / cgroup CPU quota throttling..."
if [ -d "/sys/fs/cgroup/cpu" ] || [ -d "/sys/fs/cgroup" ]; then
    # cgroup v1 or v2 cpu.stat inspection
    find /sys/fs/cgroup -name "cpu.stat" 2>/dev/null | head -n 3 | while read -r statfile; do
        echo "  Stats from ${statfile}:"
        grep -E "nr_throttled|throttled_usec|throttled_time" "${statfile}" || true
    done
fi

echo -e "\n=========================================================="
echo "✅ Diagnostic complete. If %usr is ~100%, profile with 'py-spy dump --pid ${TARGET_PID}'."
echo "=========================================================="
