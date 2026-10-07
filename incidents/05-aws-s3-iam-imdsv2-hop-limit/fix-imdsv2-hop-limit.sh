#!/usr/bin/env bash
# ==============================================================================
# Script: fix-imdsv2-hop-limit.sh
# Purpose: Modify AWS EC2 Instance Metadata Options to enable Docker container access
# ==============================================================================
set -euo pipefail

INSTANCE_ID="${1:-i-038112618ff09da48}"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo ">>> [1/3] Inspecting current metadata configuration for instance: ${INSTANCE_ID}..."
aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --query "Reservations[0].Instances[0].MetadataOptions" \
    --output json

echo ">>> [2/3] Elevating IMDSv2 HttpPutResponseHopLimit to 2..."
aws ec2 modify-instance-metadata-options \
    --region "${AWS_REGION}" \
    --instance-id "${INSTANCE_ID}" \
    --http-put-response-hop-limit 2 \
    --http-endpoint enabled

echo ">>> [3/3] Verifying updated metadata configuration..."
aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --query "Reservations[0].Instances[0].MetadataOptions" \
    --output json

echo ">>> SUCCESS: Docker containers on bridge networks can now access IMDSv2!"
