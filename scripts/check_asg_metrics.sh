#!/usr/bin/env bash
# Checks that every ASG in asg_resources has GroupInServiceInstances metric collection
# enabled. Exits 1 if any ASG is missing the metric.
#
# Usage: check_asg_metrics.sh --tfvars <path>
# Example: check_asg_metrics.sh --tfvars stacks/services/billing/dev/terraform.tfvars

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
m = re.search(r'asg_resources\s*=\s*\[(.*?)\]', content, re.DOTALL)
if not m:
    sys.exit(0)
for name in re.findall(r'name\s*=\s*"([^"]+)"', m.group(1)):
    print(name)
EOF
)

if [[ -z "$NAMES" ]]; then
  echo "No asg_resources found in $TFVARS — skipping."
  exit 0
fi

[[ -n "$REGION" ]] || { echo "Error: aws_region not found in $TFVARS." >&2; exit 1; }

FAILED=0

while IFS= read -r NAME; do
  ENABLED_METRICS=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$NAME" \
    --region "$REGION" \
    --query "AutoScalingGroups[0].EnabledMetrics[*].Metric" \
    --output text 2>/dev/null || true)

  if [[ "$ENABLED_METRICS" != *"GroupInServiceInstances"* ]]; then
    echo "WARNING: Metric 'GroupInServiceInstances' is not enabled for ASG '$NAME' in $REGION. Enable group metrics collection on the ASG." >&2
    FAILED=1
  else
    echo "OK: GroupInServiceInstances enabled for ASG '$NAME'."
  fi
done <<< "$NAMES"

exit "$FAILED"
