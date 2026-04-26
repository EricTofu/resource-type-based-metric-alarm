# Work-Repo Refactor Transfer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Note:** This plan is designed for **manual execution on a work machine without AI assistance**. The "subagent-driven" / "inline executing-plans" workflows do not apply — read it as a runbook and tick boxes by hand.

**Goal:** Transport the M0–M6 refactor (live in this generic public repo) into a separate, history-unrelated **work** repo that currently sits at the original monolithic state, while preserving the work repo's local edits to library modules and not disturbing its real Terraform state.

**Architecture:** Three repos exist on the work machine:
- **synced** — a clean clone of this public repo, on branch `refactor/m1-m6`. Read-only reference for the transfer; never modified by this plan.
- **work** — the deployment repo with real `terraform.tfvars`, real AWS state, and local commits to library modules. *This is what the plan modifies.*
- (origin lives on GitHub; not on the work machine.)

The transfer is **not a `git pull`** because synced and work have unrelated histories. Instead: `git mv` for the M1 rename (preserves work's per-file history), `cp` from synced for additive new files, and a **manual 3-way reconcile** for any library-module file where work has local edits that conflict with M6 hardening.

**Tech Stack:** git, bash, `cp`, `diff`, `terraform` ≥1.7.

**Placeholders used throughout** — substitute at execution time:

| Placeholder | Meaning | Example |
|---|---|---|
| `<synced>` | Filesystem path to the synced clone of origin on the work machine | `~/code/refactor-synced` |
| `<work>` | Filesystem path to the work deployment repo | `~/code/cw-alarms-work` |
| `<type>` | One of the 11 module types: `alb apigateway asg cloudfront ec2 elasticache lambda opensearch rds s3 ses` | `rds` |

---

## Pre-Conditions

- `<synced>` is checked out at branch `refactor/m1-m6` with a clean working tree. The synced repo is the reference; this plan never modifies it.
- `<work>` has no uncommitted changes (`git -C <work> status` is clean).
- `<work>` is currently at the original monolithic state — `modules/monitor-<type>/` exists, `modules/cloudwatch/` does not, no `stacks/` directory.
- Both repos coexist on the same filesystem so direct `cp` and `diff` work between them.
- Read these companion docs before starting:
  - `docs/superpowers/specs/2026-04-18-cloudwatch-alarm-refactor-design.md`
  - `docs/superpowers/plans/2026-04-26-deploy-cutover-runbook.md` (this transfer is a precondition for that runbook)

---

## File Structure

This plan only modifies files in `<work>`. High-level changes there:

| Action | Path | Source |
|---|---|---|
| Rename | `modules/monitor-<type>/` → `modules/cloudwatch/metrics-alarm/<type>/` (×11) | `git mv` in `<work>` |
| Overwrite | `modules/cloudwatch/metrics-alarm/<type>/{main,variables}.tf` (×11) | `cp` from `<synced>` (M6-hardened versions) |
| Create | `modules/cloudwatch/metrics-alarm/<type>/outputs.tf` (×11, new) | `cp` from `<synced>` |
| Create | `modules/cloudwatch/synthetics-canary/heartbeat/` | `cp -r` from `<synced>` |
| Create | `stacks/foundation/`, `stacks/platform/`, `stacks/services/billing/dev/` | `cp -r` from `<synced>` |
| Create | `scripts/migrate/{generate-split,scaffold-leaf}.sh` | `cp` from `<synced>` |
| Create | `.github/workflows/{preflight,terraform-ci}.yml`, `.tflint.hcl` | `cp` from `<synced>` |
| Overwrite | repo-root `main.tf` (module source paths updated to new library paths) | `cp` from `<synced>` |
| Overwrite | `CLAUDE.md` | `cp` from `<synced>` |
| Create | `docs/superpowers/{specs,plans}/` | `cp -r` from `<synced>` |
| **Untouched** | `terraform.tfvars`, `terraform.tfstate*`, `.terraform/`, repo-root `versions.tf`, `variables.tf`, `terraform.tfvars.example`, `README.md`, `resource-type-based-metric-alarm.md`, anything under `scripts/` not in `migrate/` | — |

After the transfer, `<work>` is structurally identical to `<synced>` *except* for: the work-specific `terraform.tfvars`, the AWS state, and any work-local edits that survived reconciliation in Stage 5.

---

## Stage 0: Pre-flight

### Task 0.1: Verify both repos and their states

**Files:** none (verification only)

- [ ] **Step 1: Confirm `<synced>` is on the refactor branch and clean**

```bash
cd <synced>
git status
git log --oneline -1
```

Expected: working tree clean, HEAD message starts with `feat(m6): tighten RDS DatabaseConnections fallback…` (or whatever the current tip of `refactor/m1-m6` is). If dirty: stop — synced must be a pristine reference.

- [ ] **Step 2: Confirm `<work>` is clean and on the original monolithic state**

```bash
cd <work>
git status
ls modules/
ls stacks/ 2>&1
```

Expected: working tree clean. `ls modules/` lists `monitor-alb`, `monitor-apigateway`, …, `monitor-ses` (and **not** `cloudwatch`). `ls stacks/` returns "No such file or directory". If anything is different, this plan does not apply as-written — stop and reassess.

- [ ] **Step 3: Set environment variables for the rest of the plan**

```bash
export SYNCED=<synced>   # absolute path
export WORK=<work>       # absolute path
echo "$SYNCED" && echo "$WORK"
```

Expected: both paths echo correctly. Every later step uses `$SYNCED` and `$WORK` — set these once and don't `cd` between repos without re-checking.

### Task 0.2: Snapshot AWS state for "did anything churn?" verification

**Files:** none (capture only)

- [ ] **Step 1: Capture pre-transfer alarm count for every account `<work>` deploys to**

```bash
mkdir -p ~/cutover-baselines/$(date +%Y%m%d)-pre-transfer
for alias in <alias-1> <alias-2> ...; do
  aws --profile $alias cloudwatch describe-alarms --output json \
    > ~/cutover-baselines/$(date +%Y%m%d)-pre-transfer/${alias}.json
  echo "$alias: $(jq '.MetricAlarms | length' ~/cutover-baselines/$(date +%Y%m%d)-pre-transfer/${alias}.json) alarms"
done
```

Expected: alarm count per account matches what's currently deployed. This is the invariant the transfer + later cutover must preserve. **Save these counts** — you'll diff against them after Stage 6 to prove the transfer alone changed nothing in AWS.

---

## Stage 1: Safety branch + baseline tag

If anything goes wrong, you want a one-command rollback.

### Task 1.1: Create rollback branch in work

**Files:** `<work>/.git` only (git plumbing)

- [ ] **Step 1: Tag the current state**

```bash
cd "$WORK"
git tag pre-refactor-transfer-$(date +%Y%m%d)
```

Expected: tag created. `git tag --list` includes the new tag.

- [ ] **Step 2: Create a long-lived rollback branch**

```bash
git branch pre-refactor-transfer-snapshot
git branch --list pre-refactor-transfer-snapshot
```

Expected: branch exists at the same SHA as your current HEAD.

- [ ] **Step 3: Create the working branch for the transfer**

```bash
git checkout -b refactor/m1-m6-transfer
```

Expected: now on `refactor/m1-m6-transfer`. All transfer work happens on this branch; merge to your usual deploy branch only after Stage 6 verifies clean.

---

## Stage 2: Inventory work's local edits to library modules

You need to know **before** overwriting files which module files in `<work>` carry local commits, so you can re-apply them after Stage 3 replaces those files with synced's M6-hardened versions.

### Task 2.1: List every commit in work that touches a module file

**Files:** `<work>` (read-only)

- [ ] **Step 1: List local commits touching `modules/`**

```bash
cd "$WORK"
git log --oneline --all -- modules/
```

Expected: a list of commits, oldest at bottom. Note the SHAs that touch `modules/monitor-<type>/` paths — these are the "local edits to preserve."

- [ ] **Step 2: For each commit identified above, save its patch**

```bash
mkdir -p /tmp/work-local-patches
for sha in <sha-1> <sha-2> ...; do
  git format-patch -1 $sha -o /tmp/work-local-patches/
done
ls /tmp/work-local-patches/
```

Expected: one `.patch` file per local commit. These are your "to be re-applied manually" stack.

- [ ] **Step 3: Build a per-file inventory of which module files are touched**

```bash
git log --name-only --pretty=format: --all -- modules/ \
  | grep '^modules/monitor-' \
  | sort -u
```

Expected: a deduplicated list of files like `modules/monitor-rds/main.tf`, `modules/monitor-ec2/variables.tf`, etc. **Save this list** — every file on it requires reconciliation in Stage 5; every file *not* on it is overwritten cleanly in Stage 3 with no manual work.

### Task 2.2: Sanity-check for unexpected modules

**Files:** `<work>` (read-only)

- [ ] **Step 1: Compare module directory listings between work and synced**

```bash
diff <(ls "$WORK/modules" | sort) \
     <(ls "$SYNCED/modules/cloudwatch/metrics-alarm" | sort | sed 's/^/monitor-/')
```

Expected: empty diff. If `<work>` has a `monitor-<type>` directory that `<synced>` doesn't have under `modules/cloudwatch/metrics-alarm/`, you've added a custom module that this transfer doesn't know about. **Stop and decide:**
- Port the custom module to the new structure manually before continuing, OR
- Skip it in Stage 3 (leave the old `modules/monitor-<type>/` in place — old root will keep referencing it).

---

## Stage 3: Apply structural changes (M1 rename + module overwrite)

For each of the 11 known module types: rename the directory (preserves git history), then overwrite the file contents from synced (which carry M6 hardening).

### Task 3.1: Rename and overwrite all 11 modules

**Files:** `<work>/modules/monitor-<type>/` and `<work>/modules/cloudwatch/metrics-alarm/<type>/` (×11)

- [ ] **Step 1: Create the new parent directories**

```bash
cd "$WORK"
mkdir -p modules/cloudwatch/metrics-alarm
```

Expected: directory created. `ls modules/cloudwatch/metrics-alarm` is empty.

- [ ] **Step 2: Rename each `monitor-<type>/` to `cloudwatch/metrics-alarm/<type>/` via `git mv`**

```bash
cd "$WORK"
for type in alb apigateway asg cloudfront ec2 elasticache lambda opensearch rds s3 ses; do
  git mv modules/monitor-$type modules/cloudwatch/metrics-alarm/$type
done
git status
```

Expected: `git status` shows 22 renames (`R` lines) — `main.tf` and `variables.tf` for each of 11 types. **No untracked, no modified-but-not-staged.** If `git mv` failed for any type (e.g., `monitor-foo` doesn't exist), drop that one from the list and re-run for the rest.

- [ ] **Step 3: Overwrite each file's contents with synced's M6-hardened version**

```bash
cd "$WORK"
for type in alb apigateway asg cloudfront ec2 elasticache lambda opensearch rds s3 ses; do
  cp "$SYNCED/modules/cloudwatch/metrics-alarm/$type/main.tf"      modules/cloudwatch/metrics-alarm/$type/main.tf
  cp "$SYNCED/modules/cloudwatch/metrics-alarm/$type/variables.tf" modules/cloudwatch/metrics-alarm/$type/variables.tf
  cp "$SYNCED/modules/cloudwatch/metrics-alarm/$type/outputs.tf"   modules/cloudwatch/metrics-alarm/$type/outputs.tf
done
git status
```

Expected: `git status` shows the 22 renames as **renamed + modified** (`R` with content changes), plus 11 new untracked files (`outputs.tf` for each type).

- [ ] **Step 4: Stage the new `outputs.tf` files**

```bash
cd "$WORK"
for type in alb apigateway asg cloudfront ec2 elasticache lambda opensearch rds s3 ses; do
  git add modules/cloudwatch/metrics-alarm/$type/outputs.tf
done
git status
```

Expected: 11 new files in the index, alongside the 22 renamed-and-modified files.

### Task 3.2: Update the old root's module source references

The repo-root `main.tf` has `source = "./modules/monitor-<type>"` lines. After the rename, those break. Synced's `main.tf` already has the corrected paths (`source = "./modules/cloudwatch/metrics-alarm/<type>"`).

- [ ] **Step 1: Overwrite work's root `main.tf` with synced's**

```bash
cp "$SYNCED/main.tf" "$WORK/main.tf"
git -C "$WORK" status
```

Expected: `main.tf` shows as modified. **Do not** also overwrite `variables.tf` or `terraform.tfvars` from synced — those carry your work-specific values.

- [ ] **Step 2: Diff work's now-overwritten `main.tf` against the version it had before**

```bash
cd "$WORK"
git diff main.tf
```

Expected: only the module `source =` lines change (and any related path references). If your local `main.tf` had work-specific module instantiation logic (extra modules, custom for_each), this diff will lose it. **If you see a loss, stop:** restore your version (`git checkout pre-refactor-transfer-snapshot -- main.tf`) and reconcile manually before proceeding.

### Task 3.3: Commit the structural change

- [ ] **Step 1: Commit the rename + module overwrite + root reference update**

```bash
cd "$WORK"
git commit -m "refactor: rename monitor-<type> to cloudwatch/metrics-alarm/<type>; pull M6 hardening from upstream"
```

Expected: one commit landing all module-rename, content-overwrite, and root-reference-update changes.

---

## Stage 4: Drop in additive new content

Everything in this stage is purely additive — these paths don't exist in `<work>` yet, so no conflict possible.

### Task 4.1: Copy new library and stacks directories

**Files:** new directories under `<work>`

- [ ] **Step 1: Copy the synthetics-canary library module**

```bash
cp -r "$SYNCED/modules/cloudwatch/synthetics-canary" "$WORK/modules/cloudwatch/synthetics-canary"
ls "$WORK/modules/cloudwatch/synthetics-canary/heartbeat"
```

Expected: at least `main.tf`, `variables.tf`, and a `.build/` subdirectory if synced has one.

- [ ] **Step 2: Copy the foundation, platform, and services stacks**

```bash
cp -r "$SYNCED/stacks" "$WORK/stacks"
ls "$WORK/stacks/foundation/ops"
ls "$WORK/stacks/platform"
ls "$WORK/stacks/services/billing/dev"
```

Expected: the directory tree mirrors synced (foundation/ops, platform/{dev,stg,prod}, services/billing/dev).

- [ ] **Step 3: Copy the migration scripts**

```bash
mkdir -p "$WORK/scripts/migrate"
cp "$SYNCED/scripts/migrate/scaffold-leaf.sh"   "$WORK/scripts/migrate/scaffold-leaf.sh"
cp "$SYNCED/scripts/migrate/generate-split.sh"  "$WORK/scripts/migrate/generate-split.sh"
chmod +x "$WORK/scripts/migrate/"*.sh
```

Expected: both scripts present and executable.

### Task 4.2: Copy CI workflows and lint config

- [ ] **Step 1: Copy CI workflows**

```bash
mkdir -p "$WORK/.github/workflows"
cp "$SYNCED/.github/workflows/preflight.yml"    "$WORK/.github/workflows/preflight.yml"
cp "$SYNCED/.github/workflows/terraform-ci.yml" "$WORK/.github/workflows/terraform-ci.yml"
```

Expected: both workflows present. **Note:** these workflows reference `secrets.PREFLIGHT_READ_ROLE_ARN` and similar — they will not run usefully on the work-machine repo until those secrets are configured wherever you push it.

- [ ] **Step 2: Copy `.tflint.hcl`**

```bash
cp "$SYNCED/.tflint.hcl" "$WORK/.tflint.hcl"
```

### Task 4.3: Copy docs

- [ ] **Step 1: Copy the entire docs directory**

```bash
cp -r "$SYNCED/docs" "$WORK/docs"
```

Expected: `<work>/docs/superpowers/{specs,plans}/` populated. This brings the milestone plans, the deploy runbook, and this transfer plan itself onto the work machine for offline reference.

- [ ] **Step 2: Refresh CLAUDE.md from synced**

```bash
cp "$SYNCED/CLAUDE.md" "$WORK/CLAUDE.md"
```

Expected: `<work>/CLAUDE.md` updated to reflect the new module layout. If you maintained a work-specific CLAUDE.md, save it under a different name (e.g., `CLAUDE.work.md`) before this step and merge by hand.

### Task 4.4: Commit the additive content

- [ ] **Step 1: Stage and commit**

```bash
cd "$WORK"
git add modules/cloudwatch/synthetics-canary stacks scripts/migrate \
        .github/workflows .tflint.hcl docs CLAUDE.md
git commit -m "feat: import M0/M2/M6 stacks, scripts, CI, synthetics-canary, docs from upstream"
```

Expected: one commit with all the new tree.

---

## Stage 5: Reconcile work's local module edits

For every file on the inventory list from Task 2.1 Step 3, your local edits were just overwritten by synced's M6-hardened version in Stage 3. This stage re-applies them by hand.

### Task 5.1: For each touched module file, perform a 3-way reconcile

Repeat the steps below **once per file** on the inventory list.

**Files:** `<work>/modules/cloudwatch/metrics-alarm/<type>/<file>` (the new path of the file you locally edited)

- [ ] **Step 1: Pull up the work-local diff for this file**

Find the patch(es) in `/tmp/work-local-patches/` that touch this file:

```bash
grep -l "modules/monitor-<type>/<file>" /tmp/work-local-patches/*.patch
```

Open each match in an editor.

- [ ] **Step 2: Open the new (M6-hardened) version and the diff side-by-side**

```bash
# Left pane: the file as it now exists in work (M6 version, just copied from synced)
$EDITOR "$WORK/modules/cloudwatch/metrics-alarm/<type>/<file>"
# Right pane: the patch describing your local edits (against the pre-M6 version)
$EDITOR /tmp/work-local-patches/<patch-file>
```

- [ ] **Step 3: Decide for each hunk in the patch**

For each hunk:
- **Already done by M6?** Skip — your local edit and M6 made the same change. (Common for hardening overlap, e.g., you added a `validation {}` block locally and M6 added the same one.)
- **Compatible with M6?** Re-transcribe the hunk's added/removed lines onto the new file. Watch for line-number drift — search for nearby anchor strings rather than trusting the patch's line numbers.
- **Conflicts with M6?** You changed the same lines M6 changed, but to different ends. Decide which wins — favor M6 if the work-local edit was ad-hoc; favor the local edit if it captures behavior M6 didn't anticipate.

- [ ] **Step 4: Save and verify the file still parses**

```bash
cd "$WORK"
terraform fmt modules/cloudwatch/metrics-alarm/<type>/<file>
```

Expected: no errors. If `terraform fmt` rewrites the file, that's fine — it's just whitespace.

- [ ] **Step 5: Mark the patch as applied**

Move the patch out of the active queue:

```bash
mkdir -p /tmp/work-local-patches/applied
mv /tmp/work-local-patches/<patch-file> /tmp/work-local-patches/applied/
```

This avoids accidentally re-applying it later.

### Task 5.2: Commit the reconciled edits

- [ ] **Step 1: Review the cumulative reconciliation diff**

```bash
cd "$WORK"
git diff modules/cloudwatch/metrics-alarm/
```

Expected: only the manual reconciliations from Task 5.1, nothing else.

- [ ] **Step 2: Commit**

```bash
git add modules/cloudwatch/metrics-alarm/
git commit -m "feat: re-apply work-local module edits on top of M6 hardening"
```

If `/tmp/work-local-patches/` is empty (no work-local module edits existed), skip this stage entirely — Stage 3's commit already reflects the final state.

---

## Stage 6: Verify the transfer didn't break anything

The structural transfer is done. Before tagging this complete, verify that Terraform sees the same world it did before — same plan output, same alarm count.

### Task 6.1: Format and validate

**Files:** all of `<work>`

- [ ] **Step 1: Run `terraform fmt` recursively**

```bash
cd "$WORK"
terraform fmt -recursive -check
```

Expected: no output (everything already formatted). If files are listed: re-run without `-check` to fix, then commit `chore: terraform fmt`.

- [ ] **Step 2: Validate the root and every leaf stack**

```bash
cd "$WORK"
terraform init -backend=false
terraform validate

for stack in stacks/foundation/ops stacks/platform/* stacks/services/*/*; do
  echo "--- validating $stack ---"
  (cd "$stack" && terraform init -backend=false && terraform validate)
done
```

Expected: every `validate` reports `Success! The configuration is valid.`. If any module reports a missing required variable that's set via `terraform.tfvars` at apply time, that's expected — `validate` doesn't load tfvars. If any reports a syntax error or unknown resource, fix before continuing.

### Task 6.2: Plan against real AWS — old root must show no changes

This is the critical "did the transfer break anything?" gate. Because Stage 3 only renamed module *paths* (the resources Terraform creates are unchanged), `terraform plan` on the old root should report no changes.

- [ ] **Step 1: From repo root, init against the existing state backend and plan**

```bash
cd "$WORK"
terraform init   # uses your existing backend config
terraform plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

If plan shows any **destroy** or **create** for a `aws_cloudwatch_metric_alarm`: the transfer broke a resource address. Common causes:
- A `for_each` key changed because a `name` field was edited during reconciliation. Restore the key.
- A module call's instance name changed in `main.tf`. Diff against the snapshot branch and restore.

If plan shows any **error** about validation (e.g. "severity must be one of WARN, ERROR, CRIT"): your `terraform.tfvars` has values that don't satisfy the new M6 validations. Fix the tfvars (uppercase severity, threshold ≥ 0, etc.), don't disable the validation.

**Do not apply.** Plan must come back clean before this stage exits.

### Task 6.3: Confirm AWS-side count is still the baseline

- [ ] **Step 1: Re-snapshot alarm counts and diff against pre-transfer baseline**

```bash
DATE=$(date +%Y%m%d)
mkdir -p ~/cutover-baselines/$DATE-post-transfer
for alias in <alias-1> <alias-2> ...; do
  aws --profile $alias cloudwatch describe-alarms --output json \
    > ~/cutover-baselines/$DATE-post-transfer/${alias}.json
  diff <(jq -S '[.MetricAlarms[] | .AlarmArn] | sort' ~/cutover-baselines/$DATE-pre-transfer/${alias}.json) \
       <(jq -S '[.MetricAlarms[] | .AlarmArn] | sort' ~/cutover-baselines/$DATE-post-transfer/${alias}.json)
done
```

Expected: empty diff for every account. Same alarm ARNs as before the transfer — proves no apply happened (or if any did, no churn).

---

## Stage 7: Wrap up

### Task 7.1: Merge transfer branch back into your usual deploy branch

**Files:** `<work>/.git` only

- [ ] **Step 1: Merge `refactor/m1-m6-transfer` into your normal working branch**

Replace `<deploy-branch>` with whatever you usually deploy from (often `main` in the work repo).

```bash
cd "$WORK"
git checkout <deploy-branch>
git merge --ff-only refactor/m1-m6-transfer
```

Expected: fast-forward merge. If non-fast-forward: someone committed to `<deploy-branch>` while you were transferring — merge or rebase manually.

- [ ] **Step 2: Delete the transient transfer branch**

```bash
git branch -d refactor/m1-m6-transfer
```

Expected: branch deleted (it's now reachable from `<deploy-branch>`).

- [ ] **Step 3: Keep the rollback branch and tag**

Leave `pre-refactor-transfer-snapshot` and the `pre-refactor-transfer-<date>` tag in place for at least the duration of the deploy cutover (Stages 1–4 of the deploy runbook). Delete after the cutover succeeds and you've verified parity over a few days.

### Task 7.2: Hand off to the deploy runbook

- [ ] **Step 1: Open the deploy runbook**

```bash
$EDITOR "$WORK/docs/superpowers/plans/2026-04-26-deploy-cutover-runbook.md"
```

Start at **Stage 0: One-Time Pre-Flight**. The runbook now operates on `<work>` directly — there is no separate "deploy machine" since `<work>` *is* the deploy machine.

The transfer is complete; the rest of the refactor (M0/M2/M3/M4 against real AWS) is sequenced by the deploy runbook.

---

## Rollback

If anything goes wrong before you hit Task 7.1's merge, full rollback is one command:

```bash
cd "$WORK"
git checkout pre-refactor-transfer-snapshot
git branch -D refactor/m1-m6-transfer  # discard the in-progress transfer
# Optional: scrub untracked files copied in from synced
git clean -fd modules/cloudwatch stacks scripts/migrate .github .tflint.hcl
```

After the merge in Task 7.1, rollback is `git reset --hard pre-refactor-transfer-<date>` (the tag from Task 1.1) — destructive, do only if Stage 6 verification revealed a problem you can't fix forward.
