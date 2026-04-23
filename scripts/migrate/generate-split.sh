#!/usr/bin/env bash
# Emits import.tf (for the new leaf) and removed.tf (for the old root),
# based on the old root's current state and the caller-supplied service name.
#
# Usage: scripts/migrate/generate-split.sh <service> <leaf-dir>
# Example: scripts/migrate/generate-split.sh billing stacks/services/billing/dev
#
# Prerequisites:
#   - Run from the repo root (the directory containing the old root's main.tf).
#   - AWS_PROFILE is set to the profile used by the old root.
#   - jq and terraform are on PATH.
#
# Outputs:
#   - <leaf-dir>/import.tf (import blocks for the new leaf; delete after apply)
#   - ./removed.tf          (removed blocks for the old root; delete after apply)

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <service> <leaf-dir>" >&2
  exit 1
fi

SERVICE="$1"
LEAF_DIR="$2"

command -v jq      >/dev/null || { echo "Error: jq is required." >&2; exit 1; }
command -v terraform >/dev/null || { echo "Error: terraform is required." >&2; exit 1; }

echo "Pulling Terraform state..."
STATE_JSON=$(terraform state pull)

# Filter alarms for the target service.
# Uses --arg to bind the shell variable as a jq string variable ($service).
echo "Filtering alarms for service '$SERVICE'..."
ALARMS=$(echo "$STATE_JSON" | jq -c --arg service "$SERVICE" '
  .resources[]
  | select(.type == "aws_cloudwatch_metric_alarm")
  | select(.module != null and (.module | test("module\\.monitor_[a-z]+\\[\"" + $service + "\"\\]")))
  | { module: .module, type: .type, name: .name, alarm_name: .instances[0].attributes.alarm_name }
')

if [[ -z "$ALARMS" ]]; then
  echo "No alarms found for service '$SERVICE'. Check your AWS_PROFILE and that the service name matches a project key in tfvars." >&2
  exit 1
fi

ALARM_COUNT=$(echo "$ALARMS" | wc -l)
echo "Found $ALARM_COUNT alarm(s) for '$SERVICE'."

# Generate import.tf for the leaf
IMPORT_FILE="$LEAF_DIR/import.tf"
echo "Generating $IMPORT_FILE..."
cat > "$IMPORT_FILE" <<'HEADER'
# Auto-generated import blocks for service cutover.
# Delete this file after: cd <leaf-dir> && terraform apply
HEADER

echo "$ALARMS" | while IFS= read -r alarm; do
  module=$(echo "$alarm" | jq -r '.module')
  type=$(echo "$alarm"   | jq -r '.type')
  name=$(echo "$alarm"   | jq -r '.name')
  id=$(echo "$alarm"     | jq -r '.alarm_name')
  printf '\nimport {\n  to = %s.%s.%s\n  id = "%s"\n}\n' "$module" "$type" "$name" "$id"
done >> "$IMPORT_FILE"

# Generate removed.tf for the old root
REMOVED_FILE="./removed.tf"
echo "Generating $REMOVED_FILE..."
cat > "$REMOVED_FILE" <<'HEADER'
# Auto-generated removed blocks for service cutover.
# Delete this file after: cd <repo-root> && terraform apply
HEADER

echo "$ALARMS" | while IFS= read -r alarm; do
  module=$(echo "$alarm" | jq -r '.module')
  type=$(echo "$alarm"   | jq -r '.type')
  name=$(echo "$alarm"   | jq -r '.name')
  printf '\nremoved {\n  from = %s.%s.%s\n\n  lifecycle {\n    destroy = false\n  }\n}\n' "$module" "$type" "$name"
done >> "$REMOVED_FILE"

echo ""
echo "Generated:"
echo "  $IMPORT_FILE  — import blocks for the new leaf"
echo "  $REMOVED_FILE — removed blocks for the old root"
echo ""
echo "Next steps:"
echo "  1. cd $LEAF_DIR && terraform init -backend-config=backend.hcl"
echo "  2. terraform plan -out=tfplan.bin && terraform apply tfplan.bin"
echo "  3. cd <repo-root> && terraform apply   (applies removed blocks)"
echo "  4. Delete import.tf and removed.tf after both applies succeed"
