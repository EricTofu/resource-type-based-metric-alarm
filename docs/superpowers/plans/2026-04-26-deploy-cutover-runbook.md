# Deploy Cutover Runbook — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the M0–M4 refactor against a real AWS environment from a separate "deploy" machine, in order, with verification gates and a clear rollback path between stages.

**Architecture:** This runbook layers *deploy sequencing* on top of the existing milestone plans (`M0/M1`, `M2`, `M3`, `M4`, `M6`). The milestone plans cover *what code/state changes to make*; this runbook covers *the order to apply them*, *how to verify each step against AWS*, and *what to do if something goes wrong*. The repo containing this plan is treated as the **source-of-truth code repo** that gets pulled onto the deploy machine — Terraform state and credentials live only on the deploy machine.

**Tech Stack:** Terraform ≥1.7 (required for `import {}` and `removed {}` blocks), AWS CLI v2, `jq`, Bash.

**Placeholders used throughout** — substitute at execution time, do **not** treat as TBD:

| Placeholder | Meaning | Example |
|---|---|---|
| `<service>` | A service name from the deploy environment (work-specific, never committed) | `billing` |
| `<alias>` | A target AWS account alias from `foundation/ops` outputs | `account-dev` |
| `<primary-region>` | The deploy environment's primary AWS region | `ap-northeast-1` |
| `<bucket-name>` | The Ops-account state bucket created in M0a | `acme-tf-state-prod` |
| `<branch>` | The branch carrying the refactor code (e.g. `refactor/m1-m6`) | `refactor/m1-m6` |
| `<ops-account-id>` | Numeric AWS account ID of the Ops account | `123456789012` |

---

## Pre-Conditions

Read before starting any stage:

- The five existing milestone plans (`docs/superpowers/plans/2026-04-18-m*.md`) and the design spec (`docs/superpowers/specs/2026-04-18-cloudwatch-alarm-refactor-design.md`) are required reading. This runbook does **not** repeat their contents.
- The deploy machine has AWS CLI profiles configured for the Ops account and **every** target account alias.
- The repo on the deploy machine is checked out at the same commit as the source-of-truth repo. Never edit Terraform files directly on the deploy machine.
- A maintenance/coordination window has been agreed with anyone who consumes the existing CloudWatch alarms (oncall, dashboards, alarm-driven automation).

---

## File Structure

This runbook **does not create or modify any source files**. All changes are AWS state changes plus the existing branches in the repo.

Files referenced (read-only) at execution time:

- `stacks/foundation/ops/{main.tf,backend.hcl,terraform.tfvars.example}`
- `stacks/platform/<alias>/{main.tf,backend.hcl,terraform.tfvars.example}`
- `stacks/services/<service>/<alias>/{main.tf,backend.hcl,terraform.tfvars.example}`
- `scripts/migrate/scaffold-leaf.sh`, `scripts/migrate/generate-split.sh`
- The old monolithic root: `main.tf`, `variables.tf`, `terraform.tfvars` (deleted in Stage 5)

---

## Stage 0: One-Time Pre-Flight (do before Stage 1)

Run these once per deploy machine.

### Task 0.1: Verify toolchain versions

**Files:** none (verification only)

- [ ] **Step 1: Check Terraform version**

```bash
terraform version
```

Expected: `Terraform v1.7.x` or later. If older: install/upgrade before proceeding — `import {}` and `removed {}` blocks are required for the M2/M3 cutover.

- [ ] **Step 2: Check AWS CLI version**

```bash
aws --version
```

Expected: `aws-cli/2.x.x`. Older v1 may work but is not tested.

- [ ] **Step 3: Check `jq` is installed**

```bash
jq --version
```

Expected: any version. Install via package manager if missing — used extensively for verification.

### Task 0.2: Verify AWS credentials for every account

**Files:** none (verification only)

- [ ] **Step 1: Verify Ops account profile**

```bash
aws --profile ops sts get-caller-identity
```

Expected: `Account` field matches `<ops-account-id>`. If credentials are stale: refresh via SSO / session token before proceeding.

- [ ] **Step 2: Verify each target account alias**

For each `<alias>` (e.g. `account-dev`, `account-stg`, `account-prod`):

```bash
aws --profile <alias> sts get-caller-identity
```

Expected: `Account` field matches the ID for that alias in your Ops `accounts` mapping.

If any profile fails: stop. Fix credentials before any apply. Half-deployed state is harder to recover than not starting.

### Task 0.3: Snapshot the current alarm baseline

**Files:** none (capture only)

- [ ] **Step 1: For each target account, snapshot the alarm list**

```bash
mkdir -p /tmp/alarm-baseline
for alias in <alias-1> <alias-2> ...; do
  aws --profile $alias cloudwatch describe-alarms \
    --output json > /tmp/alarm-baseline/${alias}-baseline.json
  echo "$alias: $(jq '.MetricAlarms | length' /tmp/alarm-baseline/${alias}-baseline.json) alarms"
done
```

Expected: an alarm count per account that matches your current monolithic-root deploy. Save these counts — they are the invariant the cutover must preserve.

- [ ] **Step 2: Commit the baseline somewhere durable**

```bash
cp /tmp/alarm-baseline/* ~/cutover-baselines/$(date +%Y%m%d)/
```

This is the only "after" comparison that catches silent alarm churn during M2/M3.

### Task 0.4: Sync the deploy repo to the source-of-truth branch

**Files:** none (git only)

- [ ] **Step 1: Fetch and check out the refactor branch on the deploy machine**

```bash
git fetch origin
git checkout <branch>
git pull --ff-only origin <branch>
```

Expected: working tree clean, HEAD matches the source-of-truth repo. If you get merge conflicts or non-fast-forward: stop and investigate — a divergence between machines means someone edited the deploy machine's working tree, which violates the workflow.

---

## Stage 1: M0 — Foundation + Platform Bootstrap

Implements the foundation layer. Cannot be skipped or partially applied — every later stage depends on the Ops state bucket and per-account SNS topics.

### Task 1.1: Bootstrap `foundation/ops` (chicken-and-egg)

**Files:**
- Read: `stacks/foundation/ops/main.tf`
- Use: `stacks/foundation/ops/backend.hcl`
- See: M0/M1 plan section "M0a — foundation/ops"

- [ ] **Step 1: Initialize with local state**

```bash
cd stacks/foundation/ops
terraform init
```

Expected: `Terraform has been successfully initialized!`. Backend is `local` for now — the bucket doesn't exist yet.

- [ ] **Step 2: Plan**

```bash
terraform plan
```

Expected: creates exactly one S3 bucket, one KMS CMK + alias, one IAM role (`tf-state-access`), and any associated policies. **Anything else in the plan: stop and reconcile against the M0 plan before applying.**

- [ ] **Step 3: Apply with local state**

```bash
terraform apply
```

Confirm `yes`. Expected: all resources created, `terraform.tfstate` lands as a local file in the working directory.

- [ ] **Step 4: Migrate state into the new bucket**

```bash
terraform init -backend-config=backend.hcl -migrate-state
```

Confirm `yes` to copy local state into the new S3 backend. Expected: `Successfully configured the backend "s3"!` and the local `terraform.tfstate` is renamed to `terraform.tfstate.backup`.

- [ ] **Step 5: Verify the migration is idempotent**

```bash
terraform plan
```

Expected: `No changes. Your infrastructure matches the configuration.` If any drift: state migration was incomplete — restore from `terraform.tfstate.backup` and re-attempt.

- [ ] **Step 6: Verify the bucket and role exist**

```bash
aws --profile ops s3 ls s3://<bucket-name>/foundation/ops/
aws --profile ops iam get-role --role-name tf-state-access
```

Expected: both succeed. The bucket lists `terraform.tfstate`; the role has the trust policy permitting each target account to assume it.

### Task 1.2: Apply each `platform/<alias>` stack

**Files:**
- Read: `stacks/platform/<alias>/main.tf`
- Use: `stacks/platform/<alias>/backend.hcl`
- See: M0/M1 plan section "M0b — platform stacks"

Repeat this task once per `<alias>` (e.g. `dev`, then `stg`, then `prod`). **Apply lower environments first** so failures surface before they reach prod.

- [ ] **Step 1: Initialize with the Ops backend**

```bash
cd stacks/platform/<alias>
terraform init -backend-config=backend.hcl
```

Expected: `Successfully configured the backend "s3"!`. The backend points to a key like `platform/<alias>/terraform.tfstate` in the Ops bucket.

- [ ] **Step 2: Plan**

```bash
terraform plan
```

Expected: creates SNS topics for WARN, ERROR, CRIT in `<primary-region>` plus the same three topics in `us-east-1` (for CloudFront). Plan should show **zero destroys**. If destroys appear: state already exists for this stack — stop and reconcile.

- [ ] **Step 3: Apply**

```bash
terraform apply
```

Confirm `yes`. Expected: 6 SNS topics created (3 severities × 2 regions).

- [ ] **Step 4: Verify SNS topics are reachable from the target account**

```bash
aws --profile <alias> sns list-topics --region <primary-region> | jq '.Topics[] | select(.TopicArn | test("warn|error|crit"; "i"))'
aws --profile <alias> sns list-topics --region us-east-1       | jq '.Topics[] | select(.TopicArn | test("warn|error|crit"; "i"))'
```

Expected: 3 topics per region whose ARNs match the outputs from `terraform output`. If a topic is missing in `us-east-1`: the CloudFront provider alias was misconfigured — fix and re-apply.

### Stage 1 Exit Gate

Do not proceed to Stage 2 until **all** of:

- `foundation/ops` applied, state migrated to S3, `terraform plan` clean
- Every `platform/<alias>` stack applied, SNS topics verified in both `<primary-region>` and `us-east-1`
- The cross-account `tf-state-access` role is assumable from each target account (test with `aws --profile <alias> sts assume-role --role-arn arn:aws:iam::<ops-account-id>:role/tf-state-access --role-session-name test`)

---

## Stage 2: M2 — Pilot Service Cutover

Migrates **one** `(service, account-alias)` pair from the old monolithic root into a dedicated stack. State-only move — no alarm in AWS is destroyed or recreated.

### Task 2.1: Pre-cutover snapshot

**Files:** none (capture only)

- [ ] **Step 1: Snapshot every alarm in the pilot's target account**

```bash
aws --profile <alias> cloudwatch describe-alarms --output json \
  > /tmp/alarm-baseline/<service>-<alias>-before.json
echo "Pilot account total alarms: $(jq '.MetricAlarms | length' /tmp/alarm-baseline/<service>-<alias>-before.json)"
```

Expected: a number that matches the count in `/tmp/alarm-baseline/<alias>-baseline.json` from Task 0.3 (no churn since baseline). If different: investigate before cutover — something else is changing alarms.

### Task 2.2: Apply the new pilot stack (imports)

**Files:**
- Read: `stacks/services/<service>/<alias>/main.tf`
- Read: `stacks/services/<service>/<alias>/import.tf` (or `imports.tf` — generated by M2 plan)
- See: M2 plan section "Cutover sequence"

- [ ] **Step 1: Initialize**

```bash
cd stacks/services/<service>/<alias>
terraform init -backend-config=backend.hcl
```

Expected: backend configured against the Ops bucket at key `services/<service>/<alias>/terraform.tfstate`.

- [ ] **Step 2: Plan and review carefully**

```bash
terraform plan
```

Expected output must satisfy **all** of:

1. Every alarm shows as `will be imported` — never `will be created` and never `will be destroyed`.
2. The bottom-line plan summary reads `Plan: 0 to add, 0 to change, 0 to destroy.` (imports are reported separately from the add/change/destroy counts).
3. The list of imports has the **same length** as the alarm count from Task 2.1.

If any of these fail: **stop**. The most common cause is a tfvars drift between the new stack and the old root for this service — reconcile and re-plan. **Do not apply if a single alarm shows as create or destroy** — that means alarm churn (transient OK→INSUFFICIENT_DATA→ALARM flicker).

- [ ] **Step 3: Apply imports**

```bash
terraform apply
```

Confirm `yes`. Expected: every import succeeds; no resources created or destroyed.

- [ ] **Step 4: Verify the new state is complete**

```bash
terraform state list | wc -l
```

Expected: matches the alarm count from Task 2.1 (plus any non-alarm resources defined in the new stack — typically zero at this point).

### Task 2.3: Apply the old root (removed blocks)

**Files:**
- Modify: repo-root `main.tf` — `removed {}` blocks for the migrated service (added per the M2 plan)
- See: M2 plan section "Drop from old state"

- [ ] **Step 1: From repo root, plan**

```bash
cd <repo-root>
terraform plan
```

Expected: every alarm being moved appears as `will no longer be managed by Terraform, but will not be destroyed`. Plan summary: `Plan: 0 to add, 0 to change, 0 to destroy.` (`removed` blocks reported separately).

If any alarm shows as `will be destroyed` instead of `will no longer be managed`: the `removed` block is missing the `lifecycle { destroy = false }` clause — fix and re-plan.

- [ ] **Step 2: Apply**

```bash
terraform apply
```

Confirm `yes`. Expected: state shrinks; AWS is unchanged.

- [ ] **Step 3: Verify the old root no longer references the migrated alarms**

```bash
terraform state list | grep -c '<service>'
```

Expected: `0`. If non-zero: a `removed` block was missed — add it and re-apply.

### Task 2.4: Post-cutover verification

**Files:** none (verification only)

- [ ] **Step 1: Snapshot and diff**

```bash
aws --profile <alias> cloudwatch describe-alarms --output json \
  > /tmp/alarm-baseline/<service>-<alias>-after.json

diff <(jq -S '[.MetricAlarms[] | .AlarmArn] | sort' /tmp/alarm-baseline/<service>-<alias>-before.json) \
     <(jq -S '[.MetricAlarms[] | .AlarmArn] | sort' /tmp/alarm-baseline/<service>-<alias>-after.json)
```

Expected: **empty diff**. Same set of alarm ARNs before and after. Any line of diff output = something was destroyed/recreated/created — investigate immediately.

- [ ] **Step 2: Spot-check that alarms still route to SNS**

Pick one alarm from the cutover and confirm its `AlarmActions` still point to the platform SNS topics:

```bash
aws --profile <alias> cloudwatch describe-alarms \
  --alarm-names "<one-known-alarm-name>" \
  --query 'MetricAlarms[0].AlarmActions'
```

Expected: ARNs match the `platform/<alias>` SNS topics from Stage 1. If empty or pointing elsewhere: the new stack's `sns_topic_arns` mapping is wrong — fix in code, push, pull, re-apply.

- [ ] **Step 3: Wait 1 alarm period and confirm no flapping**

Watch the pilot account's alarms for one full evaluation period (typically 5–15 min). Expected: no alarms transition state. If any alarm flips to `INSUFFICIENT_DATA` and recovers: alarm was recreated, not imported — investigate.

### Stage 2 Exit Gate

Do not proceed to Stage 3 until:

- Diff in Task 2.4 Step 1 is empty
- Spot-checked alarm still routes to the correct SNS topic
- One full alarm evaluation period has passed without state transitions

---

## Stage 3: M3 — Remaining Service Cutovers (Loop)

Repeat the M2 pattern for every remaining `(service, account-alias)` pair. **Process one pair at a time**: code → push → pull → cutover → verify → next.

### Task 3.1: Identify the next pair

**Files:** none (planning only)

- [ ] **Step 1: List services still owned by the old root**

```bash
cd <repo-root>
terraform state list | grep aws_cloudwatch_metric_alarm \
  | sed -E 's|module\.([^.]+)\..*|\1|' \
  | sort -u
```

Expected: a list of module instance keys that still need cutting over. Each one corresponds to a `(service, account-alias)` pair in the old tfvars.

- [ ] **Step 2: Pick the next pair**

Lowest-risk first: lower environments before higher ones, less-critical services before more-critical. Document the choice in your cutover log.

### Task 3.2: Scaffold the leaf stack on the source-of-truth machine

**Files:**
- Create: `stacks/services/<service>/<alias>/{main.tf,backend.hcl,terraform.tfvars,...}` via the migration script
- See: M3 plan section "Per-leaf scaffolding"

This task happens on the **source-of-truth machine**, not the deploy machine.

- [ ] **Step 1: Run the scaffold script**

```bash
scripts/migrate/scaffold-leaf.sh <service> <alias>
```

Expected: a new `stacks/services/<service>/<alias>/` directory containing `main.tf`, `backend.hcl`, `providers.tf`, `versions.tf`, and a populated `terraform.tfvars` derived from the corresponding section of the old root tfvars.

- [ ] **Step 2: Generate import + removed blocks**

```bash
scripts/migrate/generate-split.sh <service> <alias>
```

Expected: an `import.tf` in the new stack and a corresponding patch to the old root adding `removed {}` blocks for the same resources.

- [ ] **Step 3: Review the generated diff**

```bash
git diff
```

Manually verify: the import block addresses on the new side match the resource addresses on the old side. Mismatches cause plan-time "will be created" / "will be destroyed" rather than imports.

- [ ] **Step 4: Commit and push**

```bash
git add stacks/services/<service>/<alias>/ main.tf
git commit -m "feat(m3): scaffold <service>/<alias> cutover"
git push origin <branch>
```

### Task 3.3: Cut over on the deploy machine

**Files:** same as Task 2.2/2.3 but parameterized by the new pair.

- [ ] **Step 1: Pull on the deploy machine**

```bash
git fetch origin
git pull --ff-only origin <branch>
```

Expected: fast-forward, no merge conflicts. If conflict: someone edited the deploy machine — stop.

- [ ] **Step 2: Re-run the M2 procedure for this pair**

Repeat **every step of Task 2.1, 2.2, 2.3, and 2.4** using `<service>` and `<alias>` for the new pair. Do not skip the snapshot/verify steps — they are what proves no alarm churn.

- [ ] **Step 3: Mark the pair done**

Add the pair to your cutover log with the date, the alarm count migrated, and a link to the diff comparison output.

### Task 3.4: Loop until done

- [ ] **Step 1: Check whether anything remains in the old root**

```bash
cd <repo-root>
terraform state list | grep aws_cloudwatch_metric_alarm | wc -l
```

Expected after final pair: `0`. If non-zero: return to Task 3.1 and pick the next pair.

### Stage 3 Exit Gate

Do not proceed to Stage 4 until:

- `terraform state list | grep aws_cloudwatch_metric_alarm` on the old root returns zero
- Per-pair diff verification (Task 2.4 Step 1) was empty for every cutover
- The total alarm count across all target accounts matches the Stage 0 baseline

---

## Stage 4: M4 — Decommission the Old Monolithic Root

Once every alarm is owned by a leaf stack, the old root is dead code holding empty state.

### Task 4.1: Confirm the old root holds no resources

**Files:**
- Read: repo-root `main.tf`, `terraform.tfvars`

- [ ] **Step 1: Plan the old root**

```bash
cd <repo-root>
terraform plan
```

Expected: `No changes. Your infrastructure matches the configuration.` If `plan` shows **any** create or destroy: do not proceed — Stage 3 is incomplete.

- [ ] **Step 2: List remaining state**

```bash
terraform state list
```

Expected: empty, or only contains the `removed {}` block placeholders (which carry no real resources).

### Task 4.2: Archive the old state

**Files:** none (archival only)

- [ ] **Step 1: Pull the old state to a local file**

```bash
terraform state pull > /tmp/old-root-state-$(date +%Y%m%d).json
```

- [ ] **Step 2: Upload to the Ops bucket archive prefix**

```bash
aws --profile ops s3 cp /tmp/old-root-state-$(date +%Y%m%d).json \
  s3://<bucket-name>/archived/old-root-$(date +%Y%m%d).json
```

Expected: upload succeeds. This is your "if everything else fails" recovery point.

### Task 4.3: Delete the old root from the source-of-truth repo

**Files:**
- Delete: repo-root `main.tf`, `variables.tf`, `terraform.tfvars`, `terraform.tfvars.example`
- See: M4 plan section "File deletions"

This task happens on the **source-of-truth machine**.

- [ ] **Step 1: Delete the files**

```bash
git rm main.tf variables.tf terraform.tfvars terraform.tfvars.example
```

- [ ] **Step 2: Update README/CLAUDE.md to remove old-root references**

See M4 plan for the doc changes — don't reproduce them here.

- [ ] **Step 3: Commit and push**

```bash
git commit -m "chore(m4): decommission old monolithic root"
git push origin <branch>
```

### Task 4.4: Apply the deletion on the deploy machine

**Files:** none (state cleanup only)

- [ ] **Step 1: Pull**

```bash
git fetch origin && git pull --ff-only origin <branch>
```

- [ ] **Step 2: Optionally delete the old state file**

The state in the Ops bucket is now orphaned. Either leave it (cheap, useful as a redundant archive) or delete it:

```bash
aws --profile ops s3 rm s3://<bucket-name>/old-root/terraform.tfstate
```

Recommended: **leave it**. The bucket has versioning; cost is negligible; and if rollback is ever needed it's the canonical state.

### Stage 4 Exit Gate

- All old-root `.tf` files removed from the repo
- Old state archived in the Ops bucket
- README/CLAUDE.md updated to point at `stacks/...` as the only deploy entry points

---

## Rollback Procedures

Each stage's failure mode and recovery.

### Stage 1 (M0) failures

- **`foundation/ops` state migration fails partway** → the local `terraform.tfstate.backup` is preserved. Run `terraform init -reconfigure` to revert to local backend, restore `terraform.tfstate` from `.backup`, and re-attempt.
- **`platform/<alias>` apply fails** → SNS topics are independent and idempotent. Re-running `terraform apply` is safe. If a topic was created but not tracked: `aws sns delete-topic --topic-arn <arn>` then re-apply.

### Stage 2/3 (M2/M3) failures

- **Plan shows alarm `will be created` or `will be destroyed`** → tfvars drift between new stack and old root. **Do not apply.** Reconcile the resource list and re-plan.
- **Imports succeed but `removed` blocks fail to apply on old root** → alarms are now tracked in two states. Both states pointing at the same AWS resource is *safe* (neither will destroy it without a `removed` lifecycle override), but it's wrong. Investigate whether the `removed` block syntax is correct for your Terraform version.
- **Imports fail with "resource not found"** → the import block's resource address doesn't match the alarm in AWS. Check the AWS console or `aws cloudwatch describe-alarms` for the actual `AlarmName` and update the import.
- **Post-apply diff shows alarms missing in AWS** → emergency restore: pull the most recent old-root state from S3 versioning (`aws s3api list-object-versions ...`), `terraform state push <restored-state>` on the old root, then `terraform apply` to recreate the missing alarms. SNS topic ARNs from Stage 1 are stable, so re-created alarms will route correctly.

### Stage 4 (M4) failures

- **Plan shows resources still in old root** → Stage 3 is incomplete; do not delete the root files. Return to Task 3.1.
- **Need to revive the old root** → `git revert` the M4 commit on the source-of-truth machine, push, pull on deploy, restore state from the S3 archive (`terraform state push`).

---

## Cross-Machine Sync Discipline

The personal/source-of-truth repo is the only place Terraform code is edited. The deploy machine is read-only for code; it produces state changes only.

- **Never** run `terraform fmt`, `terraform import` (CLI), `terraform state mv`, or any code edit on the deploy machine.
- After every apply on the deploy machine, the working tree should still match `git status` clean. If it doesn't, an apply wrote a backend file or a `.terraform.lock.hcl` change that needs to be ported back to the source-of-truth machine — commit on source-of-truth and re-pull.
- Per-iteration loop: edit on source-of-truth → push → pull on deploy → apply → verify.

---

## Verification Appendix

Useful commands to keep on hand:

```bash
# Total alarm count in an account
aws --profile <alias> cloudwatch describe-alarms --query 'length(MetricAlarms)'

# Alarms in a specific state
aws --profile <alias> cloudwatch describe-alarms --state-value ALARM \
  --query 'MetricAlarms[].AlarmName'

# Alarms whose actions point to a specific SNS topic
aws --profile <alias> cloudwatch describe-alarms --output json \
  | jq '[.MetricAlarms[] | select(.AlarmActions[] | contains("warn"))] | length'

# State of a single Terraform resource
terraform state show '<resource.address>'

# Resource addresses currently tracked
terraform state list | sort
```
