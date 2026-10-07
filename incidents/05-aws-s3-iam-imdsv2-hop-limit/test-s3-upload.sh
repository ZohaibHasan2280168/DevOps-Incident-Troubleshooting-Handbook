#!/usr/bin/env bash
# ==============================================================================
# Script: test-s3-upload.sh
# Purpose: Validate S3 upload from EC2 host and inside Docker container
# ==============================================================================
set -euo pipefail

BUCKET_NAME="${1:-smartdoc-storage-zohaib-2026}"
TEST_KEY="telemetry-probe-$(date +%s).txt"

echo ">>> [1/2] Testing S3 upload from EC2 host shell..."
echo "Host telemetry probe at $(date)" | aws s3 cp - "s3://${BUCKET_NAME}/${TEST_KEY}"
echo ">>> Host upload successful!"

echo ">>> [2/2] Testing S3 upload from inside smartdoc-backend container..."
docker exec -it smartdoc-backend python -c "
import boto3, sys
try:
    s3 = boto3.client('s3', region_name='us-east-1')
    s3.put_object(
        Bucket='${BUCKET_NAME}',
        Key='container-${TEST_KEY}',
        Body=b'Container telemetry probe verified'
    )
    print('>>> SUCCESS: Container successfully uploaded object via IAM Instance Profile!')
except Exception as e:
    print(f'>>> FAILED: {e}', file=sys.stderr)
    sys.exit(1)
"
