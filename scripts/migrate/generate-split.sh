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
#   - jq is installed.
#   - terraform binary is available.
#
# Outputs:
#   - <leaf-dir>/import.tf (to be applied in the new leaf)
#   - ./removed.tf (to be applied in the old root)

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <service> <leaf-dir>" >&2
  exit 1
fi

SERVICE="$1"
LEAF_DIR="$2"

# Check prerequisites
if ! command -v jq &> /dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

if ! command -v terraform &> /dev/null; then
  echo "Error: terraform is required but not installed." >&2
  exit 1
fi

# Get the old root's state as JSON
echo "Pulling Terraform state..."
STATE_JSON=$(terraform state pull)

# Filter alarms for the target service
echo "Filtering alarms for service '$SERVICE'..."
ALARMS=$(echo "$STATE_JSON" | jq -r '
  .resources[] |
  select(.type == "aws_cloudwatch_metric_alarm") |
  select(.module | test("module\\.monitor_[a-z]+\\[\"" + env.SERVICE + "\"\\]")) |
  {
    module: .module,
    type: .type,
    name: .name,
    instances: .instances[]
  }
' --arg SERVICE "$SERVICE")

# Generate import.tf for the leaf
echo "Generating import.tf..."
IMPORT_FILE="$LEAF_DIR/import.tf"

cat > "$IMPORT_FILE" <<'EOF'
# Auto-generated import blocks for service cutover.
# Delete this file after successful apply.

EOF

echo "$ALARMS" | jq -r '
  @text "import {\n  to = \(.module).\(.type).\(.name)\n  id = \"\(.instances.attributes.alarm_name)\"\n}\n"
' >> "$IMPORT_FILE"

# Generate removed.tf for the old root
echo "Generating removed.tf..."
REMOVED_FILE="./removed.tf"

cat > "$REMOVED_FILE" <<'EOF'
# Auto-generated removed blocks for service cutover.
# Delete this file after successful apply.

EOF

echo "$ALARMS" | jq -r '
  @text "removed {\n  from = \(.module).\(.type).\(.name)\n}\n"
' >> "$REMOVED_FILE"

echo "Generated:"
echo "  - $IMPORT_FILE (import blocks for the new leaf)"
echo "  - $REMOVED_FILE (removed blocks for the old root)"
echo ""
echo "Next steps:"
echo "  1. cd $LEAF_DIR && terraform init -backend-config=backend.hcl"
echo "  2. terraform plan -out=tfplan.bin"
echo "  3. terraform apply tfplan.bin"
echo "  4. cd <REPO_ROOT> && terraform apply (to apply removed blocks)"
echo "  5. Delete import.tf and removed.tf after successful apply"