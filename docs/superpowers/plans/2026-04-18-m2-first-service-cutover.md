# M2: First Service Cutover (Pilot) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the pilot service's alarms (default: `billing` × `account-dev`) out of the monolithic root module into a dedicated `(service, account-alias)` stack — **without recreating a single alarm in AWS**. Use Terraform 1.7+ `import {}` blocks on the new side and `removed {}` blocks on the old side so the migration is a pure state move.

**Architecture:**
- The pilot stack at `stacks/services/billing/dev/` directly calls library modules from `modules/cloudwatch/metrics-alarm/<type>/`. No composite wrapper yet (that's M5, deferred).
- Backend: `s3://<ORG>-tfstate/account-dev/services/billing/alarms.tfstate` via the Ops `tf-state-access` role. Provider: `account-dev` `tf-deployer` role.
- `project` field is dropped from per-service tfvars; the stack injects `project = var.service` into each module call so existing alarm names stay bit-identical.
- Migration uses a generator script (`scripts/migrate/generate-split.sh`) that reads the old root's state + tfvars and emits two files: `import.tf` (new leaf) and `removed.tf` (old root). The pattern is reusable for M3.
- Pilot rule from spec: pilot must be stable ≥24h before proceeding to billing × stg/prod or any other service.

**Tech Stack:** Terraform ≥ 1.10, AWS provider ≥ 5.0, bash, jq, aws CLI.

**Prerequisites:**
- M0 complete: `foundation/ops` applied; `stacks/platform/dev/` applied with SNS topics; `accounts` output readable via `terraform_remote_state`.
- M1 complete: library lives at `modules/cloudwatch/metrics-alarm/<type>/`; old root's `source` paths updated; zero-diff verified.
- Old root has been planned/applied at least once recently so its state reflects current reality.
- Local `terraform` binary ≥ 1.10 (for both `import {}` and `removed {}`).
- `aws` CLI configured to read `account-dev` via the identity used to assume `tf-deployer` (for post-apply alarm audits).
- `jq` installed.

---

## Inputs to fill before executing

| Token | Meaning | Example |
|---|---|---|
| `<ORG>` | State bucket prefix, same as M0 | `acme` |
| `<PILOT_SERVICE>` | The service chosen as the cutover pilot | `billing` |
| `<PILOT_ALIAS>` | Account alias (without `account-` prefix in repo dir) | `dev` |
| `<PRIMARY_REGION>` | Target account's primary region | `ap-northeast-1` |
| `<OPS_ACCOUNT_ID>` | 12-digit Ops account ID | `999999999999` |
| `<OPS_STATE_ROLE_ARN>` | `arn:aws:iam::<OPS_ACCOUNT_ID>:role/tf-state-access` | `arn:aws:iam::999999999999:role/tf-state-access` |
| `<PILOT_ACCOUNT_ID>` | Target account's 12-digit ID | `111111111111` |
| `<PILOT_DEPLOYER_ROLE_ARN>` | `arn:aws:iam::<PILOT_ACCOUNT_ID>:role/tf-deployer` | `arn:aws:iam::111111111111:role/tf-deployer` |
| `<OLD_ROOT_STATE_LOCATION>` | Where the old root's state currently lives | `./terraform.tfstate` (local) |
| `<OLD_ROOT_AWS_PROFILE>` | AWS CLI profile the old root currently uses | `default` |

---

## File Structure

Created in M2:

```
stacks/
└── services/
    └── <PILOT_SERVICE>/
        └── <PILOT_ALIAS>/
            ├── versions.tf         # terraform >= 1.10, aws >= 5.0, backend "s3" {}
            ├── backend.hcl         # partial backend (bucket, key, region, kms_key_id, role_arn=Ops)
            ├── providers.tf        # aws + aws.us_east_1; both assume_role into <PILOT_ACCOUNT_ID>/tf-deployer
            ├── variables.tf        # service, ec2_resources, rds_resources, …
            ├── terraform.tfvars    # pilot inventory — no project field
            ├── main.tf             # direct module calls into library; reads platform remote state
            ├── outputs.tf          # alarm_arns, alarm_names re-exports
            ├── import.tf           # transient — deleted in Task 10
            └── .gitignore

scripts/
└── migrate/
    └── generate-split.sh           # reusable generator — used by M3 too

backups/
└── pre-<PILOT_SERVICE>-<PILOT_ALIAS>.tfstate  # snapshot from Task 3

# Modified in M2:
./removed.tf                        # transient — deleted in Task 11
./terraform.tfvars                  # strip <PILOT_SERVICE> entries
```

---

## Task 1: Inventory the pilot's current footprint

Before writing any code, enumerate which resource types `<PILOT_SERVICE>` uses and exactly which resources land under its `project` key in the old root's state. Everything downstream depends on this list.

**Files:**
- Read: `./terraform.tfvars` (old root)
- Read: `<OLD_ROOT_STATE_LOCATION>`

- [ ] **Step 1: List the resource types the pilot uses from the root tfvars**

From the repo root, grep the tfvars for the pilot's project name and note which `*_resources` blocks contain it. Eleven possible types: `alb`, `apigateway`, `asg`, `cloudfront`, `ec2`, `elasticache`, `lambda`, `opensearch`, `rds`, `s3`, `ses`.

Run: `grep -n "project = \"<PILOT_SERVICE>\"" terraform.tfvars`

Expected output: a list of lines inside each `*_resources` block that the pilot participates in. Write them down — you'll need the list in Step 3 and in Task 2.

- [ ] **Step 2: List the pilot's alarms in the live AWS account**

Independent cross-check. With `<OLD_ROOT_AWS_PROFILE>` active:

Run: `AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> aws cloudwatch describe-alarms --alarm-name-prefix "<PILOT_SERVICE>-" --query 'MetricAlarms[].AlarmName' --output text | tr '\t' '\n' | sort > /tmp/pilot-alarms-aws.txt`

Expected: one alarm name per line. This is the source-of-truth list of alarms the cutover must preserve.

Count: `wc -l /tmp/pilot-alarms-aws.txt`

- [ ] **Step 3: List the pilot's alarms in the current Terraform state**

Run: `AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state list | grep 'module.monitor_.*\["<PILOT_SERVICE>"\].aws_cloudwatch_metric_alarm' | sort > /tmp/pilot-alarms-tf.txt`

Expected: one Terraform address per line, e.g. `module.monitor_ec2["billing"].aws_cloudwatch_metric_alarm.cpu["billing-web-1"]`.

Count: `wc -l /tmp/pilot-alarms-tf.txt`

- [ ] **Step 4: Confirm the two counts match**

Run: `wc -l /tmp/pilot-alarms-aws.txt /tmp/pilot-alarms-tf.txt`

Expected: identical line counts. If they differ, **STOP** — the old root's state is out of sync with AWS. Run `terraform apply` in the old root first to reconcile, then repeat Step 3.

A count mismatch after `apply` means something created alarms outside Terraform or Terraform lost them; investigate before proceeding.

- [ ] **Step 5: Save the lists for later tasks**

Run: `mkdir -p backups && cp /tmp/pilot-alarms-{aws,tf}.txt backups/`

These become the ground truth for Task 9 verification.

---

## Task 2: Build the migration generator script

One script generates the `import.tf` + `removed.tf` pair from the old root's state. Reusable across every M3 cutover — worth writing carefully once.

**Files:**
- Create: `scripts/migrate/generate-split.sh`

- [ ] **Step 1: Create the script directory**

Run: `mkdir -p scripts/migrate`

- [ ] **Step 2: Write the generator script**

Create `scripts/migrate/generate-split.sh`:

```bash
#!/usr/bin/env bash
# Emits import.tf (for the new leaf) and removed.tf (for the old root),
# based on the old root's current state and the caller-supplied service name.
#
# Usage: scripts/migrate/generate-split.sh <service> <leaf-dir>
# Example: scripts/migrate/generate-split.sh billing stacks/services/billing/dev
#
# Prerequisites:
#   - Run from the repo root (the directory containing the old root's main.tf).
#   - `terraform state list` must work here (correct AWS credentials, initialized).
#   - The leaf-dir must already exist.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <service> <leaf-dir>" >&2
  exit 1
fi

SERVICE="$1"
LEAF_DIR="$2"

if [[ ! -d "$LEAF_DIR" ]]; then
  echo "Error: leaf dir $LEAF_DIR does not exist" >&2
  exit 1
fi

# 1. Pull every TF address that matches the pilot service in the old root.
mapfile -t addrs < <(terraform state list | grep -E "^module\.monitor_[a-z]+\[\"${SERVICE}\"\]\.aws_cloudwatch_metric_alarm\." | sort)

if [[ ${#addrs[@]} -eq 0 ]]; then
  echo "Error: no state entries matched module.monitor_*[\"${SERVICE}\"].aws_cloudwatch_metric_alarm.* " >&2
  exit 1
fi

# 2. Collect the distinct resource-type prefixes (ec2, rds, …) so we can emit
#    one `removed {}` block per module instance instead of one per alarm.
declare -A removed_seen=()
for a in "${addrs[@]}"; do
  # module.monitor_ec2["billing"] -> monitor_ec2
  mod_instance=$(echo "$a" | sed -E 's|^(module\.monitor_[a-z]+\["'"${SERVICE}"'"\]).*|\1|')
  removed_seen["$mod_instance"]=1
done

# 3. Emit import.tf in the leaf dir.
IMPORT_FILE="$LEAF_DIR/import.tf"
{
  echo "# AUTO-GENERATED by scripts/migrate/generate-split.sh"
  echo "# Delete this file after the first successful apply in ${LEAF_DIR}."
  echo
  for a in "${addrs[@]}"; do
    # module.monitor_ec2["billing"].aws_cloudwatch_metric_alarm.cpu["billing-web-1"]
    #   -> resource address in NEW leaf: module.ec2_alarms.aws_cloudwatch_metric_alarm.cpu["billing-web-1"]
    type=$(echo "$a" | sed -E 's|^module\.monitor_([a-z]+)\[.*|\1|')
    tail=$(echo "$a"  | sed -E 's|^module\.monitor_[a-z]+\["[^"]+"\]\.(.*)|\1|')
    new_addr="module.${type}_alarms.${tail}"
    alarm_name=$(terraform state show "$a" 2>/dev/null | awk -F'"' '/^ *alarm_name *=/ {print $2; exit}')
    if [[ -z "$alarm_name" ]]; then
      echo "Error: could not read alarm_name for $a" >&2
      exit 1
    fi
    echo "import {"
    echo "  to = ${new_addr}"
    echo "  id = \"${alarm_name}\""
    echo "}"
    echo
  done
} > "$IMPORT_FILE"

# 4. Emit removed.tf in the old root dir (current working dir).
REMOVED_FILE="./removed.tf"
{
  echo "# AUTO-GENERATED by scripts/migrate/generate-split.sh"
  echo "# Delete this file after the first successful apply in the old root."
  echo
  for mod_instance in "${!removed_seen[@]}"; do
    echo "removed {"
    echo "  from = ${mod_instance}"
    echo "  lifecycle {"
    echo "    destroy = false"
    echo "  }"
    echo "}"
    echo
  done
} > "$REMOVED_FILE"

echo "Wrote $IMPORT_FILE   ($(grep -c '^import {' "$IMPORT_FILE") import blocks)"
echo "Wrote $REMOVED_FILE  ($(grep -c '^removed {' "$REMOVED_FILE") removed blocks)"
```

- [ ] **Step 3: Make it executable**

Run: `chmod +x scripts/migrate/generate-split.sh`

- [ ] **Step 4: Commit**

```bash
git add scripts/migrate/generate-split.sh
git commit -m "feat(migrate): Add state-split generator script for service cutovers.

Reads the old root's Terraform state for a given service and emits
(a) import.tf in the new leaf with one import block per alarm and
(b) removed.tf in the old root with one removed block per monitor_*
module instance keyed by that service.

Used by M2 pilot (billing x dev) and reused for every M3 cutover."
```

---

## Task 3: Snapshot the old root's state

Safety net. If M2 wedges somewhere, restoring this puts the world back to before the cutover.

**Files:**
- Create: `backups/pre-<PILOT_SERVICE>-<PILOT_ALIAS>.tfstate`
- Create: `backups/pre-<PILOT_SERVICE>-<PILOT_ALIAS>.tfstate.sha256`

- [ ] **Step 1: Pull state to a timestamped backup**

From the repo root, with `<OLD_ROOT_AWS_PROFILE>` active:

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state pull > backups/pre-<PILOT_SERVICE>-<PILOT_ALIAS>.tfstate
cp backups/pre-<PILOT_SERVICE>-<PILOT_ALIAS>.tfstate backups/pre-<PILOT_SERVICE>-<PILOT_ALIAS>-${TS}.tfstate
sha256sum backups/pre-<PILOT_SERVICE>-<PILOT_ALIAS>.tfstate > backups/pre-<PILOT_SERVICE>-<PILOT_ALIAS>.tfstate.sha256
```

- [ ] **Step 2: Sanity-check the snapshot**

Run: `jq '.terraform_version, (.resources | length)' backups/pre-<PILOT_SERVICE>-<PILOT_ALIAS>.tfstate`

Expected: a terraform version string and a resource count > 0. Non-zero means the snapshot is non-empty, which is correct at this point.

- [ ] **Step 3: Commit the snapshot**

```bash
git add backups/
git commit -m "backup: Snapshot old-root state before <PILOT_SERVICE>-<PILOT_ALIAS> cutover.

Retained for 30 days per spec's safety-nets section. Restore via
\`terraform state push backups/pre-<PILOT_SERVICE>-<PILOT_ALIAS>.tfstate\`
if the cutover needs to be reversed."
```

---

## Task 4: Scaffold the pilot leaf directory — non-Terraform files

Small files that don't need working Terraform to verify. Laying these down first lets Task 5 focus on the module wiring.

**Files:**
- Create: `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/.gitignore`
- Create: `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/backend.hcl`
- Create: `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/versions.tf`

- [ ] **Step 1: Create the directory**

Run: `mkdir -p stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>`

- [ ] **Step 2: Write the leaf `.gitignore`**

Create `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/.gitignore`:

```gitignore
.terraform/
.terraform.lock.hcl
terraform.tfstate
terraform.tfstate.backup
tfplan.bin
```

- [ ] **Step 3: Write `backend.hcl`**

Create `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/backend.hcl`:

```hcl
bucket       = "<ORG>-tfstate"
key          = "account-<PILOT_ALIAS>/services/<PILOT_SERVICE>/alarms.tfstate"
region       = "<PRIMARY_REGION>"
encrypt      = true
kms_key_id   = "alias/tfstate"
use_lockfile = true
role_arn     = "<OPS_STATE_ROLE_ARN>"
```

- [ ] **Step 4: Write `versions.tf`**

Create `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  backend "s3" {}
}
```

The backend block is empty; partial config comes from `backend.hcl` at init time.

- [ ] **Step 5: Commit**

```bash
git add stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/
git commit -m "feat(services): Scaffold pilot leaf for <PILOT_SERVICE> x <PILOT_ALIAS>.

Adds versions.tf, backend.hcl, and .gitignore. Providers and module
wiring follow in subsequent commits."
```

---

## Task 5: Wire providers and variables in the pilot leaf

Two-role-hop: backend role (Task 4) goes to Ops; provider role goes to the target account. Both come from `terraform_remote_state` reads against foundation/ops.

**Files:**
- Create: `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/providers.tf`
- Create: `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/variables.tf`

- [ ] **Step 1: Write `variables.tf`**

Create `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/variables.tf`:

```hcl
variable "service" {
  description = "Service name — injected as `project` into every module call. Must match the value used in the old root's tfvars so alarm names stay identical."
  type        = string
}

variable "alias" {
  description = "Account alias for this stack (without the `account-` prefix)."
  type        = string
}

variable "primary_region" {
  description = "Primary AWS region for this stack's provider."
  type        = string
}

variable "ops_bucket" {
  description = "Ops-account S3 bucket holding all Terraform state."
  type        = string
}

variable "ops_state_role_arn" {
  description = "Role in the Ops account that grants state-bucket access. Used by data.terraform_remote_state.* calls."
  type        = string
}

# -----------------------------------------------------------------------------
# Resource inventories — strictly optional; empty lists disable each module.
# Note: no `project` field inside; the stack injects `project = var.service`.
# -----------------------------------------------------------------------------

variable "alb_resources" {
  type = list(object({
    name = string
    overrides = optional(object({
      severity                       = optional(string)
      description                    = optional(string)
      elb_5xx_threshold              = optional(number)
      target_5xx_threshold           = optional(number)
      unhealthy_host_threshold       = optional(number)
      target_response_time_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "apigateway_resources" {
  type = list(object({
    name = string
    overrides = optional(object({
      severity            = optional(string)
      description         = optional(string)
      error_5xx_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "ec2_resources" {
  type = list(object({
    name = string
    overrides = optional(object({
      severity         = optional(string)
      description      = optional(string)
      cpu_threshold    = optional(number)
      memory_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "asg_resources" {
  type = list(object({
    name             = string
    desired_capacity = number
    overrides = optional(object({
      severity           = optional(string)
      description        = optional(string)
      capacity_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "lambda_resources" {
  type = list(object({
    name       = string
    timeout_ms = number
    overrides = optional(object({
      severity              = optional(string)
      description           = optional(string)
      duration_threshold_ms = optional(number)
    }), {})
  }))
  default = []
}

variable "lambda_concurrency_threshold" {
  type    = number
  default = 900
}

variable "rds_resources" {
  type = list(object({
    name       = string
    is_cluster = optional(bool, false)
    serverless = optional(bool, false)
    overrides = optional(object({
      severity                               = optional(string)
      description                            = optional(string)
      freeable_memory_threshold              = optional(number)
      freeable_memory_threshold_percent      = optional(number)
      cpu_threshold                          = optional(number)
      database_connections_threshold         = optional(number)
      database_connections_threshold_percent = optional(number)
      free_storage_threshold                 = optional(number)
      volume_bytes_used_threshold            = optional(number)
      acu_utilization_threshold              = optional(number)
      serverless_capacity_threshold          = optional(number)
    }), {})
  }))
  default = []
}

variable "s3_resources" {
  type = list(object({
    name = string
    overrides = optional(object({
      severity            = optional(string)
      description         = optional(string)
      error_5xx_threshold = optional(number)
      replication_enabled = optional(bool)
    }), {})
  }))
  default = []
}

variable "elasticache_resources" {
  type = list(object({
    name = string
    overrides = optional(object({
      severity         = optional(string)
      description      = optional(string)
      cpu_threshold    = optional(number)
      memory_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "opensearch_resources" {
  type = list(object({
    name = string
    overrides = optional(object({
      severity                     = optional(string)
      description                  = optional(string)
      cpu_threshold                = optional(number)
      jvm_memory_threshold         = optional(number)
      old_gen_jvm_memory_threshold = optional(number)
      free_storage_threshold       = optional(number)
    }), {})
  }))
  default = []
}

variable "ses_resources" {
  type = list(object({
    name = string
    overrides = optional(object({
      severity              = optional(string)
      description           = optional(string)
      bounce_rate_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "cloudfront_resources" {
  type = list(object({
    distribution_id = string
    name            = optional(string)
    overrides = optional(object({
      severity                 = optional(string)
      description              = optional(string)
      error_4xx_threshold      = optional(number)
      error_5xx_threshold      = optional(number)
      origin_latency_threshold = optional(number)
      cache_hit_rate_threshold = optional(number)
    }), {})
  }))
  default = []
}
```

These mirror the root `variables.tf` minus the outer `project`/`resources` wrapping — each list is now flat because the stack already knows the service.

- [ ] **Step 2: Write `providers.tf`**

Create `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/providers.tf`:

```hcl
data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket   = var.ops_bucket
    key      = "foundation/ops.tfstate"
    region   = var.primary_region
    role_arn = var.ops_state_role_arn
  }
}

locals {
  target_account       = data.terraform_remote_state.foundation.outputs.accounts["account-${var.alias}"]
  tf_deployer_role_arn = local.target_account.tf_deployer_role_arn
}

provider "aws" {
  region = var.primary_region

  assume_role {
    role_arn     = local.tf_deployer_role_arn
    session_name = "tf-services-${var.service}-${var.alias}"
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  assume_role {
    role_arn     = local.tf_deployer_role_arn
    session_name = "tf-services-${var.service}-${var.alias}-us-east-1"
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/variables.tf \
        stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/providers.tf
git commit -m "feat(services): Add variables and providers for <PILOT_SERVICE>-<PILOT_ALIAS> leaf.

Two-role-hop auth: backend assumes Ops tf-state-access (via backend.hcl);
provider assumes target-account tf-deployer (ARN resolved via
terraform_remote_state.foundation.outputs.accounts[\"account-<PILOT_ALIAS>\"])."
```

---

## Task 6: Wire library module calls and outputs in the pilot leaf

Eleven direct calls into `modules/cloudwatch/metrics-alarm/<type>/`, one per resource type, each guarded by `count = length(var.<type>_resources) > 0 ? 1 : 0` so types the pilot doesn't use cost zero.

Also reads the platform stack's remote state for SNS topic ARNs (regional and global).

**Files:**
- Create: `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/main.tf`
- Create: `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/outputs.tf`

- [ ] **Step 1: Write `main.tf`**

Create `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/main.tf`:

```hcl
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket   = var.ops_bucket
    key      = "account-${var.alias}/platform/sns.tfstate"
    region   = var.primary_region
    role_arn = var.ops_state_role_arn
  }
}

locals {
  sns_topic_arns        = data.terraform_remote_state.platform.outputs.sns_topic_arns
  sns_topic_arns_global = data.terraform_remote_state.platform.outputs.sns_topic_arns_global
  project               = var.service
}

module "alb_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/alb"
  count  = length(var.alb_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.alb_resources
  sns_topic_arns = local.sns_topic_arns
}

module "apigateway_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/apigateway"
  count  = length(var.apigateway_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.apigateway_resources
  sns_topic_arns = local.sns_topic_arns
}

module "ec2_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/ec2"
  count  = length(var.ec2_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.ec2_resources
  sns_topic_arns = local.sns_topic_arns
}

module "asg_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/asg"
  count  = length(var.asg_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.asg_resources
  sns_topic_arns = local.sns_topic_arns
}

module "lambda_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/lambda"
  count  = length(var.lambda_resources) > 0 ? 1 : 0

  project               = local.project
  resources             = var.lambda_resources
  sns_topic_arns        = local.sns_topic_arns
  concurrency_threshold = var.lambda_concurrency_threshold
}

module "rds_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/rds"
  count  = length(var.rds_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.rds_resources
  sns_topic_arns = local.sns_topic_arns
}

module "s3_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/s3"
  count  = length(var.s3_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.s3_resources
  sns_topic_arns = local.sns_topic_arns
}

module "elasticache_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/elasticache"
  count  = length(var.elasticache_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.elasticache_resources
  sns_topic_arns = local.sns_topic_arns
}

module "opensearch_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/opensearch"
  count  = length(var.opensearch_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.opensearch_resources
  sns_topic_arns = local.sns_topic_arns
}

module "ses_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/ses"
  count  = length(var.ses_resources) > 0 ? 1 : 0

  project        = local.project
  resources      = var.ses_resources
  sns_topic_arns = local.sns_topic_arns
}

module "cloudfront_alarms" {
  source = "../../../../modules/cloudwatch/metrics-alarm/cloudfront"
  count  = length(var.cloudfront_resources) > 0 ? 1 : 0

  providers = {
    aws = aws.us_east_1
  }

  project        = local.project
  resources      = var.cloudfront_resources
  sns_topic_arns = local.sns_topic_arns_global
}
```

**Important:** the import-generator script (Task 2) expects module labels `<type>_alarms` (e.g., `ec2_alarms`). Do not rename them without also editing the script's `new_addr` template.

- [ ] **Step 2: Write `outputs.tf`**

Create `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/outputs.tf`:

```hcl
output "alarm_arns" {
  description = "Map of resource-type to list of alarm ARNs created by this stack. Empty lists for types the service doesn't use."
  value = {
    alb         = try(module.alb_alarms[0].alarm_arns, [])
    apigateway  = try(module.apigateway_alarms[0].alarm_arns, [])
    ec2         = try(module.ec2_alarms[0].alarm_arns, [])
    asg         = try(module.asg_alarms[0].alarm_arns, [])
    lambda      = try(module.lambda_alarms[0].alarm_arns, [])
    rds         = try(module.rds_alarms[0].alarm_arns, [])
    s3          = try(module.s3_alarms[0].alarm_arns, [])
    elasticache = try(module.elasticache_alarms[0].alarm_arns, [])
    opensearch  = try(module.opensearch_alarms[0].alarm_arns, [])
    ses         = try(module.ses_alarms[0].alarm_arns, [])
    cloudfront  = try(module.cloudfront_alarms[0].alarm_arns, [])
  }
}
```

**Caveat:** the library modules do not yet expose `alarm_arns` — that's a P1 item in M6. Until then, `try(… , [])` returns `[]` because the attribute reference fails. The output compiles and `terraform validate` passes; consumers of the output get empty lists until M6 lands. This is intentional: M6 adds the attribute without needing another edit here.

- [ ] **Step 3: Commit**

```bash
git add stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/main.tf \
        stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/outputs.tf
git commit -m "feat(services): Wire library modules and outputs for <PILOT_SERVICE>-<PILOT_ALIAS>.

main.tf calls each metrics-alarm module guarded by count=0 when the
corresponding *_resources input is empty, so unused types cost nothing.
outputs.tf re-exports alarm_arns per type with try() fallbacks that
gracefully handle missing module outputs until M6 adds them."
```

---

## Task 7: Populate the pilot's `terraform.tfvars`

Move `<PILOT_SERVICE>`'s resources out of the root tfvars and into the new leaf. Shape differs: no outer `project`/`resources` wrap, each list is flat.

**Files:**
- Create: `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/terraform.tfvars`
- Modify: `./terraform.tfvars` (delete pilot entries in Task 8, **not here**)

- [ ] **Step 1: Compose the pilot tfvars file**

Create `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/terraform.tfvars`. Use your actual resource list from Task 1. Template:

```hcl
service        = "<PILOT_SERVICE>"
alias          = "<PILOT_ALIAS>"
primary_region = "<PRIMARY_REGION>"
ops_bucket     = "<ORG>-tfstate"
ops_state_role_arn = "<OPS_STATE_ROLE_ARN>"

# Populate each list with the entries that lived under `{ project = "<PILOT_SERVICE>", resources = [...] }`
# in the old root's terraform.tfvars. Copy each inner `resources` list verbatim here.

ec2_resources = [
  # { name = "billing-web-1" },
  # { name = "billing-web-2", overrides = { cpu_threshold = 90 } },
]

rds_resources = [
  # { name = "billing-main-db", overrides = { freeable_memory_threshold = 1073741824 } },
]

# … add other *_resources blocks for every type the pilot uses.
# Types the pilot doesn't use are omitted; their defaults (= []) keep the module count=0.
```

Do not leave commented-out example entries in your final file. They're shown above only to illustrate shape.

- [ ] **Step 2: Verify inventory completeness against Task 1's Step 2 list**

Run locally from the leaf dir:

```bash
cd stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>
# Extract the names you just declared, compared to the alarm list from Task 1.
grep -oE 'name += +"[^"]+"' terraform.tfvars | sort -u > /tmp/pilot-leaf-names.txt
diff /tmp/pilot-leaf-names.txt <(awk -F'[][]' '/^'$SERVICE'-/ {print "name = \""$2"\""}' backups/pilot-alarms-aws.txt | sort -u)
```

Expected: no diff, OR a diff that you can explain (e.g., CloudFront uses `distribution_id` not `name`, so those entries are in a different column).

- [ ] **Step 3: Commit**

```bash
git add stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/terraform.tfvars
git commit -m "feat(services): Populate <PILOT_SERVICE>-<PILOT_ALIAS> tfvars.

Mirrors the resources currently under project=\"<PILOT_SERVICE>\" in the
old root tfvars, minus the project field (now injected by the stack
as project=var.service). Root tfvars still points at these resources;
they will be removed in Task 10 once the new leaf's import apply lands."
```

---

## Task 8: Generate `import.tf` + `removed.tf` via the script

Single script run produces both halves of the state-move. Don't hand-edit the outputs — if something looks wrong, fix the script.

**Files:**
- Create (generated): `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/import.tf`
- Create (generated): `./removed.tf`

- [ ] **Step 1: Run the generator from the repo root**

With `<OLD_ROOT_AWS_PROFILE>` active (the script uses the old root's state):

```bash
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> \
  scripts/migrate/generate-split.sh \
  <PILOT_SERVICE> \
  stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>
```

Expected stdout:
```
Wrote stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/import.tf   (N import blocks)
Wrote ./removed.tf  (M removed blocks)
```

where `N` equals the line count of `backups/pilot-alarms-tf.txt` from Task 1 Step 3, and `M` equals the number of distinct resource types `<PILOT_SERVICE>` uses.

- [ ] **Step 2: Sanity-check `import.tf`**

Run: `head -20 stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/import.tf`

Expected: each block has a `to = module.<type>_alarms.aws_cloudwatch_metric_alarm.<metric>["<name>"]` and an `id = "<PILOT_SERVICE>-<Type>-[<name>]-<MetricName>"`.

- [ ] **Step 3: Sanity-check `removed.tf`**

Run: `cat removed.tf`

Expected: one block per module instance the pilot uses, e.g.:

```hcl
removed {
  from = module.monitor_ec2["<PILOT_SERVICE>"]
  lifecycle {
    destroy = false
  }
}
```

- [ ] **Step 4: Do NOT commit yet**

These are transient files. Task 11 deletes them. Commit only after the full cutover succeeds — otherwise the diff has to be reverted atomically. See Task 12 for the combined commit strategy.

---

## Task 9: Initialize and apply the pilot leaf (import phase)

This is the first real apply. `terraform apply` will execute the import blocks and expect zero resource diffs beyond them.

**Files:**
- No new files. State is written to S3.

- [ ] **Step 1: Initialize with partial backend config**

```bash
cd stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>
terraform init -backend-config=backend.hcl
```

Expected: "Terraform has been successfully initialized!" Provider plugins download; state bucket key `account-<PILOT_ALIAS>/services/<PILOT_SERVICE>/alarms.tfstate` is confirmed accessible.

If this step fails with an auth error, your caller identity can't assume `<OPS_STATE_ROLE_ARN>` — fix the trust policy before continuing.

- [ ] **Step 2: Validate**

Run: `terraform validate`

Expected: "Success! The configuration is valid."

- [ ] **Step 3: Plan**

Run: `terraform plan -out=tfplan.bin`

Expected summary:
```
Plan: 0 to add, 0 to change, 0 to destroy.
<N> to import.
```

If you see **any** "to add" or "to change" entries: **STOP**. Either the tfvars in Task 7 don't match the old root's inventory, or the alarm name patterns drifted between the library version being imported and the old root's state. Inspect the diff; most likely you'll need to edit the tfvars (Task 7) or fix a library module rename you missed in M1.

- [ ] **Step 4: Review the plan**

Run: `terraform show -json tfplan.bin | jq '.resource_drift, (.resource_changes | length)'`

Expected: `null` for drift, `<N>` for the imports count.

- [ ] **Step 5: Apply the imports**

Run: `terraform apply tfplan.bin`

Expected: `Apply complete! Resources: <N> imported, 0 added, 0 changed, 0 destroyed.`

- [ ] **Step 6: Re-plan to confirm steady state**

Run: `terraform plan -detailed-exitcode`

Expected: exit code `0` (no changes). If exit code `2`, something drifts between your tfvars and the live alarms — investigate before proceeding.

At this point the alarms exist in **two** Terraform states simultaneously: the old root still thinks it owns them, and the new leaf now thinks it owns them too. That is fine for a few minutes because no one is going to apply until Task 10. But do not leave this state overnight.

- [ ] **Step 7: Do NOT commit the S3 state**

Nothing to git-commit for this step — state lives in S3.

---

## Task 10: Apply the old root `removed {}` blocks (state-only removal)

Old-root side of the cutover. The `removed` blocks with `lifecycle { destroy = false }` drop resources from the old root's state without deleting anything in AWS.

**Files:**
- Modify: `./terraform.tfvars` (strip pilot entries)
- Use: `./removed.tf` (from Task 8)

- [ ] **Step 1: Remove pilot entries from root tfvars**

Edit `./terraform.tfvars` and delete every `{ project = "<PILOT_SERVICE>", resources = [...] }` block inside every `*_resources = [...]` list. Leave other projects untouched.

Example before:
```hcl
ec2_resources = [
  { project = "<PILOT_SERVICE>", resources = [{ name = "<PILOT_SERVICE>-web-1" }] },
  { project = "other-service",    resources = [{ name = "other-web-1" }] },
]
```

After:
```hcl
ec2_resources = [
  { project = "other-service",    resources = [{ name = "other-web-1" }] },
]
```

- [ ] **Step 2: Plan from the repo root**

```bash
cd <REPO_ROOT>
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform plan -out=tfplan-removed.bin
```

Expected summary:
```
Plan: 0 to add, 0 to change, 0 to destroy.
<M> to forget.
```

where `M` matches the number of `removed` blocks (one per monitor_<type> module instance the pilot used).

Critical: **any `to destroy` count greater than 0 means the `removed` block is misconfigured** (`destroy = false` must be present in every block). **STOP** and re-run `scripts/migrate/generate-split.sh` — do NOT apply.

- [ ] **Step 3: Apply the removal**

Run: `AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform apply tfplan-removed.bin`

Expected: `Apply complete! Resources: 0 added, 0 changed, 0 destroyed, <M> forgotten.`

- [ ] **Step 4: Re-plan the old root to confirm no pilot residue**

Run: `AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform plan -detailed-exitcode`

Expected: exit code `0` (no changes).

- [ ] **Step 5: Confirm no `<PILOT_SERVICE>` entries remain in the old root state**

Run: `AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state list | grep "<PILOT_SERVICE>" || echo "clean"`

Expected: `clean` (grep finds nothing).

---

## Task 11: Verify zero-flicker cutover

The AWS alarms should be bit-identical: same names, same config, **and same `AlarmConfigurationUpdatedTimestamp`** as before the cutover.

**Files:**
- Create: `backups/post-<PILOT_SERVICE>-<PILOT_ALIAS>-audit.json`

- [ ] **Step 1: Capture post-cutover alarm config timestamps**

With the pilot account's profile/role active:

```bash
aws cloudwatch describe-alarms --alarm-name-prefix "<PILOT_SERVICE>-" \
  --query 'MetricAlarms[].[AlarmName, AlarmConfigurationUpdatedTimestamp]' \
  --output json > backups/post-<PILOT_SERVICE>-<PILOT_ALIAS>-audit.json
```

- [ ] **Step 2: Sort and confirm every timestamp predates Task 9**

Run:

```bash
jq -r '.[] | .[1]' backups/post-<PILOT_SERVICE>-<PILOT_ALIAS>-audit.json | sort | head -5
```

Expected: the *earliest* timestamp is whenever the alarm was originally created; the *latest* is whenever it was last edited — both of which should be **before** you started Task 9.

If any timestamp falls **inside the cutover window** (between Task 9 Step 5 and now), an alarm got recreated. Correlate the alarm name to the offending import block, restore from `backups/pre-<PILOT_SERVICE>-<PILOT_ALIAS>.tfstate` (see Rollback section), and retry.

- [ ] **Step 3: Confirm alarm count matches pre-cutover**

```bash
aws cloudwatch describe-alarms --alarm-name-prefix "<PILOT_SERVICE>-" \
  --query 'length(MetricAlarms)' --output text
```

Expected: same count as `wc -l < backups/pilot-alarms-aws.txt` from Task 1.

- [ ] **Step 4: Commit the audit artifact**

```bash
git add backups/post-<PILOT_SERVICE>-<PILOT_ALIAS>-audit.json
git commit -m "audit: Post-cutover alarm timestamps for <PILOT_SERVICE>-<PILOT_ALIAS>.

Confirms zero-flicker migration: no AlarmConfigurationUpdatedTimestamp
falls inside the M2 cutover window, proving Terraform executed the
state move without recreating any alarm."
```

---

## Task 12: Clean up one-shot migration files

`import.tf` and `removed.tf` are transient — they must not sit in the repo forever, or the next `terraform plan` after any inventory edit will re-attempt imports / removals.

**Files:**
- Delete: `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/import.tf`
- Delete: `./removed.tf`

- [ ] **Step 1: Delete both files**

```bash
rm stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/import.tf
rm ./removed.tf
```

- [ ] **Step 2: Plan the old root to confirm clean**

Run: `AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform plan -detailed-exitcode`

Expected: exit `0`.

- [ ] **Step 3: Plan the pilot leaf to confirm clean**

```bash
cd stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>
terraform plan -detailed-exitcode
```

Expected: exit `0`.

- [ ] **Step 4: Commit the cleanup**

```bash
cd <REPO_ROOT>
git add -A
git commit -m "chore(migrate): Remove transient import/removed blocks after <PILOT_SERVICE>-<PILOT_ALIAS> cutover.

The one-shot state-move files generated by scripts/migrate/generate-split.sh
are no longer needed; Terraform plans for both the old root and the new
leaf return zero diff."
```

---

## Task 13: Pilot stability window (24h wait)

Per spec M2 pilot rule: wait ~24h before proceeding to M3. During this window, observe alarms in the target account (no new PagerDuty pages? no CloudWatch config drift?). If anything looks off, use the Rollback section below.

- [ ] **Step 1: Set a calendar reminder or issue to re-check the pilot stack 24h from now**
- [ ] **Step 2: Optional — trigger a test alarm via `aws cloudwatch set-alarm-state` to confirm SNS delivery still routes correctly through the new platform topics**

Example:

```bash
aws cloudwatch set-alarm-state \
  --alarm-name "<PILOT_SERVICE>-EC2-[<some-instance>]-CPUUtilization" \
  --state-value ALARM \
  --state-reason "M2 cutover smoke test" \
  --state-value OK  # flip back right away
```

Confirm the notification arrived in your Slack/email channel for the correct severity level.

---

## Verification summary (all phases)

After Task 12 the repo state must satisfy all of these:

1. **Two clean plans.** `terraform plan -detailed-exitcode` exits `0` in both the old root and `stacks/services/<PILOT_SERVICE>/<PILOT_ALIAS>/`.
2. **Alarm counts match.** `aws cloudwatch describe-alarms --alarm-name-prefix "<PILOT_SERVICE>-"` returns the same count as `backups/pilot-alarms-aws.txt`.
3. **No alarms recreated.** No `AlarmConfigurationUpdatedTimestamp` in the post-cutover audit falls inside the cutover window.
4. **Old root owns no pilot resources.** `terraform state list` in the old root returns nothing matching `<PILOT_SERVICE>`.
5. **No transient files left.** `find stacks scripts -name import.tf -o -name removed.tf` returns nothing outside of `scripts/migrate/`.

---

## Rollback recipe

Use only if Task 11 or Task 12 detects a problem. From the repo root:

```bash
# 1. Restore the old root's state from snapshot.
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state push backups/pre-<PILOT_SERVICE>-<PILOT_ALIAS>.tfstate

# 2. Delete the new leaf's state file from S3 (it's orphaned).
aws s3 rm "s3://<ORG>-tfstate/account-<PILOT_ALIAS>/services/<PILOT_SERVICE>/alarms.tfstate"

# 3. Revert the repo to the pre-M2 commit.
git log --oneline | grep -E "Snapshot old-root state" # find the Task 3 commit SHA
git revert --no-commit <all commits since Task 3>
git commit -m "revert: roll back <PILOT_SERVICE>-<PILOT_ALIAS> cutover"

# 4. Verify no drift.
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform plan -detailed-exitcode
```

The alarms in AWS were never deleted (by design — `destroy = false` in every `removed` block), so rollback is a state-only restore.

---

## Known limitations / edge cases

1. **CloudFront `name` default.** If the pilot has CloudFront resources without an explicit `name`, the alarm uses `distribution_id` in brackets. The generator script reads `alarm_name` straight from state, so it handles both cases automatically — but double-check Step 2 of Task 8's sanity-check output.
2. **RDS cluster vs standalone.** The RDS module splits resources internally into `cluster_resources` and `standalone_resources` based on `is_cluster`. The generator script doesn't need to know this — it copies `alarm_name` from state, which is already correct. Just ensure `is_cluster = true` is preserved in the new leaf's tfvars.
3. **Lambda account-concurrency alarm.** Named `<project>-Lambda-[Account]-ClaimedAccountConcurrency` (singleton, not per-function). It's included in the generator's output as long as it's in the old root state. Confirm it imports cleanly — if the new leaf has no `lambda_resources`, the module is `count = 0` and there's nothing to import to. In that case either add a dummy function or skip this alarm.
4. **If the old root's state isn't local.** Substitute `<OLD_ROOT_STATE_LOCATION>`-aware commands for every `terraform state pull` / `terraform state list` step. `terraform_remote_state` reads from other backends aren't required because we operate on the old root in-place.
5. **`alarm_name` character set.** Brackets in alarm names (`[resource-name]`) survive round-trips through `aws cloudwatch describe-alarms`; no escaping needed in the `import.tf` `id` field.
