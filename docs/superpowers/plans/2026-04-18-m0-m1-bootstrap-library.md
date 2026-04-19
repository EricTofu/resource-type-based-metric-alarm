# M0 + M1: Foundation Bootstrap & Library Refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the centralized Ops-account foundation (`foundation/ops` — single S3 state bucket, KMS CMK, `tf-state-access` role, `accounts` output) and one `platform/<alias>` stack per target AWS account (SNS topics for WARN/ERROR/CRIT severities, regional + `us-east-1`). Then rename the module library from `modules/monitor-<type>/` to `modules/cloudwatch/metrics-alarm/<type>/`. All work is additive or zero-diff; the existing monolithic root continues to own alarms throughout.

**Architecture:**
- **M0a — foundation/ops:** one Terraform stack in the Ops account. Bootstraps its own state bucket via local-state → `-migrate-state`. Creates the bucket, KMS CMK, and the cross-account `tf-state-access` IAM role. Publishes an `accounts` output mapping each alias (`account-dev`, `account-stg`, `account-prod`, …) to `{id, tf_deployer_role_arn}` so leaf stacks can derive their provider/backend config without hardcoding.
- **M0b — platform/<alias>:** one Terraform stack per target account. Backend writes to `s3://<ORG>-tfstate/account-<alias>/platform/sns.tfstate` via the Ops `tf-state-access` role. AWS provider assumes that account's `tf-deployer` role to create SNS topics (regional + `us-east-1` alias).
- **M1 — library rename:** `git mv modules/monitor-<type>/ modules/cloudwatch/metrics-alarm/<type>/` and update root `main.tf` source paths. Verified by `terraform plan -detailed-exitcode` = 0 on the existing root.

**Tech Stack:** Terraform ≥ 1.10 (required for S3-native state locking via `use_lockfile = true`), AWS provider ≥ 5.0, bash.

**Prerequisite — Ops account and target accounts must exist in AWS Organizations.** Specifically: Ops account is provisioned and you have credentials that can create an IAM role + S3 bucket + KMS CMK there. Each target account has a `tf-deployer` IAM role (or you have permissions to create one) whose trust policy permits assume-role from the human/CI principal running Terraform.

---

## Inputs to fill before executing

This plan uses tokens you must resolve before running any command. Search-and-replace on the plan file, or keep a scratch note.

| Token | Meaning | Example |
|---|---|---|
| `<ORG>` | Short slug used in the state bucket name | `acme` |
| `<PRIMARY_REGION>` | Default provider region for resources and state bucket | `ap-northeast-1` |
| `<OPS_ACCOUNT_ID>` | 12-digit Ops account ID (holds state bucket + KMS CMK) | `999999999999` |
| `<OPS_BOOTSTRAP_PROFILE>` | AWS CLI profile with admin access to the Ops account, used **only** to bootstrap foundation/ops | `myco-ops-admin` |
| `<OPS_STATE_ROLE_ARN>` | ARN of the `tf-state-access` role, known after Task 2 completes. Format: `arn:aws:iam::<OPS_ACCOUNT_ID>:role/tf-state-access` | `arn:aws:iam::999999999999:role/tf-state-access` |
| `<ACCOUNT_ALIASES>` | Ordered list of target account aliases to bootstrap in M0b | `dev stg prod` |
| `<ACCOUNT_ID_<alias>>` | 12-digit account ID for each alias (e.g., `<ACCOUNT_ID_dev>`) | `111111111111` |
| `<TF_DEPLOYER_ROLE_ARN_<alias>>` | ARN of `tf-deployer` in each target account | `arn:aws:iam::111111111111:role/tf-deployer` |
| `<CALLER_PRINCIPAL_ARN>` | ARN of the human/CI identity that will run Terraform (used in trust policies) | `arn:aws:iam::<OPS_ACCOUNT_ID>:user/eric` |
| `<SNS_CHOICE>` | `create` (new topics) or `import` (adopt existing) | `create` |
| `<EXISTING_SNS_ARN_<alias>_<severity>>` | Required only for `<SNS_CHOICE>=import` | `arn:aws:sns:ap-northeast-1:111111111111:warning-alerts` |

---

## File Structure

Created in M0:

```
stacks/
├── foundation/
│   └── ops/
│       ├── versions.tf              # required_version, backend "s3" {}, provider requirements
│       ├── providers.tf             # Ops provider — uses <OPS_BOOTSTRAP_PROFILE> initially
│       ├── variables.tf             # ops_account_id, caller_principal_arn, accounts (map), common_tags
│       ├── main.tf                  # S3 bucket + KMS CMK + tf-state-access IAM role + trust policy
│       ├── outputs.tf               # state_bucket, state_kms_alias, tf_state_access_role_arn, accounts
│       ├── backend.hcl              # partial backend: bucket, key=foundation/ops.tfstate, kms, use_lockfile
│       ├── terraform.tfvars         # gitignored — concrete account IDs and role ARNs
│       └── .gitignore               # terraform.tfvars, *.tfstate*, .terraform/
└── platform/
    ├── dev/
    │   ├── versions.tf              # backend "s3" {}, required_providers
    │   ├── providers.tf             # primary + us-east-1 alias; both assume_role into tf-deployer via remote_state lookup
    │   ├── variables.tf             # alias, aws_region, common_tags
    │   ├── data.tf                  # terraform_remote_state "foundation" — reads accounts map from Ops
    │   ├── main.tf                  # aws_sns_topic.regional / .global (for_each over severities)
    │   ├── outputs.tf               # sns_topic_arns (regional map) + sns_topic_arns_global (us-east-1 map)
    │   ├── backend.hcl              # bucket=<ORG>-tfstate, key=account-dev/platform/sns.tfstate, role_arn=<OPS_STATE_ROLE_ARN>
    │   ├── terraform.tfvars         # gitignored
    │   └── .gitignore
    ├── stg/                         # same files as dev/ with stg values
    └── prod/                        # same files as dev/ with prod values
```

Moved in M1:

```
modules/monitor-alb/           → modules/cloudwatch/metrics-alarm/alb/
modules/monitor-apigateway/    → modules/cloudwatch/metrics-alarm/apigateway/
modules/monitor-asg/           → modules/cloudwatch/metrics-alarm/asg/
modules/monitor-cloudfront/    → modules/cloudwatch/metrics-alarm/cloudfront/
modules/monitor-ec2/           → modules/cloudwatch/metrics-alarm/ec2/
modules/monitor-elasticache/   → modules/cloudwatch/metrics-alarm/elasticache/
modules/monitor-lambda/        → modules/cloudwatch/metrics-alarm/lambda/
modules/monitor-opensearch/    → modules/cloudwatch/metrics-alarm/opensearch/
modules/monitor-rds/           → modules/cloudwatch/metrics-alarm/rds/
modules/monitor-s3/            → modules/cloudwatch/metrics-alarm/s3/
modules/monitor-ses/           → modules/cloudwatch/metrics-alarm/ses/
```

Modified in M1:

- Root `main.tf`: 11 `source` paths updated.
- Root `CLAUDE.md` and `README.md`: path references updated.

---

# M0a — Foundation (Ops account)

## Task 1: Scaffold `stacks/foundation/ops/`

**Files:**
- Create: `stacks/foundation/ops/versions.tf`
- Create: `stacks/foundation/ops/providers.tf`
- Create: `stacks/foundation/ops/variables.tf`
- Create: `stacks/foundation/ops/main.tf`
- Create: `stacks/foundation/ops/outputs.tf`
- Create: `stacks/foundation/ops/.gitignore`

- [ ] **Step 1: Create `stacks/foundation/ops/versions.tf`**

  > The `backend "s3" {}` block is intentionally omitted here. First apply uses local state; backend block is added in Task 2 Step 5 once the bucket exists.

  ```hcl
  terraform {
    required_version = ">= 1.10"

    required_providers {
      aws = {
        source  = "hashicorp/aws"
        version = ">= 5.0"
      }
    }
  }
  ```

- [ ] **Step 2: Create `stacks/foundation/ops/providers.tf`**

  > Uses a named profile during bootstrap. After migration to S3 backend, this file can optionally switch to assume-role or stay as-is — Ops-account admins are the only ones who ever run this stack, so a profile is fine.

  ```hcl
  provider "aws" {
    region  = var.aws_region
    profile = var.bootstrap_profile
  }
  ```

- [ ] **Step 3: Create `stacks/foundation/ops/variables.tf`**

  ```hcl
  variable "aws_region" {
    description = "Primary AWS region for state bucket and KMS CMK."
    type        = string
  }

  variable "bootstrap_profile" {
    description = "AWS CLI profile with admin access to the Ops account. Used only to bootstrap this stack."
    type        = string
  }

  variable "ops_account_id" {
    description = "12-digit Ops account ID (holds the state bucket and CMK)."
    type        = string
  }

  variable "caller_principal_arn" {
    description = "ARN of the principal (user/role) that needs to assume tf-state-access. Added to the role's trust policy."
    type        = string
  }

  variable "accounts" {
    description = "Alias -> {id, tf_deployer_role_arn} map for every target account. Re-exported as an output for leaf stacks."
    type = map(object({
      id                   = string
      tf_deployer_role_arn = string
    }))
  }

  variable "common_tags" {
    description = "Tags applied to all foundation resources."
    type        = map(string)
    default     = {}
  }
  ```

- [ ] **Step 4: Create `stacks/foundation/ops/main.tf`**

  ```hcl
  #-----------------------------------------------------------------------------
  # KMS CMK for state bucket SSE.
  #-----------------------------------------------------------------------------
  resource "aws_kms_key" "tfstate" {
    description             = "CMK for Terraform state encryption (Ops bucket)"
    enable_key_rotation     = true
    deletion_window_in_days = 30
    tags                    = merge(var.common_tags, { Purpose = "tfstate-sse" })
  }

  resource "aws_kms_alias" "tfstate" {
    name          = "alias/tfstate"
    target_key_id = aws_kms_key.tfstate.key_id
  }

  #-----------------------------------------------------------------------------
  # Single S3 bucket for all Terraform state, Org-wide.
  #-----------------------------------------------------------------------------
  resource "aws_s3_bucket" "tfstate" {
    bucket = "${var.ops_account_id == "" ? "unset" : ""}${var.common_tags["Org"]}-tfstate"
    # Note: the bucket name template above assumes common_tags includes an "Org" key.
    # If you prefer an explicit variable instead, replace with:
    # bucket = var.state_bucket_name  (and add a state_bucket_name variable).
    tags = merge(var.common_tags, { Purpose = "tfstate" })
  }

  resource "aws_s3_bucket_versioning" "tfstate" {
    bucket = aws_s3_bucket.tfstate.id
    versioning_configuration {
      status = "Enabled"
    }
  }

  resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
    bucket = aws_s3_bucket.tfstate.id

    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.tfstate.arn
      }
      bucket_key_enabled = true
    }
  }

  resource "aws_s3_bucket_public_access_block" "tfstate" {
    bucket                  = aws_s3_bucket.tfstate.id
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }

  resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
    bucket = aws_s3_bucket.tfstate.id

    rule {
      id     = "expire-old-versions"
      status = "Enabled"

      noncurrent_version_expiration {
        noncurrent_days = 90
      }

      abort_incomplete_multipart_upload {
        days_after_initiation = 7
      }
    }
  }

  #-----------------------------------------------------------------------------
  # Cross-account tf-state-access role.
  # Assumed by every leaf's backend "s3" { role_arn = ... }.
  # Grants S3 read/write to this bucket + KMS use on the state CMK.
  #-----------------------------------------------------------------------------
  data "aws_iam_policy_document" "tf_state_access_trust" {
    statement {
      effect  = "Allow"
      actions = ["sts:AssumeRole"]

      principals {
        type = "AWS"
        # Caller principal (human user / CI role) that will run terraform.
        identifiers = [var.caller_principal_arn]
      }
    }

    # Also allow every target account's tf-deployer role to assume
    # (so leaves running via tf-deployer can also read state).
    dynamic "statement" {
      for_each = var.accounts
      content {
        effect  = "Allow"
        actions = ["sts:AssumeRole"]

        principals {
          type        = "AWS"
          identifiers = [statement.value.tf_deployer_role_arn]
        }
      }
    }
  }

  resource "aws_iam_role" "tf_state_access" {
    name               = "tf-state-access"
    assume_role_policy = data.aws_iam_policy_document.tf_state_access_trust.json
    tags               = var.common_tags
  }

  data "aws_iam_policy_document" "tf_state_access" {
    statement {
      effect = "Allow"
      actions = [
        "s3:ListBucket",
      ]
      resources = [aws_s3_bucket.tfstate.arn]
    }

    statement {
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
      ]
      resources = ["${aws_s3_bucket.tfstate.arn}/*"]
    }

    statement {
      effect = "Allow"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey",
      ]
      resources = [aws_kms_key.tfstate.arn]
    }
  }

  resource "aws_iam_role_policy" "tf_state_access" {
    name   = "tf-state-access"
    role   = aws_iam_role.tf_state_access.id
    policy = data.aws_iam_policy_document.tf_state_access.json
  }
  ```

  > **Bucket naming note:** the `aws_s3_bucket.tfstate` resource above uses `var.common_tags["Org"]` to build the bucket name. If you prefer an explicit variable, delete that line and add a `state_bucket_name` variable instead. Either is fine; document which in `terraform.tfvars`.

- [ ] **Step 5: Create `stacks/foundation/ops/outputs.tf`**

  ```hcl
  output "state_bucket" {
    description = "S3 bucket holding all Terraform state org-wide."
    value       = aws_s3_bucket.tfstate.id
  }

  output "state_kms_key_arn" {
    description = "KMS CMK ARN used for state SSE."
    value       = aws_kms_key.tfstate.arn
  }

  output "state_kms_key_alias" {
    description = "KMS alias. Use in downstream backend.hcl as kms_key_id."
    value       = aws_kms_alias.tfstate.name
  }

  output "tf_state_access_role_arn" {
    description = "Cross-account role ARN assumed by leaf backends for state I/O."
    value       = aws_iam_role.tf_state_access.arn
  }

  output "accounts" {
    description = "Alias -> {id, tf_deployer_role_arn} map consumed by every leaf via terraform_remote_state."
    value       = var.accounts
  }
  ```

- [ ] **Step 6: Create `stacks/foundation/ops/.gitignore`**

  ```
  terraform.tfvars
  *.tfstate
  *.tfstate.*
  .terraform/
  .terraform.lock.hcl
  ```

- [ ] **Step 7: Commit the scaffold**

  ```bash
  git add stacks/foundation/ops
  git commit -m "feat(m0a): scaffold foundation/ops (Ops bucket + KMS + tf-state-access role)"
  ```

---

## Task 2: Bootstrap `foundation/ops` (local state → apply → migrate to S3)

**Working directory for this task:** `stacks/foundation/ops/`

- [ ] **Step 1: Write `stacks/foundation/ops/terraform.tfvars`**

  ```hcl
  aws_region           = "<PRIMARY_REGION>"
  bootstrap_profile    = "<OPS_BOOTSTRAP_PROFILE>"
  ops_account_id       = "<OPS_ACCOUNT_ID>"
  caller_principal_arn = "<CALLER_PRINCIPAL_ARN>"

  accounts = {
    "account-dev" = {
      id                   = "<ACCOUNT_ID_dev>"
      tf_deployer_role_arn = "<TF_DEPLOYER_ROLE_ARN_dev>"
    }
    "account-stg" = {
      id                   = "<ACCOUNT_ID_stg>"
      tf_deployer_role_arn = "<TF_DEPLOYER_ROLE_ARN_stg>"
    }
    "account-prod" = {
      id                   = "<ACCOUNT_ID_prod>"
      tf_deployer_role_arn = "<TF_DEPLOYER_ROLE_ARN_prod>"
    }
    # Add more accounts here (e.g., "account-prod-apac") as they're commissioned.
  }

  common_tags = {
    Org         = "<ORG>"
    ManagedBy   = "terraform"
    Stack       = "foundation/ops"
  }
  ```

- [ ] **Step 2: Init with local state**

  ```bash
  cd stacks/foundation/ops
  terraform init
  ```

  Expected: `Terraform has been successfully initialized!`.

- [ ] **Step 3: Plan**

  ```bash
  terraform plan
  ```

  Expected: ~11 additions — KMS key + alias, S3 bucket + 4 bucket-config resources, IAM role + role policy, IAM policy document data sources don't count as resources. Zero destroys.

- [ ] **Step 4: Apply**

  ```bash
  terraform apply
  ```

  Type `yes`. Expected final line: `Apply complete!`. Note the `state_bucket` and `tf_state_access_role_arn` outputs — the latter is `<OPS_STATE_ROLE_ARN>` for later tasks.

- [ ] **Step 5: Write `stacks/foundation/ops/backend.hcl`**

  ```hcl
  bucket       = "<ORG>-tfstate"
  key          = "foundation/ops.tfstate"
  region       = "<PRIMARY_REGION>"
  encrypt      = true
  kms_key_id   = "alias/tfstate"
  use_lockfile = true
  profile      = "<OPS_BOOTSTRAP_PROFILE>"
  ```

  > Foundation/ops is special: it uses `profile` (not `role_arn`) because the caller is already operating in the Ops account directly. Leaves in other accounts use `role_arn` to cross into Ops.

- [ ] **Step 6: Add `backend "s3" {}` to `versions.tf`**

  Edit `stacks/foundation/ops/versions.tf` — add the `backend "s3" {}` line inside the existing `terraform { … }` block:

  ```hcl
  terraform {
    required_version = ">= 1.10"

    backend "s3" {}

    required_providers {
      aws = {
        source  = "hashicorp/aws"
        version = ">= 5.0"
      }
    }
  }
  ```

- [ ] **Step 7: Migrate state into the bucket**

  ```bash
  terraform init -backend-config=backend.hcl -migrate-state
  ```

  When prompted `Do you want to copy existing state to the new backend?`, type `yes`. Expected: `Successfully configured the backend "s3"!`.

- [ ] **Step 8: Verify**

  ```bash
  aws --profile <OPS_BOOTSTRAP_PROFILE> s3 ls s3://<ORG>-tfstate/foundation/
  ```

  Expected: `ops.tfstate`.

  ```bash
  terraform plan
  ```

  Expected: `No changes. Your infrastructure matches the configuration.`

- [ ] **Step 9: Delete the local state**

  ```bash
  rm terraform.tfstate terraform.tfstate.backup
  ```

- [ ] **Step 10: Commit**

  ```bash
  cd ../../..
  git add stacks/foundation/ops/versions.tf stacks/foundation/ops/backend.hcl
  git commit -m "feat(m0a): bootstrap foundation/ops; migrate state to S3 backend"
  ```

---

# M0b — Platform (one per target account)

## Task 3: Scaffold `stacks/platform/dev/`

**Files:**
- Create: `stacks/platform/dev/versions.tf`
- Create: `stacks/platform/dev/providers.tf`
- Create: `stacks/platform/dev/variables.tf`
- Create: `stacks/platform/dev/data.tf`
- Create: `stacks/platform/dev/main.tf`
- Create: `stacks/platform/dev/outputs.tf`
- Create: `stacks/platform/dev/.gitignore`

- [ ] **Step 1: Create `stacks/platform/dev/versions.tf`**

  ```hcl
  terraform {
    required_version = ">= 1.10"

    backend "s3" {}

    required_providers {
      aws = {
        source  = "hashicorp/aws"
        version = ">= 5.0"
      }
    }
  }
  ```

- [ ] **Step 2: Create `stacks/platform/dev/variables.tf`**

  ```hcl
  variable "alias" {
    description = "Account alias this stack targets (e.g., account-dev)."
    type        = string
  }

  variable "aws_region" {
    description = "Primary AWS region."
    type        = string
  }

  variable "ops_state_bucket" {
    description = "Name of the Ops-account state bucket (same value for every leaf)."
    type        = string
  }

  variable "ops_state_role_arn" {
    description = "ARN of the Ops tf-state-access role (same value for every leaf)."
    type        = string
  }

  variable "common_tags" {
    type    = map(string)
    default = {}
  }
  ```

- [ ] **Step 3: Create `stacks/platform/dev/data.tf`**

  > Reads `foundation/ops` outputs via `terraform_remote_state`. The backend used for this data source also assumes the Ops state role — so any principal running Terraform must have permission to assume `tf-state-access`.

  ```hcl
  data "terraform_remote_state" "foundation" {
    backend = "s3"
    config = {
      bucket   = var.ops_state_bucket
      key      = "foundation/ops.tfstate"
      region   = var.aws_region
      role_arn = var.ops_state_role_arn
      encrypt  = true
    }
  }

  locals {
    target_account         = data.terraform_remote_state.foundation.outputs.accounts[var.alias]
    tf_deployer_role_arn   = local.target_account.tf_deployer_role_arn
  }
  ```

- [ ] **Step 4: Create `stacks/platform/dev/providers.tf`**

  > Both the primary provider and the `us-east-1` alias assume the target account's `tf-deployer` role. CloudFront-region SNS topics must live in `us-east-1` (consumed by alarms for global CloudFront metrics).

  ```hcl
  provider "aws" {
    region = var.aws_region

    assume_role {
      role_arn = local.tf_deployer_role_arn
    }
  }

  provider "aws" {
    alias  = "us_east_1"
    region = "us-east-1"

    assume_role {
      role_arn = local.tf_deployer_role_arn
    }
  }
  ```

- [ ] **Step 5: Create `stacks/platform/dev/main.tf`**

  Base content (both SNS paths share this):

  ```hcl
  locals {
    severities = ["WARN", "ERROR", "CRIT"]
    # The directory name (dev/stg/prod) — used for topic naming. The var.alias has the "account-" prefix.
    tier = replace(var.alias, "account-", "")
  }

  resource "aws_sns_topic" "regional" {
    for_each = toset(local.severities)
    name     = "${local.tier}-${lower(each.key)}-alerts"
    tags     = merge(var.common_tags, { Severity = each.key, Scope = "regional" })
  }

  resource "aws_sns_topic" "global" {
    provider = aws.us_east_1
    for_each = toset(local.severities)
    name     = "${local.tier}-${lower(each.key)}-alerts-global"
    tags     = merge(var.common_tags, { Severity = each.key, Scope = "global" })
  }
  ```

  **If `<SNS_CHOICE>=import`:** append `import {}` blocks for each existing topic:

  ```hcl
  import {
    to = aws_sns_topic.regional["WARN"]
    id = "<EXISTING_SNS_ARN_dev_WARN>"
  }

  import {
    to = aws_sns_topic.regional["ERROR"]
    id = "<EXISTING_SNS_ARN_dev_ERROR>"
  }

  import {
    to = aws_sns_topic.regional["CRIT"]
    id = "<EXISTING_SNS_ARN_dev_CRIT>"
  }
  ```

  > **Import caveat:** the resource's `name` is `${local.tier}-${lower(each.key)}-alerts` → `dev-warn-alerts` etc. If the existing topic's name doesn't match, Terraform plans a destroy-and-replace. Either (a) rename to match existing, or (b) use `<SNS_CHOICE>=create` and repoint root tfvars afterwards.

- [ ] **Step 6: Create `stacks/platform/dev/outputs.tf`**

  ```hcl
  output "sns_topic_arns" {
    description = "Regional SNS topic ARNs by severity (WARN/ERROR/CRIT)."
    value = {
      WARN  = aws_sns_topic.regional["WARN"].arn
      ERROR = aws_sns_topic.regional["ERROR"].arn
      CRIT  = aws_sns_topic.regional["CRIT"].arn
    }
  }

  output "sns_topic_arns_global" {
    description = "us-east-1 SNS topic ARNs by severity — consumed by CloudFront alarms."
    value = {
      WARN  = aws_sns_topic.global["WARN"].arn
      ERROR = aws_sns_topic.global["ERROR"].arn
      CRIT  = aws_sns_topic.global["CRIT"].arn
    }
  }
  ```

- [ ] **Step 7: Create `stacks/platform/dev/.gitignore`**

  ```
  terraform.tfvars
  *.tfstate
  *.tfstate.*
  .terraform/
  .terraform.lock.hcl
  ```

- [ ] **Step 8: Commit the scaffold**

  ```bash
  git add stacks/platform/dev
  git commit -m "feat(m0b): scaffold platform/dev (SNS topics via cross-account assume-role)"
  ```

---

## Task 4: Apply `platform/dev`

**Working directory for this task:** `stacks/platform/dev/`

- [ ] **Step 1: Write `stacks/platform/dev/terraform.tfvars`**

  ```hcl
  alias              = "account-dev"
  aws_region         = "<PRIMARY_REGION>"
  ops_state_bucket   = "<ORG>-tfstate"
  ops_state_role_arn = "<OPS_STATE_ROLE_ARN>"

  common_tags = {
    Org         = "<ORG>"
    Environment = "dev"
    Account     = "account-dev"
    ManagedBy   = "terraform"
    Stack       = "platform"
  }
  ```

- [ ] **Step 2: Write `stacks/platform/dev/backend.hcl`**

  ```hcl
  bucket       = "<ORG>-tfstate"
  key          = "account-dev/platform/sns.tfstate"
  region       = "<PRIMARY_REGION>"
  encrypt      = true
  kms_key_id   = "alias/tfstate"
  use_lockfile = true
  role_arn     = "<OPS_STATE_ROLE_ARN>"
  ```

  > The `role_arn` here points at the Ops `tf-state-access` role. The caller first assumes that role to read/write state in the Ops bucket. The AWS provider (for resource CRUD) separately assumes the `tf-deployer` role in account-dev via `providers.tf`.

- [ ] **Step 3: Init**

  ```bash
  cd stacks/platform/dev
  terraform init -backend-config=backend.hcl
  ```

  Expected: `Terraform has been successfully initialized!`. The init step also downloads state from `foundation/ops.tfstate` for the `terraform_remote_state` data source.

- [ ] **Step 4: Plan**

  ```bash
  terraform plan
  ```

  If `<SNS_CHOICE>=create`: expected `Plan: 6 to add, 0 to change, 0 to destroy.` (3 regional + 3 global topics).

  If `<SNS_CHOICE>=import`: expected N imports, 0 adds, 0 destroys. **If you see any `add` or `destroy` for `aws_sns_topic.regional`, stop** — the resource `name` doesn't match the existing topic.

- [ ] **Step 5: Apply**

  ```bash
  terraform apply
  ```

  Type `yes`. Expected: `Apply complete!`.

- [ ] **Step 6: Capture the new ARNs**

  ```bash
  terraform output -json sns_topic_arns
  terraform output -json sns_topic_arns_global
  ```

  Save the output — you'll paste it into root `terraform.tfvars` in Task 7 (if the root currently points at dev).

- [ ] **Step 7: If `<SNS_CHOICE>=import`, remove the single-use `import {}` blocks**

  After a clean apply, delete the `import {}` blocks from `main.tf`. Run `terraform plan` — expected `No changes.`. Commit the cleanup.

- [ ] **Step 8: Commit**

  ```bash
  cd ../../..
  git add stacks/platform/dev/backend.hcl
  # If you cleaned up import blocks:
  git add stacks/platform/dev/main.tf
  git commit -m "feat(m0b): apply platform/dev (SNS topics provisioned in account-dev)"
  ```

---

## Task 5: Scaffold and apply `platform/stg` and `platform/prod`

Each additional account needs its own `stacks/platform/<alias>/` leaf. The only differences per leaf:
- `terraform.tfvars`: `alias`, `common_tags.Environment`, `common_tags.Account`.
- `backend.hcl`: `key` (changes the `account-<alias>/` prefix).
- If `<SNS_CHOICE>=import`: the `import {}` block ID values per alias.

Everything else (versions.tf, providers.tf, variables.tf, data.tf, main.tf, outputs.tf, .gitignore) is **identical** across leaves.

- [ ] **Step 1: Clone `platform/dev` → `platform/stg`**

  ```bash
  cp -r stacks/platform/dev stacks/platform/stg
  rm stacks/platform/stg/terraform.tfvars stacks/platform/stg/backend.hcl 2>/dev/null || true
  ```

  (The `rm` is defensive — `terraform.tfvars` and `backend.hcl` are gitignored, but if your cp behavior pulls them over, remove to avoid reusing dev values.)

- [ ] **Step 2: Write `stacks/platform/stg/terraform.tfvars`**

  ```hcl
  alias              = "account-stg"
  aws_region         = "<PRIMARY_REGION>"
  ops_state_bucket   = "<ORG>-tfstate"
  ops_state_role_arn = "<OPS_STATE_ROLE_ARN>"

  common_tags = {
    Org         = "<ORG>"
    Environment = "stg"
    Account     = "account-stg"
    ManagedBy   = "terraform"
    Stack       = "platform"
  }
  ```

- [ ] **Step 3: Write `stacks/platform/stg/backend.hcl`**

  ```hcl
  bucket       = "<ORG>-tfstate"
  key          = "account-stg/platform/sns.tfstate"
  region       = "<PRIMARY_REGION>"
  encrypt      = true
  kms_key_id   = "alias/tfstate"
  use_lockfile = true
  role_arn     = "<OPS_STATE_ROLE_ARN>"
  ```

- [ ] **Step 4: Init + plan + apply `platform/stg`**

  ```bash
  cd stacks/platform/stg
  terraform init -backend-config=backend.hcl
  terraform plan        # inspect — same expectations as Task 4 Step 4
  terraform apply       # yes
  terraform output -json sns_topic_arns
  terraform output -json sns_topic_arns_global
  ```

- [ ] **Step 5: Commit `stg`**

  ```bash
  cd ../../..
  git add stacks/platform/stg/versions.tf stacks/platform/stg/providers.tf \
          stacks/platform/stg/variables.tf stacks/platform/stg/data.tf \
          stacks/platform/stg/main.tf stacks/platform/stg/outputs.tf \
          stacks/platform/stg/.gitignore stacks/platform/stg/backend.hcl
  git commit -m "feat(m0b): scaffold and apply platform/stg"
  ```

- [ ] **Step 6: Repeat for `platform/prod`** (Steps 1–5 with `prod` values).

- [ ] **Step 7: Commit `prod`**

  ```bash
  git add stacks/platform/prod
  git commit -m "feat(m0b): scaffold and apply platform/prod"
  ```

- [ ] **Step 8: (Future) Each new account alias repeats Steps 1–5.**

  Adding `account-prod-apac` later means: `cp -r stacks/platform/prod stacks/platform/prod-apac`, update `terraform.tfvars` and `backend.hcl`, update the `accounts` map in `stacks/foundation/ops/terraform.tfvars` and re-apply foundation, then init/plan/apply the new leaf. No other code changes.

---

## Task 6: Repoint root `terraform.tfvars` to the new SNS ARNs

> **Skip this task if `<SNS_CHOICE>=import`** — the ARNs didn't change.

The existing root has hardcoded SNS ARNs in `terraform.tfvars`. For the `create` path, swap them to the new ARNs from whichever account the root is currently pointed at (usually `account-dev` if the root was running against dev).

**Files:**
- Modify: `terraform.tfvars` (root)

- [ ] **Step 1: Determine which account the root currently targets**

  ```bash
  grep -E '^(aws_profile|aws_region)' terraform.tfvars
  ```

  Match the profile/region to one of your account aliases. Call it `<ROOT_CURRENT_ALIAS>`.

- [ ] **Step 2: Edit root `terraform.tfvars`**

  Replace the `sns_topic_arns` and `sns_topic_arns_global` blocks with the ARNs from `stacks/platform/<ROOT_CURRENT_ALIAS>/` outputs (captured in Task 4/5 Step 6).

  Example assuming root targets `account-dev`:

  ```hcl
  sns_topic_arns = {
    WARN  = "arn:aws:sns:ap-northeast-1:<ACCOUNT_ID_dev>:dev-warn-alerts"
    ERROR = "arn:aws:sns:ap-northeast-1:<ACCOUNT_ID_dev>:dev-error-alerts"
    CRIT  = "arn:aws:sns:ap-northeast-1:<ACCOUNT_ID_dev>:dev-crit-alerts"
  }

  sns_topic_arns_global = {
    WARN  = "arn:aws:sns:us-east-1:<ACCOUNT_ID_dev>:dev-warn-alerts-global"
    ERROR = "arn:aws:sns:us-east-1:<ACCOUNT_ID_dev>:dev-error-alerts-global"
    CRIT  = "arn:aws:sns:us-east-1:<ACCOUNT_ID_dev>:dev-crit-alerts-global"
  }
  ```

- [ ] **Step 3: Run root plan**

  ```bash
  cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
  terraform plan
  ```

  Expected: a **modify-only** plan with every `aws_cloudwatch_metric_alarm` showing its `alarm_actions` / `ok_actions` / `insufficient_data_actions` changed. **Zero destroys, zero creates.**

  Spot-check one diff line:

  ```
  ~ alarm_actions = [
      - "arn:aws:sns:ap-northeast-1:…:warning-alerts",
      + "arn:aws:sns:ap-northeast-1:…:dev-warn-alerts",
    ]
  ```

- [ ] **Step 4: Apply**

  ```bash
  terraform apply
  ```

  Type `yes`. Expected: `Apply complete! Resources: 0 added, N changed, 0 destroyed.`

- [ ] **Step 5: Verify alarm config update**

  ```bash
  aws cloudwatch describe-alarms \
    --query 'MetricAlarms[].{Name:AlarmName,ConfigUpdated:AlarmConfigurationUpdatedTimestamp}' \
    --output table | head -30
  ```

  `ConfigUpdated` timestamps should be post-apply (the rewire landed); alarm names unchanged.

- [ ] **Step 6: Commit**

  > `terraform.tfvars` is likely gitignored. If it is, record the change in an empty commit; otherwise add it.

  ```bash
  git status terraform.tfvars
  # If tracked:
  git add terraform.tfvars
  git commit -m "feat(m0b): repoint root tfvars to platform-managed SNS topics"
  # If gitignored:
  git commit --allow-empty -m "chore(m0b): repointed root tfvars to new SNS ARNs (tfvars gitignored)"
  ```

---

# M1 — Library Refactor (zero-diff)

## Task 7: Move modules from `modules/monitor-<type>/` to `modules/cloudwatch/metrics-alarm/<type>/`

**Files:**
- Move: 11 module directories (see file-structure section above).
- Modify: root `main.tf` (11 `source =` lines).

- [ ] **Step 1: Create the new parent directory**

  ```bash
  mkdir -p modules/cloudwatch/metrics-alarm
  ```

- [ ] **Step 2: `git mv` each module**

  ```bash
  git mv modules/monitor-alb          modules/cloudwatch/metrics-alarm/alb
  git mv modules/monitor-apigateway   modules/cloudwatch/metrics-alarm/apigateway
  git mv modules/monitor-asg          modules/cloudwatch/metrics-alarm/asg
  git mv modules/monitor-cloudfront   modules/cloudwatch/metrics-alarm/cloudfront
  git mv modules/monitor-ec2          modules/cloudwatch/metrics-alarm/ec2
  git mv modules/monitor-elasticache  modules/cloudwatch/metrics-alarm/elasticache
  git mv modules/monitor-lambda       modules/cloudwatch/metrics-alarm/lambda
  git mv modules/monitor-opensearch   modules/cloudwatch/metrics-alarm/opensearch
  git mv modules/monitor-rds          modules/cloudwatch/metrics-alarm/rds
  git mv modules/monitor-s3           modules/cloudwatch/metrics-alarm/s3
  git mv modules/monitor-ses          modules/cloudwatch/metrics-alarm/ses
  ```

- [ ] **Step 3: Verify directory structure**

  ```bash
  ls modules/cloudwatch/metrics-alarm
  ```

  Expected (11 entries): `alb  apigateway  asg  cloudfront  ec2  elasticache  lambda  opensearch  rds  s3  ses`.

  ```bash
  ls modules
  ```

  Expected: only `cloudwatch` (no `monitor-*` left behind).

- [ ] **Step 4: Update `source` paths in root `main.tf`**

  Replace every `source = "./modules/monitor-<type>"` with `source = "./modules/cloudwatch/metrics-alarm/<type>"`. Use `sed`:

  ```bash
  sed -i \
    -e 's|"./modules/monitor-alb"|"./modules/cloudwatch/metrics-alarm/alb"|' \
    -e 's|"./modules/monitor-apigateway"|"./modules/cloudwatch/metrics-alarm/apigateway"|' \
    -e 's|"./modules/monitor-asg"|"./modules/cloudwatch/metrics-alarm/asg"|' \
    -e 's|"./modules/monitor-cloudfront"|"./modules/cloudwatch/metrics-alarm/cloudfront"|' \
    -e 's|"./modules/monitor-ec2"|"./modules/cloudwatch/metrics-alarm/ec2"|' \
    -e 's|"./modules/monitor-elasticache"|"./modules/cloudwatch/metrics-alarm/elasticache"|' \
    -e 's|"./modules/monitor-lambda"|"./modules/cloudwatch/metrics-alarm/lambda"|' \
    -e 's|"./modules/monitor-opensearch"|"./modules/cloudwatch/metrics-alarm/opensearch"|' \
    -e 's|"./modules/monitor-rds"|"./modules/cloudwatch/metrics-alarm/rds"|' \
    -e 's|"./modules/monitor-s3"|"./modules/cloudwatch/metrics-alarm/s3"|' \
    -e 's|"./modules/monitor-ses"|"./modules/cloudwatch/metrics-alarm/ses"|' \
    main.tf
  ```

- [ ] **Step 5: Confirm no lingering `monitor-` references**

  ```bash
  grep -rn 'monitor-' main.tf modules 2>/dev/null || echo "clean"
  ```

  Expected output: `clean`.

- [ ] **Step 6: Reinit to pick up the new module paths**

  ```bash
  terraform init -upgrade
  ```

  Expected: `Terraform has been successfully initialized!`.

---

## Task 8: Verify M1 is a zero-diff refactor

The non-negotiable M1 gate. If the plan shows any diff, **do not commit** — something was miswired.

- [ ] **Step 1: Run the detailed-exit-code plan**

  ```bash
  terraform plan -detailed-exitcode -out=/tmp/m1-plan.bin
  echo "exit=$?"
  ```

  Exit codes: `0` = no changes (✅ proceed). `2` = changes (❌ stop). `1` = error.

- [ ] **Step 2: If exit code is 2, dump the diff**

  ```bash
  terraform show /tmp/m1-plan.bin | head -100
  ```

  Typical causes: a `source` path not updated; a module referencing a sibling with a relative path that broke across the move.

  Fix, re-run Step 1, until exit 0.

- [ ] **Step 3: Commit the library move**

  ```bash
  git add main.tf modules
  git commit -m "refactor(m1): move modules/monitor-<type>/ to modules/cloudwatch/metrics-alarm/<type>/ (zero-diff)"
  ```

- [ ] **Step 4: Clean up the temp plan file**

  ```bash
  rm /tmp/m1-plan.bin
  ```

---

## Task 9: Update documentation references to the new paths

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md` (if it references the old paths)

- [ ] **Step 1: Find all references to `modules/monitor-` in docs**

  ```bash
  grep -rn 'modules/monitor-' --include='*.md'
  ```

  Expected hits in `CLAUDE.md` ("Adding a New Resource Type" section), maybe `README.md`, `STRUCTURE.md`, `IMPLEMENTATION_PLAN.md`, `resource-type-based-metric-alarm.md`.

- [ ] **Step 2: Update `CLAUDE.md`**

  Change `modules/monitor-<type>/` to `modules/cloudwatch/metrics-alarm/<type>/` in both bullets of the "Adding a New Resource Type" section.

- [ ] **Step 3: Update `README.md`** if it mentions the old paths.

- [ ] **Step 4: (Optional) Update scratch docs**

  `STRUCTURE.md`, `IMPLEMENTATION_PLAN.md`, `resource-type-based-metric-alarm.md` are historical artifacts — the spec at `docs/superpowers/specs/2026-04-18-cloudwatch-alarm-refactor-design.md` is canonical. Update or leave them as history, your call.

- [ ] **Step 5: Commit**

  ```bash
  git add CLAUDE.md README.md
  git commit -m "docs(m1): update module-path references for cloudwatch/metrics-alarm layout"
  ```

---

# Verification (end-to-end)

After Task 9, the repo state should be:

- `stacks/foundation/ops/` applies cleanly with S3 backend; `terraform plan` shows no changes.
- `stacks/platform/{dev,stg,prod}/` each apply cleanly; each `terraform output sns_topic_arns` returns a WARN/ERROR/CRIT ARN map; `terraform output sns_topic_arns_global` returns the us-east-1 counterparts.
- Root `terraform plan` exits 0 (`-detailed-exitcode`) with the new module paths and (for `<SNS_CHOICE>=create`) the new SNS ARNs for the current target account.
- `git log --oneline` shows a logical progression (foundation → each platform → root repoint → library move → docs).

## Manual smoke checks

- [ ] **Alarm actions correctly point at platform-managed topics:**

  ```bash
  aws cloudwatch describe-alarms --alarm-names '<pick-one>' \
    --query 'MetricAlarms[0].AlarmActions' --output json
  ```

  Expected: ARN matches the `platform/<ROOT_CURRENT_ALIAS>` output.

- [ ] **No alarm recreated:**

  ```bash
  aws cloudwatch describe-alarms \
    --query 'MetricAlarms[].{Name:AlarmName,ConfigUpdated:AlarmConfigurationUpdatedTimestamp}' \
    --output table | head
  ```

  > Use `AlarmConfigurationUpdatedTimestamp`, not `StateUpdatedTimestamp`. The former tracks config changes; the latter tracks alarm-state transitions (OK ↔ ALARM).

- [ ] **State keys in the Ops bucket:**

  ```bash
  aws --profile <OPS_BOOTSTRAP_PROFILE> s3 ls --recursive s3://<ORG>-tfstate/
  ```

  Expected output:
  ```
  foundation/ops.tfstate
  account-dev/platform/sns.tfstate
  account-stg/platform/sns.tfstate
  account-prod/platform/sns.tfstate
  ```

## Rollback (if needed)

- **Foundation bootstrap fails mid-way** — `terraform destroy` while state is still local; delete the dir; retry. If state already migrated, empty the bucket (caution: versioned!) and destroy remaining resources manually.
- **Platform apply creates wrong topics in the target account** — `terraform destroy` in that platform stack, fix config, re-apply. Root still holds legacy ARNs and is unaffected until Task 6.
- **Task 6 root plan shows unexpected destroys** — do NOT apply. `git checkout terraform.tfvars` (or restore from notes) and investigate.
- **M1 plan shows non-zero diff** — revert the move:

  ```bash
  git reset --hard HEAD~1   # only if the move is the last commit
  terraform init -upgrade
  terraform plan            # verify clean
  ```

---

# Next milestone

With M0+M1 landed, the repo has:
- A single Ops-account state bucket + KMS CMK + cross-account `tf-state-access` role, ready to host every future leaf's state.
- One `platform/<alias>` stack per target account, exposing `sns_topic_arns` and `sns_topic_arns_global` via `terraform_remote_state`.
- A renamed library that leaf stacks will reference as `source = "../../../modules/cloudwatch/metrics-alarm/<type>"`.

**Next plan:** M2 — pilot cutover of the first service (`billing`) using Terraform `removed` + `import` blocks to move alarms from the monolithic root into `stacks/services/billing/<alias>/` without recreating them. That plan will include the `scripts/migrate/generate-split.sh` helper since M3 reuses it across the remaining (service, account) pairs.
