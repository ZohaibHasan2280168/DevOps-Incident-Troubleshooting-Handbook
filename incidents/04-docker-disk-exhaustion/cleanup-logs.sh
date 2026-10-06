#!/usr/bin/env bash
# ==============================================================================
# Script: cleanup-logs.sh
# Purpose: Safely truncate Docker container logs without restarting services
# ==============================================================================
set -euo pipefail

echo ">>> [1/3] Current disk utilization before cleanup:"
df -h /

echo ">>> [2/3] Truncating all active container json-file logs..."
sudo find /var/lib/docker/containers/ -name "*-json.log" -type f -exec truncate -s 0 {} +

echo ">>> [3/3] Pruning dangling Docker build cache and stopped resources..."
docker system prune -f

echo ">>> Cleanup complete! Disk utilization after cleanup:"
df -h /
