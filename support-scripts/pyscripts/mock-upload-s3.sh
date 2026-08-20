#!/bin/bash
# Mock script: simulates uploading config zip to S3
# In production: aws s3 cp aws-accelerator-config.zip s3://aws-accelerator-config-{account}/zipped/
set -euo pipefail

ENV="${1:-prd}"
echo "=== Mock: Creating config zip ==="
sleep 1
echo "✓ aws-accelerator-config.zip created (mock)"

if [[ "$ENV" == "prd" ]]; then
  echo "=== Mock: Uploading to S3 ==="
  sleep 2
  echo "✓ Uploaded to s3://aws-accelerator-config-585008077316-ap-southeast-2/zipped/aws-accelerator-config.zip"
else
  echo "=== Skipping S3 upload (environment: ${ENV}, upload only on prd) ==="
fi
