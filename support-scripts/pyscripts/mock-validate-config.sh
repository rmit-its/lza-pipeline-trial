#!/bin/bash
# Mock script: simulates LZA validator
# In production this runs inside the ghcr.io/rmit-its/uelz-lza-lza-validator container
set -euo pipefail

echo "=== Mock: Validating LZA config ==="
sleep 3
echo "✓ network-config.yaml: valid"
echo "✓ accounts-config.yaml: valid"
echo "✓ iam-config.yaml: valid"
echo "✓ customizations-config.yaml: valid"
echo ""
echo "=== LZA Config Validation PASSED ==="
