#!/usr/bin/env bash
# Checks that every S3 bucket in s3_resources has the 'EntireBucket' request-metrics
# configuration enabled. Exits 1 if any bucket is missing the configuration.
#
# Usage: check_s3_metrics.sh --tfvars <path>
# Example: check_s3_metrics.sh --tfvars stacks/projects/billing/dev/terraform.tfvars

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

NAMES=$(python3 - "$TFVARS" "s3_resources" "error_5xx" <<'EOF'
import re, sys
content = open(sys.argv[1]).read()
list_var, metric = sys.argv[2], sys.argv[3]

start = re.search(rf'{list_var}\s*=\s*\[', content)
if not start:
    sys.exit(0)

# Capture the bracketed list body by bracket depth.
i, depth, body = start.end(), 1, []
while i < len(content) and depth > 0:
    c = content[i]
    if c == '[':
        depth += 1
    elif c == ']':
        depth -= 1
        if depth == 0:
            break
    body.append(c)
    i += 1
body = ''.join(body)

# Split body into top-level { ... } object entries.
entries, depth, cur = [], 0, []
for c in body:
    if c == '{':
        depth += 1
        if depth == 1:
            cur = []
            continue
    if c == '}':
        depth -= 1
        if depth == 0:
            entries.append(''.join(cur))
            continue
    if depth >= 1:
        cur.append(c)

for e in entries:
    nm = re.search(r'name\s*=\s*"([^"]+)"', e)
    if not nm:
        continue
    da = re.search(r'disabled_alarms\s*=\s*\[([^\]]*)\]', e)
    disabled = re.findall(r'"([^"]+)"', da.group(1)) if da else []
    if metric in disabled:
        continue
    print(nm.group(1))
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
