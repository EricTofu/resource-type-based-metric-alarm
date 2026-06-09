#!/usr/bin/env bash
# Copies the shape of stacks/projects/<PILOT_PROJECT>/<PILOT_ENV>/ (from M2)
# into a new leaf for <project> x <env>. Copies invariant files verbatim;
# generates a per-leaf backend.hcl and skeleton terraform.tfvars.
#
# Usage: scripts/migrate/scaffold-leaf.sh <project> <env>
# Example: scripts/migrate/scaffold-leaf.sh checkout dev
#
# Required environment variables:
#   ORG                — state bucket name prefix (e.g. acme)
#   PRIMARY_REGION     — AWS region (e.g. ap-northeast-1)
#   OPS_STATE_ROLE_ARN — ARN of the tf-state-access role in the Ops account
#   PILOT_PROJECT      — project that was cut over in M2 (template source)
#   PILOT_ENV          — env that was cut over in M2 (template source)
#
# Must be run from the repo root.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <project> <env>" >&2
  exit 1
fi

PROJECT="$1"
ENV="$2"

: "${ORG:?ORG environment variable required, e.g. export ORG=acme}"
: "${PRIMARY_REGION:?PRIMARY_REGION required, e.g. export PRIMARY_REGION=ap-northeast-1}"
: "${OPS_STATE_ROLE_ARN:?OPS_STATE_ROLE_ARN required}"
: "${PILOT_PROJECT:?PILOT_PROJECT required — the project cut over in M2}"
: "${PILOT_ENV:?PILOT_ENV required — the env cut over in M2}"

SRC="stacks/projects/$PILOT_PROJECT/$PILOT_ENV"
DST="stacks/projects/$PROJECT/$ENV"

[[ -d "$SRC" ]] || {
  echo "Error: pilot leaf $SRC not found. Did M2 finish?" >&2
  exit 1
}
[[ -e "$DST" ]] && {
  echo "Error: $DST already exists. Refusing to overwrite." >&2
  exit 1
}

mkdir -p "$DST"

for f in versions.tf providers.tf variables.tf main.tf outputs.tf .gitignore; do
  cp "$SRC/$f" "$DST/$f"
done

cat >"$DST/backend.hcl" <<EOF
bucket       = "${ORG}-tfstate"
key          = "${ENV}/projects/${PROJECT}/alarms.tfstate"
region       = "${PRIMARY_REGION}"
encrypt      = true
kms_key_id   = "alias/tfstate"
use_lockfile = true
role_arn     = "${OPS_STATE_ROLE_ARN}"
EOF

cat >"$DST/terraform.tfvars" <<EOF
project            = "${PROJECT}"
env                = "${ENV}"
aws_region         = "${PRIMARY_REGION}"
ops_bucket         = "${ORG}-tfstate"
ops_state_role_arn = "${OPS_STATE_ROLE_ARN}"

lambda_concurrency_threshold = 900

common_tags = {
  ManagedBy   = "terraform"
  Environment = "${ENV}"
}

# TODO: fill each *_resources list from the old root's terraform.tfvars
# entries where project == "${PROJECT}". Types the project does not use stay as [].
alb_resources         = []
apigateway_resources  = []
asg_resources         = []
cloudfront_resources  = []
ec2_resources         = []
elasticache_resources = []
lambda_resources      = []
opensearch_resources  = []
rds_resources         = []
s3_resources          = []
ses_resources         = []
EOF

echo "Scaffolded $DST"
echo "Next: fill $DST/terraform.tfvars with the old root's entries for project=\"${PROJECT}\""
