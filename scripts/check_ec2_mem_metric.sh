#!/usr/bin/env bash
# Checks that every EC2 instance in ec2_resources has the CWAgent mem_used_percent
# metric publishing to CloudWatch. Exits 1 if any instance is missing the metric.
#
# Usage: check_ec2_mem_metric.sh --tfvars <path>
# Example: check_ec2_mem_metric.sh --tfvars stacks/projects/billing/dev/terraform.tfvars

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

NAMES=$(python3 - "$TFVARS" "ec2_resources" "memory" <<'EOF'
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
  echo "No ec2_resources found in $TFVARS — skipping."
  exit 0
fi

[[ -n "$REGION" ]] || { echo "Error: aws_region not found in $TFVARS." >&2; exit 1; }

FAILED=0

while IFS= read -r NAME; do
  INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running,stopped" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text \
    --region "$REGION" 2>/dev/null || true)

  if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    echo "WARNING: No running/stopped EC2 instance found with Name tag '$NAME' in $REGION." >&2
    FAILED=1
    continue
  fi

  METRIC_EXISTS=$(aws cloudwatch list-metrics \
    --namespace CWAgent \
    --metric-name mem_used_percent \
    --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
    --region "$REGION" \
    --query "length(Metrics)" \
    --output text 2>/dev/null || echo "0")

  if [[ "$METRIC_EXISTS" == "0" || -z "$METRIC_EXISTS" ]]; then
    echo "WARNING: CWAgent metric 'mem_used_percent' not found for instance '$NAME' ($INSTANCE_ID) in $REGION. Install and configure the CloudWatch Agent." >&2
    FAILED=1
  else
    echo "OK: mem_used_percent present for '$NAME' ($INSTANCE_ID)."
  fi
done <<< "$NAMES"

exit "$FAILED"
