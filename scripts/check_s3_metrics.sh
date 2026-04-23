#!/usr/bin/env bash
# Checks that every S3 bucket in s3_resources has the 'EntireBucket' request-metrics
# configuration enabled. Exits 1 if any bucket is missing the configuration.
#
# Usage: check_s3_metrics.sh --tfvars <path>
# Example: check_s3_metrics.sh --tfvars stacks/services/billing/dev/terraform.tfvars

set -euo pipefail

TFVARS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tfvars) TFVARS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TFVARS" ]]; then
  echo "Usage: $0 --tfvars <path>" >&2
  exit 1
fi

[[ -f "$TFVARS" ]] || { echo "Error: $TFVARS not found." >&2; exit 1; }

REGION=$(python3 - "$TFVARS" <<'EOF'
import re, sys
content = open(sys.argv[1]).read()
m = re.search(r'aws_region\s*=\s*"([^"]+)"', content)
print(m.group(1) if m else "")
EOF
)

NAMES=$(python3 - "$TFVARS" <<'EOF'
import re, sys
content = open(sys.argv[1]).read()
m = re.search(r's3_resources\s*=\s*\[(.*?)\]', content, re.DOTALL)
if not m:
    sys.exit(0)
for name in re.findall(r'name\s*=\s*"([^"]+)"', m.group(1)):
    print(name)
EOF
)

if [[ -z "$NAMES" ]]; then
  echo "No s3_resources found in $TFVARS — skipping."
  exit 0
fi

[[ -n "$REGION" ]] || { echo "Error: aws_region not found in $TFVARS." >&2; exit 1; }

FAILED=0

while IFS= read -r NAME; do
  HTTP_CODE=$(aws s3api get-bucket-metrics-configuration \
    --bucket "$NAME" \
    --id "EntireBucket" \
    --region "$REGION" \
    2>&1; echo "EXIT:$?")

  EXIT_CODE=$(echo "$HTTP_CODE" | grep "EXIT:" | cut -d: -f2)
  OUTPUT=$(echo "$HTTP_CODE" | grep -v "EXIT:")

  if [[ "$EXIT_CODE" == "0" ]]; then
    echo "OK: S3 request metrics 'EntireBucket' present for bucket '$NAME'."
  elif echo "$OUTPUT" | grep -q "NoSuchConfiguration\|NoSuchBucket"; then
    echo "WARNING: Request metrics configuration 'EntireBucket' not found for S3 bucket '$NAME'. 5xx/4xx error alarms may not have data." >&2
    FAILED=1
  else
    echo "ERROR: Failed to check metrics configuration for bucket '$NAME': $OUTPUT" >&2
    FAILED=1
  fi
done <<< "$NAMES"

exit "$FAILED"
