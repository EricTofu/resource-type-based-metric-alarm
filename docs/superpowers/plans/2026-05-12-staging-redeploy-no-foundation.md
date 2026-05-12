# Staging Redeploy (No Foundation) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: this plan is designed for **manual execution on the work machine without AI assistance**. The "subagent-driven" / "inline executing-plans" workflows do not apply — read it as a runbook and tick boxes by hand. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redeploy the CloudWatch-alarm staging environment from a fresh `work` repo into the refactored per-service-stack layout, without first deploying the `foundation/ops` stack. Use local terraform state during this phase; foundation + state migration happens later. Finish by tidying the local `synced` clone and (optionally) the public `origin` repo.

**Architecture:** Three repos exist on the work machine:
- **work** — freshly re-init'd local deployment repo; carries `modules/cloudwatch/metrics-alarm/`, `stacks/`, `scripts/`, gitignored `terraform.tfvars` and `terraform.tfstate*`. No AI-authored docs; standalone git history.
- **synced** — clean clone of `origin/refactor/m1-m6`. Read-only reference for runbooks and scripts. Never modified by this plan.
- **origin** — public GitHub repo (`refactor/m1-m6` tip is `ea329a4`). Modified only in Stage 3 (cleanup), and only from a separate machine that has push access.

Deployment uses Terraform's `*_override.tf` mechanism plus direct edits to `providers.tf` / `data.tf` to substitute local backend + profile-based auth for the foundation-mode S3 backend + assume_role. When foundation lands later, `git checkout -- providers.tf data.tf && rm bootstrap_override.tf && terraform init -migrate-state` reverses it.

**Tech Stack:** terraform ≥1.7, AWS CLI with admin profile for the staging account, an already-existing or about-to-be-created set of three SNS topics (WARN/ERROR/CRIT).

**Placeholders used throughout** — substitute at execution time:

| Placeholder | Meaning | Example |
|---|---|---|
| `<work>` | Path to the freshly-reinit'd work repo | `~/code/cw-alarms-work` |
| `<synced>` | Path to the synced clone of origin/refactor/m1-m6 | `~/code/refactor-synced` |
| `<snapshot>` | Path to the saved monolithic tfvars | `/tmp/work-tfvars-snapshot-20260512.tfvars` |
| `<runbook>` | Path to the bootstrap runbook (in synced) | `<synced>/docs/superpowers/plans/2026-05-11-stacks-without-foundation-bootstrap.md` |
| `<profile>` | AWS CLI profile with admin on the staging account | `staging-admin` |
| `<region>` | Primary AWS region | `ap-northeast-1` |
| `<org>` | Org slug used in state bucket naming and tags | `acme` |
| `<service>` | A service name extracted from the snapshot in Stage 1 | `billing` |

---

## Stage 0: Pre-flight

Verify everything you need is in place before touching anything.

### Task 0.1: Verify the three repos exist and are in the right shape

**Files:** none (verification only)

- [ ] **Step 1: Confirm `<work>` is freshly re-init'd**

```bash
cd <work>
git log --oneline
ls modules/cloudwatch/metrics-alarm/ stacks/ scripts/migrate/scaffold-leaf.sh
```

Expected: `git log` shows your initial commit (one or a few — the "import refactor layout" commit plus any M4 decommission commits). `ls` shows the library modules, stacks scaffolding, and the scaffold script. **No** `docs/superpowers/`, **no** `CLAUDE.md` (you scrubbed them). If those AI-authored files are still present and you want them gone, stop and scrub now.

- [ ] **Step 2: Confirm `<synced>` is on `refactor/m1-m6` at `ea329a4`**

```bash
cd <synced>
git log --oneline -3
```

Expected: tip is `ea329a4 fix(m6,docs): propagate RDS enabled flag through cluster expansion; correct bootstrap doc override semantics`; HEAD~1 is `7e4a486 feat: port work-machine module tunings onto M6-hardened library`.

- [ ] **Step 3: Confirm the tfvars snapshot exists**

```bash
ls -l <snapshot>
head -5 <snapshot>
```

Expected: file exists, contents look like terraform tfvars (resource lists wrapped in `{ project = "...", resources = [...] }` blocks).

- [ ] **Step 4: Confirm AWS CLI works against the staging account**

```bash
aws sts get-caller-identity --profile <profile>
aws cloudwatch describe-alarms --profile <profile> --query 'length(MetricAlarms)' --output text
```

Expected: returns the staging account ID under the profile you'll use; alarm count is 0 (you already destroyed in the prior nuke step) or whatever pre-existing baseline you accept.

### Task 0.2: Set the env vars used by `scaffold-leaf.sh`

**Files:** shell environment only

- [ ] **Step 1: Export the five required vars in your shell session**

```bash
export ORG="<org>"
export PRIMARY_REGION="<region>"
export OPS_STATE_ROLE_ARN="arn:aws:iam::000000000000:role/tf-state-access"   # placeholder OK in bootstrap mode
export PILOT_SERVICE="billing"
export PILOT_ALIAS="dev"
```

Expected: `echo "$ORG $PRIMARY_REGION $OPS_STATE_ROLE_ARN $PILOT_SERVICE $PILOT_ALIAS"` prints all five.

The `OPS_STATE_ROLE_ARN` is written into each new stack's `backend.hcl` and `terraform.tfvars`, but in bootstrap mode the override replaces the backend and the value is unused at apply time. Putting a placeholder is fine; if you already know the future Ops account ID, use the real value so flipping to foundation later is one edit fewer.

---

## Stage 1: Extract services + scaffold per-service stacks

### Task 1.1: Enumerate services from the snapshot

**Files:** none (read-only)

- [ ] **Step 1: List unique `project` values across the snapshot**

```bash
grep -oE 'project[[:space:]]*=[[:space:]]*"[^"]+"' <snapshot> \
  | awk -F'"' '{print $2}' | sort -u
```

Expected: a newline-separated list of service names (whatever `project = "..."` values appeared in the old monolithic tfvars). Save this list — you'll iterate over it in Task 1.2.

- [ ] **Step 2: Decide whether `billing` is in the list and how to handle it**

If `billing` appears, the existing `stacks/services/billing/dev/` from origin's M2 pilot will collide with `scaffold-leaf.sh` (which refuses to overwrite). Two choices:

- **Keep origin's billing/dev scaffold** and fill its tfvars in Task 1.3 (skip billing in Task 1.2's loop).
- **Re-scaffold from your template** to ensure every service has identical shape: `rm -rf stacks/services/billing/dev/` and include billing in the Task 1.2 loop.

Choose one. The first is simpler and the difference is cosmetic.

### Task 1.2: Run `scaffold-leaf.sh` for each service

**Files:** new `stacks/services/<service>/dev/` directories

- [ ] **Step 1: Loop over the service list**

Replace the placeholder list with your actual services from Task 1.1. Skip `billing` if you chose "keep origin's scaffold":

```bash
cd <work>
for svc in <svc-1> <svc-2> <svc-3>; do
  echo "=== scaffolding $svc/dev ==="
  bash scripts/migrate/scaffold-leaf.sh "$svc" dev
done
```

Expected: one line per service, "Scaffolded stacks/services/<svc>/dev". No errors.

- [ ] **Step 2: Verify each scaffold has the right files**

```bash
for dir in stacks/services/*/dev; do
  echo "=== $dir ==="
  ls "$dir"
done
```

Expected: each `stacks/services/<svc>/dev/` contains `backend.hcl`, `data.tf`, `.gitignore`, `main.tf`, `outputs.tf`, `providers.tf`, `terraform.tfvars`, `variables.tf`, `versions.tf`.

- [ ] **Step 3: Commit the scaffolds (working state, even before tfvars are filled)**

```bash
cd <work>
git add stacks/services/
git commit -m "scaffold per-service stacks (staging/dev)"
```

### Task 1.3: Fill each service's `terraform.tfvars`

**Files:** `stacks/services/<service>/dev/terraform.tfvars` (one per service)

Repeat the steps below **once per service**.

- [ ] **Step 1: Locate the service's entries in the snapshot**

```bash
grep -n 'project[[:space:]]*=[[:space:]]*"<service>"' <snapshot>
```

Expected: line numbers where `project = "<service>"` appears. Each appearance is inside a resource-type list (`alb_resources = [...]`, `lambda_resources = [...]`, etc.). Open the snapshot in an editor and identify the surrounding `resources = [...]` array for each occurrence.

- [ ] **Step 2: Open the new tfvars file and the snapshot side-by-side**

```bash
$EDITOR <work>/stacks/services/<service>/dev/terraform.tfvars <snapshot>
```

- [ ] **Step 3: For each `<type>_resources` in the new file, paste the matching resources from the snapshot**

The schema differs slightly between layouts:

| Old (monolithic) | New (per-service stack) |
|---|---|
| `{ project = "<service>", resources = [{ name = "x", overrides = {...} }, ...] }` | `[{ name = "x", overrides = {...} }, ...]` |

So strip the outer `{ project = "...", resources = ... }` wrapper and paste only the inner resource list.

**Watch for these conversions:**
- `is_serverless = true` (old/work) → `serverless = true` (new). The library module is named `serverless`; the per-service-stack `rds_resources` schema uses `serverless` too.
- `lambda_concurrency_threshold` lives at the top of the tfvars (not inside `lambda_resources`); copy if present in the snapshot.
- `cloudfront_resources` keys on `distribution_id`, not `name`. If the snapshot had a `name` field, drop it (or keep it — the override schema allows arbitrary extras to be ignored).

- [ ] **Step 4: If you need per-resource `read_latency_threshold` or `write_latency_threshold` for RDS**

The library module (`modules/cloudwatch/metrics-alarm/rds/variables.tf`) accepts these as override fields, but `stacks/services/<service>/dev/variables.tf` does not yet declare them. To enable per-resource control, edit the stack's `rds_resources` override schema:

```hcl
# In stacks/services/<service>/dev/variables.tf, inside variable "rds_resources" overrides:
      read_latency_threshold                 = optional(number)
      write_latency_threshold                = optional(number)
```

Otherwise the library defaults (`0.1` seconds read, `0.2` seconds write) apply uniformly. For most staging cases the defaults are fine; skip this step unless the snapshot showed explicit latency overrides on RDS resources.

- [ ] **Step 5: Set `common_tags` and other stack-level vars**

The scaffold pre-fills:
```hcl
common_tags = {
  ManagedBy   = "terraform"
  Service     = "<service>"
  Environment = "dev"
}
```
Add any work-org-specific tag keys (e.g., `Owner`, `CostCenter`) as needed.

- [ ] **Step 6: Validate-by-eye that all resource lists are accounted for**

For each `<type>_resources = []` in the new file, ask: did the snapshot have entries for this type under `project = "<service>"`? If yes and the new file shows `[]`, you forgot to copy. If no, leaving `[]` is correct.

- [ ] **Step 7: After filling all services, commit**

```bash
cd <work>
git add stacks/services/*/dev/terraform.tfvars
# Plus any variables.tf edits if you did Step 4 for any service:
git add stacks/services/*/dev/variables.tf 2>/dev/null
git commit -m "fill per-service tfvars from staging snapshot"
```

---

## Stage 2: Bootstrap deploy (no foundation)

Apply `platform/dev` first (it creates the SNS topics service stacks consume), then loop service stacks.

Reference: `<runbook>` documents the override-file pattern in detail. This stage compresses it into per-task steps.

### Task 2.1: Bootstrap and apply `stacks/platform/dev/`

**Files:**
- Create: `<work>/stacks/platform/dev/bootstrap_override.tf` (gitignored)
- Modify: `<work>/stacks/platform/dev/providers.tf`
- Modify: `<work>/stacks/platform/dev/data.tf`
- Modify: `<work>/stacks/platform/dev/terraform.tfvars`

- [ ] **Step 1: Add the override filename to the stack's `.gitignore`**

```bash
cd <work>/stacks/platform/dev
echo "bootstrap_override.tf" >> .gitignore
```

- [ ] **Step 2: Create `bootstrap_override.tf` with only the backend override**

```bash
cat > bootstrap_override.tf <<'EOF'
terraform {
  backend "local" {}
}
EOF
```

Why this is just the backend: an override `provider "aws" {}` block would *merge* with the original (keeping its `assume_role { ... }` nested block), not replace it. So the provider change is a direct edit in Step 3, not an override.

- [ ] **Step 3: Edit `providers.tf` — drop `assume_role`, add `profile`**

Open `providers.tf` and edit both `provider "aws"` blocks (default and `us_east_1` alias). Remove the `assume_role { ... }` block and add a `profile` line:

```hcl
provider "aws" {
  region  = var.aws_region
  profile = "<profile>"
}

provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = "<profile>"
}
```

- [ ] **Step 4: Edit `data.tf` — comment out the foundation remote_state and its consumers**

The original `data.tf` reads `foundation/ops.tfstate` to get the `accounts` map and derives `local.tf_deployer_role_arn` from it. With `assume_role` gone from providers, that local is unused. Comment out:
- The entire `data "terraform_remote_state" "foundation" { ... }` block.
- The `locals { target_account = ... ; tf_deployer_role_arn = ... }` block (or whichever local depends on the foundation remote state).

Use `#` line prefixes; leave the file parseable.

- [ ] **Step 5: Fill `terraform.tfvars`**

Open the stack's tfvars and set the values the stack's `variables.tf` requires. Example shape (your variable names may differ; check `variables.tf` first):

```hcl
alias       = "dev"
aws_region  = "<region>"
sns_choice  = "create"     # creates the three SNS topics; vs "import"
common_tags = {
  Org       = "<org>"
  ManagedBy = "terraform"
  Stack     = "platform/dev"
}
```

`sns_choice = "create"` makes `stacks/platform/dev/main.tf` create the WARN/ERROR/CRIT topics. If your account already has staging SNS topics you want to reuse, set `sns_choice = "import"` and provide ARNs via the schema in `variables.tf`.

- [ ] **Step 6: Init + plan**

```bash
cd <work>/stacks/platform/dev
terraform init
terraform plan -out=tfplan
```

Expected: plan shows `+ create` for three `aws_sns_topic` resources (regional) and three more (us-east-1 global) if `sns_choice = "create"`. No destroys.

- [ ] **Step 7: Apply**

```bash
terraform apply tfplan
```

Expected: apply succeeds; state lands in `<work>/stacks/platform/dev/terraform.tfstate` (already gitignored). Six SNS topics now exist in AWS.

- [ ] **Step 8: Capture the SNS topic ARNs — you'll paste them into service stacks**

```bash
aws sns list-topics --profile <profile> --region <region> --output text \
  --query 'Topics[?contains(TopicArn, `alerts`)].TopicArn'
aws sns list-topics --profile <profile> --region us-east-1 --output text \
  --query 'Topics[?contains(TopicArn, `alerts`)].TopicArn'
```

Expected output (example with `<org>` slug used in topic naming):
```
arn:aws:sns:<region>:<account>:dev-warn-alerts
arn:aws:sns:<region>:<account>:dev-error-alerts
arn:aws:sns:<region>:<account>:dev-crit-alerts
arn:aws:sns:us-east-1:<account>:dev-warn-alerts-global
arn:aws:sns:us-east-1:<account>:dev-error-alerts-global
arn:aws:sns:us-east-1:<account>:dev-crit-alerts-global
```

Save these six ARNs in a scratch file — you'll paste them into each service stack's `data.tf` in Task 2.2.

### Task 2.2: Bootstrap and apply ONE pilot service stack

Pick the simplest service in your list (fewest resources) as the pilot. Validate the pattern end-to-end before looping. The instructions below use `<pilot>` as the placeholder for that service name.

**Files:**
- Create: `<work>/stacks/services/<pilot>/dev/bootstrap_override.tf` (gitignored)
- Modify: `<work>/stacks/services/<pilot>/dev/providers.tf`
- Modify: `<work>/stacks/services/<pilot>/dev/data.tf`

- [ ] **Step 1: Override file (same as platform)**

```bash
cd <work>/stacks/services/<pilot>/dev
echo "bootstrap_override.tf" >> .gitignore
cat > bootstrap_override.tf <<'EOF'
terraform {
  backend "local" {}
}
EOF
```

- [ ] **Step 2: Edit `providers.tf` — drop `assume_role`, add `profile`**

Service-stack providers.tf uses `data.terraform_remote_state.platform.outputs.accounts[var.alias].tf_deployer_role_arn` inside `assume_role`. Replace the entire `assume_role { ... }` block with `profile = "<profile>"`:

```hcl
provider "aws" {
  region  = var.aws_region
  profile = "<profile>"
}

provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = "<profile>"
}
```

- [ ] **Step 3: Edit `data.tf` — comment out platform remote_state, hardcode SNS ARNs**

Comment out the `data "terraform_remote_state" "platform" { ... }` block, then replace the `locals` block that consumed its outputs:

```hcl
locals {
  project = var.service
  sns_topic_arns = {
    WARN  = "<paste warn ARN from Task 2.1 Step 8>"
    ERROR = "<paste error ARN>"
    CRIT  = "<paste crit ARN>"
  }
  sns_topic_arns_global = {
    WARN  = "<paste us-east-1 warn ARN>"
    ERROR = "<paste us-east-1 error ARN>"
    CRIT  = "<paste us-east-1 crit ARN>"
  }
}
```

If your platform setup uses the same ARN for global and regional (it shouldn't for CloudFront, which requires us-east-1), `sns_topic_arns_global = local.sns_topic_arns` works as a fallback.

- [ ] **Step 4: Init + plan**

```bash
cd <work>/stacks/services/<pilot>/dev
terraform init
terraform plan -out=tfplan
```

Expected: plan shows `+ create` for `aws_cloudwatch_metric_alarm` resources matching the resources you put in the tfvars. Specifically, count them:
- ALB resources × 3 alarms each (elb_5xx, target_5xx, unhealthy_host) — *no* target_response_time, that's commented out in the library
- APIGW resources × 1 alarm (error_5xx)
- ASG resources × 1 alarm (in_service_capacity)
- CloudFront × 2 alarms each (error_5xx, origin_latency) — *no* error_4xx or cache_hit_rate
- EC2 × 4 alarms each (status_check, status_check_ebs, cpu, memory)
- ElastiCache × 2 alarms each (cpu, memory)
- Lambda × 1 alarm per function (duration) + 1 account-level (concurrency)
- OpenSearch × 4 alarms each (cpu, jvm_memory, old_gen_jvm_memory, free_storage)
- RDS × 7 alarms per non-serverless instance (freeable_memory, cpu, database_connections, free_storage, engine_uptime, read_latency, write_latency); + 2 more (acu_utilization, serverless_capacity) for serverless; *no* volume_bytes_used
- S3 × 1 alarm per bucket (error_5xx), + 1 more if `replication_enabled` is set
- SES × 1 alarm per identity (bounce_rate)

If plan shows zero alarms, the tfvars resource lists are still empty — revisit Task 1.3.

- [ ] **Step 5: Apply**

```bash
terraform apply tfplan
```

Expected: apply succeeds.

- [ ] **Step 6: Verify in AWS**

```bash
aws cloudwatch describe-alarms --profile <profile> --region <region> \
  --query "MetricAlarms[?contains(AlarmName, '<pilot>')] | length(@)" --output text
```

Expected: matches the plan count from Step 4.

```bash
aws cloudwatch describe-alarms --profile <profile> --region <region> \
  --query "MetricAlarms[?contains(AlarmName, '<pilot>') && length(OKActions)==\`0\`] | [].AlarmName" \
  --output text
```

Expected: empty. Every alarm should have non-empty `OKActions` — that's the port-from-work-tunings working.

- [ ] **Step 7: Spot-check one alarm**

Pick any one alarm name from the list and describe it:

```bash
aws cloudwatch describe-alarms --profile <profile> --region <region> \
  --alarm-names "<one-alarm-name>" --output json \
  | jq '{name:.MetricAlarms[0].AlarmName, desc:.MetricAlarms[0].AlarmDescription, ok:.MetricAlarms[0].OKActions, alarm:.MetricAlarms[0].AlarmActions}'
```

Expected:
- `desc` starts with `[WARN]-`, `[ERROR]-`, or `[CRIT]-` (severity prefix).
- `ok` and `alarm` both contain exactly one ARN, both pointing at the same severity-matched SNS topic from Task 2.1.

If anything looks wrong here, fix before proceeding to other services.

### Task 2.3: Loop the remaining services

**Files:** repeat Task 2.2 across each remaining service.

- [ ] **Step 1: For each remaining service, repeat Task 2.2 Steps 1–7**

Copy your `bootstrap_override.tf` from the pilot to each remaining service's directory — it's identical:

```bash
for svc in <remaining-svc-1> <remaining-svc-2> ...; do
  cd <work>/stacks/services/$svc/dev
  echo "bootstrap_override.tf" >> .gitignore
  cp ../../<pilot>/dev/bootstrap_override.tf .
  echo "=== copied override to $svc/dev ==="
done
```

Then for each service, hand-edit `providers.tf` and `data.tf` per Task 2.2 Steps 2–3 (the SNS ARNs are identical across services), then `terraform init && plan && apply`.

- [ ] **Step 2: Final cross-check — total alarm count**

```bash
aws cloudwatch describe-alarms --profile <profile> --region <region> \
  --query 'length(MetricAlarms)' --output text
aws cloudwatch describe-alarms --profile <profile> --region us-east-1 \
  --query 'length(MetricAlarms)' --output text
```

Expected: sum approximately matches the union of plan counts from each service's Task 2.2 Step 4. Differences worth investigating:
- More than expected: a stack got applied twice, or another project is creating alarms in this account.
- Fewer than expected: a service stack didn't apply cleanly. Re-check `terraform state list` in each.

- [ ] **Step 3: Commit the non-gitignored edits**

Only `providers.tf`, `data.tf`, and any `variables.tf` edits land in git. `bootstrap_override.tf` and tfstate stay gitignored.

```bash
cd <work>
git add stacks/platform/dev/providers.tf stacks/platform/dev/data.tf
git add stacks/services/*/dev/providers.tf stacks/services/*/dev/data.tf
git commit -m "staging deploy: bootstrap-mode provider auth + remote_state stubs"
git tag staging-deployed-$(date +%Y%m%d)
```

---

## Stage 3: Post-deploy cleanup

Three independent cleanup paths. Pick whichever matches your needs; they don't conflict.

### Task 3.1 (Path α): Drop or simplify the local `synced` clone

After deploys are stable and the runbooks are no longer being actively consulted, `synced` is dead weight on the work machine.

- [ ] **Step 1: Archive any docs you might want offline**

```bash
mkdir -p ~/runbooks-archive
cp -r <synced>/docs/superpowers/plans/ ~/runbooks-archive/
cp -r <synced>/docs/superpowers/specs/  ~/runbooks-archive/
```

- [ ] **Step 2: Delete the clone**

```bash
rm -rf <synced>
```

You can `git clone` it again from origin any time you need to pull a future update.

### Task 3.2 (Path β): Scrub AI-authored content from `origin` (cosmetic; only do this from a machine with push access)

If the public origin shouldn't carry the planning docs or `CLAUDE.md` going forward (e.g., the repo is shared with colleagues who'll review `git log`), drop those files in a forward-going commit:

- [ ] **Step 1: From a clone with push access (NOT the work machine), remove the files**

```bash
cd <origin-clone>
git checkout refactor/m1-m6
git pull --ff-only
git rm -r docs/superpowers/ CLAUDE.md IMPLEMENTATION_PLAN.md STRUCTURE.md
git rm -f resource-type-based-metric-alarm.md   # if still present
git commit -m "remove planning docs and AI-instruction files"
git push origin refactor/m1-m6
```

Don't `git filter-repo` to rewrite history unless compliance specifically requires it — rewriting forces every clone (including any colleague's fork) to reset. The forward-going removal above is enough for "nothing AI-authored in tree going forward."

### Task 3.3 (Path γ): Promote `refactor/m1-m6` to `main`

If `refactor/m1-m6` is now the canonical shape and the old monolithic `main` is obsolete:

- [ ] **Step 1: From the clone with push access**

```bash
cd <origin-clone>
git checkout refactor/m1-m6
git pull --ff-only
git branch -m main old-monolithic-main    # only if you have main checked out locally
git push origin :main                      # delete remote main — DESTRUCTIVE, confirm no consumers
git push -u origin refactor/m1-m6:main     # push refactor as the new main
git push origin :refactor/m1-m6            # delete the now-redundant branch (optional)
```

Expected: GitHub shows `main` at SHA `ea329a4` (plus any cleanup commits from Task 3.2); the branch list no longer includes `refactor/m1-m6`.

**Caution:** `git push origin :main` deletes the remote main. If anyone else has a working clone tracking `origin/main`, they'll need to re-checkout. Verify before pushing.

---

## Rollback

This plan is for staging; no real rollback is needed for the deploy itself (you can `terraform destroy` per stack and start over). But within the cleanup stages:

- **Path α rollback:** re-clone `<synced>` from origin (`git clone <origin-url> <synced> && cd <synced> && git checkout refactor/m1-m6`).
- **Path β rollback:** the removed files are in origin's history at `ea329a4`. `git checkout ea329a4 -- docs/superpowers/ CLAUDE.md ... && git commit -m "restore planning docs"`.
- **Path γ rollback:** if you deleted `refactor/m1-m6` from origin, re-push it from any clone that still has it: `cd <some-clone-with-it> && git push origin refactor/m1-m6`. If main got overwritten and you need the old monolithic main back, `git push origin old-monolithic-main:main` from a clone that has the archived branch.

For the **deploy** itself: `terraform destroy` from any stack rolls back that stack. Bootstrap-mode state is local to `<stack>/terraform.tfstate`, so a destroy + apply cycle is cheap.

---

## Migration to foundation mode (later, when ready)

When you eventually deploy `stacks/foundation/ops/` and want the staging stacks under its S3 backend, follow Stage 2 of `<runbook>` per stack:

1. `rm bootstrap_override.tf`
2. `git checkout HEAD -- providers.tf data.tf` (reverts to the foundation-aware versions)
3. `terraform init -backend-config=backend.hcl -migrate-state` — answer `yes` to copy local state to S3
4. `terraform plan` — must show no changes; if it does, provider auth or remote_state values diverged

Not in scope for this plan.
