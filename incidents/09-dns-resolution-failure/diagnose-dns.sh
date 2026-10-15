#!/usr/bin/env bash
# ==============================================================================
# SRE Triage Script: Diagnose DNS Latency & Conntrack Packet Drops
# Incident: INC-009
# ==============================================================================
set -euo pipefail

TARGET_DOMAIN="${1:-api.openai.com}"

echo "=========================================================="
echo "🚨 INC-009 DIAGNOSTIC: DNS RESOLUTION LATENCY & PACKET DROPS"
echo "Target Hostname: ${TARGET_DOMAIN}"
echo "Timestamp:       $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "=========================================================="

# 1. Inspect /etc/resolv.conf options
echo -e "\n[Step 1] Inspecting local /etc/resolv.conf settings..."
if [ -f /etc/resolv.conf ]; then
    grep -E "nameserver|search|options" /etc/resolv.conf || cat /etc/resolv.conf
    
    NDOTS=$(grep -o "ndots:[0-9]" /etc/resolv.conf | cut -d':' -f2 || echo "default (1)")
    echo "  -> Current ndots value: ${NDOTS}"
    if [ "${NDOTS}" -ge 5 ]; then
        echo "  [WARNING ⚠️] ndots is set to ${NDOTS}. External domains will suffer search path explosion!"
    fi
fi

# 2. Benchmark DNS Query Latency & Trace Search Traversals
echo -e "\n[Step 2] Executing dig query latency trace..."
if command -v dig &> /dev/null; then
    dig +search +stats "${TARGET_DOMAIN}" | grep -E "Query time|SERVER|WHEN|MSG SIZE|status:"
else
    echo "  [INFO] 'dig' utility not installed. Falling back to nslookup / python..."
    python3 -c "
import socket, time
start = time.time()
try:
    ip = socket.gethostbyname('${TARGET_DOMAIN}')
    duration = (time.time() - start) * 1000
    print(f'  Resolved {TARGET_DOMAIN} -> {ip} in {duration:.2f} ms')
except Exception as e:
    print(f'  DNS resolution failed: {e}')
"
fi

# 3. Check Linux Kernel Conntrack Statistics
echo -e "\n[Step 3] Checking Linux Kernel Conntrack Drop Statistics..."
if command -v conntrack &> /dev/null; then
    conntrack -S 2>/dev/null || sudo conntrack -S
else
    echo "  [INFO] 'conntrack' CLI tool not found. Checking kernel syslog..."
    dmesg -T | grep -i -E "conntrack.*table full|insert_failed" | tail -n 5 || echo "  No conntrack crash messages in dmesg."
fi

# 4. Check AWS ENI Linklocal Allowance Exceeded (if running on EC2)
echo -e "\n[Step 4] Checking AWS EC2 Link-Local DNS Rate Limits..."
PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -n 1 || echo "eth0")
if command -v ethtool &> /dev/null; then
    ethtool -S "$PRIMARY_IF" 2>/dev/null | grep -i "allowance_exceeded" || echo "  Interface $PRIMARY_IF has no allowance_exceeded counters."
else
    echo "  [INFO] 'ethtool' not installed. Skipping hardware counter check."
fi

echo -e "\n=========================================================="
echo "✅ Diagnostic complete. If query time > 1000ms, deploy NodeLocal DNSCache & set ndots:2."
echo "=========================================================="
