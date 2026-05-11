# Stacks-Without-Foundation Bootstrap — Runbook

> **For agentic workers:** this plan is designed for **manual execution on a work machine without AI assistance**. Read it as a runbook and tick boxes by hand.

**Goal:** Deploy `stacks/platform/<env>/` and `stacks/services/<svc>/<env>/` against real AWS *before* `stacks/foundation/ops/` is in place. Later, when foundation is ready, migrate each stack's state into the central S3 backend without churning AWS resources.

**Why this is needed:** the per-stack `data "terraform_remote_state"` blocks and `assume_role` providers expect foundation outputs (state bucket, KMS alias, `tf_deployer_role_arn`, SNS ARNs). If you don't have those yet, you can't `terraform init` the stacks as written. This runbook substitutes local backend + a profile-based provider + hardcoded values for the foundation outputs, and tells you how to undo the substitutions later.

**Tech Stack:** terraform ≥1.7, an AWS CLI profile with admin access to the target staging account, an SNS topic in that account.

**Placeholders:**

| Placeholder | Meaning |
|---|---|
| `<STACK>` | Path to a stack directory, e.g. `stacks/platform/dev` or `stacks/services/billing/dev` |
| `<AWS_PROFILE>` | AWS CLI profile that has admin access to the staging account |
| `<SNS_WARN_ARN>` / `<SNS_ERROR_ARN>` / `<SNS_CRIT_ARN>` | Real SNS topic ARNs in the staging account (one per severity) |

---

## Stage 1: Per-stack bootstrap override

For each stack you want to bring up.

### Task 1.1: Add `bootstrap_override.tf`

**Files:** `<STACK>/bootstrap_override.tf` (new — gitignored)

- [ ] **Step 1: Add the file to the per-stack `.gitignore`** so it never lands on origin.

```bash
echo "bootstrap_override.tf" >> "<STACK>/.gitignore"
```

This appends to (or creates) `<STACK>/.gitignore`, not the repo-root one.

- [ ] **Step 2: Create `<STACK>/bootstrap_override.tf`**

This replaces the stack's `terraform { backend "s3" {} }` (an override's `backend "local" {}` block fully supplants the s3 backend since it has no nested attributes to merge).

```hcl
terraform {
  backend "local" {}
}
```

> ⚠ **Override-file caveat:** Terraform's `*_override.tf` merges nested blocks from the original rather than replacing whole resources. The original `providers.tf` has `provider "aws" { ... assume_role { role_arn = local.tf_deployer_role_arn } }`. An override `provider "aws"` block that adds `profile` would NOT remove the inner `assume_role` block — terraform would still attempt to assume the role. For that reason the provider change is a direct edit, not an override (see Task 1.2 step 1c below).

### Task 1.2: Direct edits to `providers.tf` and `data.tf`

These edits are temporary — you'll revert them in Stage 3 via `git checkout`.

- [ ] **Step 1a (platform stack only):** comment out the `data "terraform_remote_state" "foundation"` block and the `locals { tf_deployer_role_arn = ... }` that consumes it.

- [ ] **Step 1b (service stack only):** comment out the `data "terraform_remote_state" "platform"` block. Replace the `locals { sns_topic_arns = ... }` with hardcoded values:

```hcl
locals {
  project = var.service
  sns_topic_arns = {
    WARN  = "<SNS_WARN_ARN>"
    ERROR = "<SNS_ERROR_ARN>"
    CRIT  = "<SNS_CRIT_ARN>"
  }
  sns_topic_arns_global = local.sns_topic_arns
}
```

- [ ] **Step 1c (both):** edit `providers.tf` and remove the entire `assume_role { ... }` block from each `provider "aws"` declaration (both the default and the `us_east_1` alias). Replace it with a `profile = "<AWS_PROFILE>"` attribute. Example:

```hcl
provider "aws" {
  region  = var.aws_region
  profile = "<AWS_PROFILE>"
  # assume_role { role_arn = local.tf_deployer_role_arn }   # REMOVED for bootstrap
}

provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = "<AWS_PROFILE>"
  # assume_role { role_arn = local.tf_deployer_role_arn }   # REMOVED for bootstrap
}
```

### Task 1.3: Apply

- [ ] **Step 1: Init + apply**

```bash
cd "<STACK>"
terraform init                    # uses local backend, no -backend-config needed
terraform plan
terraform apply
```

Expected: state file at `<STACK>/terraform.tfstate`. `terraform.tfstate*` is already gitignored at the stack level.

- [ ] **Step 2: Sanity-check the resources are in AWS**

```bash
aws --profile <AWS_PROFILE> cloudwatch describe-alarms --output json | jq '.MetricAlarms | length'
```

---

## Stage 2: Deploy foundation (when ready)

This is the standard foundation deployment — itself bootstrap-able with the same local-backend trick if the Ops account isn't fully wired yet.

- [ ] Deploy `stacks/foundation/ops/` (creates the central state bucket, KMS key, IAM roles). If it itself needs a temporary local backend (chicken-and-egg on its own state bucket), follow Stage 1 for it, then `terraform init -migrate-state -backend-config=backend.hcl` to move its state into the bucket it just created.

- [ ] Verify `foundation/ops` outputs contain the values the platform stack needs (`accounts` map with `tf_deployer_role_arn` per alias).

- [ ] Deploy `stacks/platform/<env>/` *properly* (no override) — this is a fresh apply that creates the per-tier SNS topics in the central state bucket. Its state lives in the Ops bucket from this point on.

> Note: if a platform-stack apply with the override already created SNS topics that foundation's setup expects to exist (it shouldn't — platform owns SNS), you'll need to import or replace them.

---

## Stage 3: Migrate each previously-bootstrap-deployed service stack

For each `<STACK>` that was bootstrapped in Stage 1.

### Task 3.1: Restore the original files

- [ ] **Step 1:** delete `bootstrap_override.tf`.
- [ ] **Step 2:** revert `data.tf` and `providers.tf` to the committed versions:

```bash
cd "<STACK>"
git checkout -- data.tf providers.tf
rm bootstrap_override.tf
```

### Task 3.2: Migrate state from local to S3

- [ ] **Step 1: Re-init with the production backend, migrating state**

```bash
cd "<STACK>"
terraform init -backend-config=backend.hcl -migrate-state
```

Terraform reads `<STACK>/terraform.tfstate` (local) and prompts:

> Do you want to copy existing state to the new backend?

Type `yes`. State now lives in S3.

- [ ] **Step 2: Plan must show no changes**

```bash
terraform plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

If you see destroys or creates:
- **Provider mismatch.** Bootstrap used profile auth; foundation expects role assumption. If the role assumes into the *same* account, plan should be clean. If different accounts: stop, you can't migrate — destroy and redeploy.
- **Resource address changed.** Stubbed `data` blocks may have returned different values than the real remote_state. Compare hardcoded SNS ARNs against platform's outputs and align.

- [ ] **Step 3: Archive the local state file**

```bash
mv terraform.tfstate terraform.tfstate.local-backup
```

Keep the backup until you've verified the cloud state is intact (you can `terraform state pull > /tmp/cloud-state.json` and compare).

---

## Rollback

If migration plan shows unacceptable churn:

```bash
cd "<STACK>"
# Restore bootstrap state if you already deleted it
git checkout HEAD -- data.tf providers.tf
# Recreate bootstrap_override.tf per Task 1.1 step 2
terraform init -reconfigure            # re-points at local backend, no migration
```

Or simpler: destroy and redeploy via foundation-aware path from a clean state, since this is staging.

---

## Notes

- Bootstrap-mode provider auth (`profile`) and foundation-mode auth (`assume_role`) must reach the **same AWS account**, or the migrated state will refer to resources the provider can no longer manage.
- The override file approach keeps the source files clean of "temporary" patches — easier to merge updates from origin in the future via the work-repo ongoing sync pattern.
- Don't commit `bootstrap_override.tf` or the data-stub edits. They are local-only.
