#!/usr/bin/env bash
# ==============================================================================
# Script: setup-swap.sh
# Purpose: Provision a 1GB persistent Swap space buffer on AWS EC2
# ==============================================================================
set -euo pipefail

SWAP_SIZE="${1:-1G}"
SWAP_FILE="/swapfile"

echo ">>> [1/5] Checking existing swap allocation..."
free -h

if [ -f "$SWAP_FILE" ]; then
    echo ">>> Swapfile $SWAP_FILE already exists. Exiting."
    exit 0
fi

echo ">>> [2/5] Allocating ${SWAP_SIZE} swapfile..."
sudo fallocate -l "${SWAP_SIZE}" "${SWAP_FILE}"

echo ">>> [3/5] Setting secure file permissions (0600)..."
sudo chmod 600 "${SWAP_FILE}"

echo ">>> [4/5] Formatting as Linux swap..."
sudo mkswap "${SWAP_FILE}"

echo ">>> [5/5] Activating swap space..."
sudo swapon "${SWAP_FILE}"

# Persist in fstab if not already added
if ! grep -q "$SWAP_FILE" /etc/fstab; then
    echo "${SWAP_FILE} none swap sw 0 0" | sudo tee -a /etc/fstab
    echo ">>> Persisted in /etc/fstab."
fi

echo ">>> Swap configuration complete!"
free -h
