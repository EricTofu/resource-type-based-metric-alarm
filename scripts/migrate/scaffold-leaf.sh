#!/usr/bin/env bash
# Copies the shape of stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/ (from M2)
# into a new leaf for <service> x <alias>. Copies the invariant files
# verbatim; generates backend.hcl and a skeleton terraform.tfvars.
#
# Usage: scripts/migrate/scaffold-leaf.sh <service> <alias>
# Example: scripts/migrate/scaffold-leaf.sh checkout dev
#
# Must be run from the repo root.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <service> <alias>" >&2
  exit 1
fi

SERVICE="$1"
ALIAS="$2"

: "${ORG:?ORG environment variable required, e.g. export ORG=<ORG>}"
: "${PRIMARY_REGION:?PRIMARY_REGION required, e.g. export PRIMARY_REGION=<PRIMARY_REGION>}"
: "${OPS_STATE_ROLE_ARN:?OPS_STATE_ROLE_ARN required}"
: "${PILOT_SERVICE:?PILOT_SERVICE required — the service cut over in M2}"
: "${PILOT_ALIAS:?PILOT_ALIAS required — the alias cut over in M2}"

SRC="stacks/services/$PILOT_SERVICE/$PILOT_ALIAS"
DST="stacks/services/$SERVICE/$ALIAS"

if [[ ! -d "$SRC" ]]; then
  echo "Error: pilot leaf $SRC not found. Did M2 finish?" >&2
  exit 1
fi

if [[ -e "$DST" ]]; then
  echo "Error: $DST already exists. Refusing to overwrite." >&2
  exit 1
fi

mkdir -p "$DST"

# Invariant files — same in every leaf.
for f in versions.tf providers.tf variables.tf main.tf outputs.tf .gitignore; do
  cp "$SRC/$f" "$DST/$f"
done

# backend.hcl — varies per leaf.
cat > "$DST/backend.hcl" <<EOF
bucket       = "${ORG}-tfstate"
key          = "account-${ALIAS}/services/${SERVICE}/alarms.tfstate"
region       = "${PRIMARY_REGION}"
encrypt      = true
kms_key_id   = "alias/tfstate"
use_lockfile = true
role_arn     = "${OPS_STATE_ROLE_ARN}"
EOF

# terraform.tfvars — skeleton with service-specific header + empty lists.
# The operator fills in the inventory before running Task 4.
cat > "$DST/terraform.tfvars" <<EOF
service        = "${SERVICE}"
alias          = "${ALIAS}"
aws_region     = "${PRIMARY_REGION}"
ops_bucket     = "${ORG}-tfstate"
ops_state_role_arn = "${OPS_STATE_ROLE_ARN}"
lambda_concurrency_threshold = 80

# TODO(operator): fill each *_resources list from the old root's terraform.tfvars
# entries where project == "${SERVICE}". Types the service doesn't use stay at [].
alb_resources          = []
apigateway_resources   = []
asg_resources          = []
cloudfront_resources   = []
ec2_resources          = []
elasticache_resources  = []
lambda_resources       = []
opensearch_resources   = []
rds_resources          = []
s3_resources           = []
ses_resources          = []

common_tags = {
  ManagedBy = "Terraform"
  Project   = "${SERVICE}"
}
EOF

echo "Scaffolded $DST"
echo "Next: fill $DST/terraform.tfvars with the old root's entries for project=\"${SERVICE}\""