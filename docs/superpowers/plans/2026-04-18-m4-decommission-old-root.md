# M4: Decommission the Old Monolithic Root — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the now-empty root Terraform configuration and archive its state. After M4, the repo root contains no `.tf` files at top level; every `terraform apply` happens inside `stacks/services/<service>/<alias>/` (or `stacks/foundation/ops/`, `stacks/platform/<alias>/`).

**Architecture:**
- M4 is deletion + documentation only. No new Terraform resources, no state moves.
- Safety net: after M3, the old root's state is confirmed empty. M4's first task re-verifies that invariant before touching anything.
- State backups in `backups/pre-*-tfstate` stay on disk for 30 days (spec §Safety nets). A scheduled task removes them on day 31 — not part of this plan.

**Tech Stack:** bash, git.

**Prerequisites:**
- M3 complete. `docs/m3-cutover-matrix.md` is all DONE or N/A.
- Old root state contains zero `module.monitor_*` entries (verified at the end of M3 Task 5).
- `backups/post-m3-empty-root.tfstate` exists and is committed.

---

## Inputs to fill before executing

| Token | Meaning | Example |
|---|---|---|
| `<OLD_ROOT_AWS_PROFILE>` | AWS CLI profile the old root used | `default` |

No other tokens — M4 doesn't interact with AWS beyond the verification commands.

---

## File Structure

Deleted in M4:
- `./main.tf`
- `./variables.tf`
- `./versions.tf`
- `./terraform.tfvars`
- `./terraform.tfvars.example`
- `./.terraform/` (local providers + backend cache)
- `./terraform.tfstate` (local state — if present; otherwise skip)
- `./terraform.tfstate.backup` (if present; otherwise skip)
- `./.terraform.lock.hcl`

Preserved:
- `backups/` (kept 30 days, per spec)
- `docs/m3-cutover-matrix.md` (historical record)
- `docs/superpowers/` (specs + plans)
- `modules/cloudwatch/` (library)
- `stacks/` (all new homes)
- `scripts/` (inventory, migrate, smoke — still useful)
- `README.md`, `CLAUDE.md`, `IMPLEMENTATION_PLAN.md`

---

## Task 1: Re-verify the old root is empty

Last chance to catch a missed cutover before deletion becomes irreversible.

**Files:**
- Read only.

- [ ] **Step 1: List the root-level `.tf` files**

Run: `ls -1 *.tf *.tfvars 2>/dev/null`

Expected: `main.tf`, `variables.tf`, `versions.tf`, `terraform.tfvars`, `terraform.tfvars.example`. No other `.tf` or `.tfvars` files.

- [ ] **Step 2: Confirm the old root state has zero monitoring resources**

```bash
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state list | grep -E '^module\.monitor_[a-z]+\[' | wc -l
```

Expected: `0`. Non-zero → **STOP** and return to M3 to migrate the remaining resources.

- [ ] **Step 3: Confirm `terraform plan` is clean**

```bash
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform plan -detailed-exitcode
```

Expected: exit `0`.

If exit `2`, the plan proposes changes. Read the diff carefully:
- **Creates:** some `*_resources` in `./terraform.tfvars` still have entries. Return to M3 to strip them.
- **Destroys:** an alarm exists in state that shouldn't. This is unusual after M3 Task 5; investigate before deletion.

- [ ] **Step 4: Confirm `docs/m3-cutover-matrix.md` is all DONE or N/A**

Run: `grep -cE '^\| [a-z]' docs/m3-cutover-matrix.md`

Expected: same count as `grep -cE 'DONE|N/A' docs/m3-cutover-matrix.md`. In other words, every service row is fully accounted for.

- [ ] **Step 5: Pull a final empty-state snapshot**

Even though M3 Task 5 already did this, pull one more time — the interval between then and now might have had operator pushes.

```bash
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state pull > backups/pre-m4-final-empty-root.tfstate
jq '.resources | length' backups/pre-m4-final-empty-root.tfstate
```

Expected output: `0`.

If non-zero: **STOP**, re-run Task 1.

- [ ] **Step 6: Commit the snapshot**

```bash
git add backups/pre-m4-final-empty-root.tfstate
git commit -m "backup: Final empty-state snapshot before M4 decommission."
```

---

## Task 2: Delete the local Terraform working directory

`./.terraform/`, `./.terraform.lock.hcl`, and any local state files are worthless once the root `.tf` files are gone. Clear them before the file deletions so nobody accidentally runs `terraform` in the repo root afterward.

**Files:**
- Delete: `./.terraform/`
- Delete: `./.terraform.lock.hcl`
- Delete: `./terraform.tfstate` (if present)
- Delete: `./terraform.tfstate.backup` (if present)

- [ ] **Step 1: Remove the provider cache and lock file**

```bash
rm -rf ./.terraform/
rm -f ./.terraform.lock.hcl
```

These are untracked (per the top-level `.gitignore`); deletion is local-only.

- [ ] **Step 2: Check whether local state files exist**

```bash
ls -l ./terraform.tfstate ./terraform.tfstate.backup 2>/dev/null || echo "no local state files"
```

If the output is `no local state files`, skip Step 3.

- [ ] **Step 3: Remove local state files (if any)**

```bash
rm -f ./terraform.tfstate ./terraform.tfstate.backup
```

You already have two snapshots in `backups/` from Task 1 Step 5 and M3 Task 5; no data is lost.

No commit for this task — these files are all gitignored.

---

## Task 3: Delete the root `.tf` files and `terraform.tfvars`

The point of no return. Everything validated in Task 1 must hold.

**Files:**
- Delete: `./main.tf`
- Delete: `./variables.tf`
- Delete: `./versions.tf`
- Delete: `./terraform.tfvars`
- Delete: `./terraform.tfvars.example`

- [ ] **Step 1: Delete each file**

Run from the repo root:

```bash
git rm main.tf variables.tf versions.tf terraform.tfvars terraform.tfvars.example
```

`git rm` both removes from the working tree and stages the deletion.

- [ ] **Step 2: Verify the repo root no longer has Terraform roots**

Run: `ls *.tf *.tfvars 2>/dev/null || echo "root is Terraform-free"`

Expected: `root is Terraform-free`.

- [ ] **Step 3: Confirm the stacks/ tree is intact**

```bash
find stacks -maxdepth 3 -name versions.tf | wc -l
```

Expected: at least `2 + N_accounts + N_services × N_accounts`. Exact shape depends on your matrix; the point is that `stacks/` survived unaffected.

- [ ] **Step 4: Commit the deletion**

```bash
git commit -m "feat: Decommission old monolithic root (M4).

Deletes main.tf, variables.tf, versions.tf, terraform.tfvars, and
terraform.tfvars.example. Every resource previously managed by the
root is now owned by a per-(service, account) stack under stacks/.

State snapshots retained in backups/ for 30 days per spec safety nets."
```

---

## Task 4: Update repo docs and helper scripts

Docs and scripts that reference the old root need updating now that it's gone.

**Files:**
- Modify: `./README.md`
- Modify: `./CLAUDE.md`
- Read: `./scripts/` (audit for root-path references)

- [ ] **Step 1: Update `README.md`**

Open `README.md`. Replace any section that says "run `terraform init && terraform plan && terraform apply` at the repo root" with a pointer to the per-stack workflow. The specific wording depends on what's already there — the guiding edits:

- Add a "Repo layout" section (or update the existing one) that describes `modules/cloudwatch/`, `stacks/foundation/ops/`, `stacks/platform/<alias>/`, `stacks/services/<service>/<alias>/`.
- Replace any "Getting Started" flow that assumes root `.tf` files.
- Add a "Deployment workflow" section that walks through: `cd stacks/services/<service>/<alias>/ && terraform init -backend-config=backend.hcl && terraform apply`.
- Link to `scripts/migrate/scaffold-leaf.sh` as the way to add a new leaf.

- [ ] **Step 2: Update `CLAUDE.md`**

Open `CLAUDE.md`. Two edits:

1. In the "Commands" section, note that `terraform <command>` must be run inside a specific stack dir — running at repo root is no longer valid.
2. In the "Architecture" section, replace the "Data Flow" paragraph:

Before:
```
`variables.tf` (root) defines typed resource lists → `main.tf` instantiates per-module `for_each` loops keyed by project → each `modules/monitor-<type>/` creates alarms for every resource in the list.
```

After:
```
Each `stacks/services/<service>/<alias>/terraform.tfvars` declares typed resource lists (no project field — the stack injects `project = var.service`). `stacks/services/<service>/<alias>/main.tf` instantiates library modules from `modules/cloudwatch/metrics-alarm/<type>/`, one call per resource type that service uses. State lives in `s3://<ORG>-tfstate/account-<alias>/services/<service>/alarms.tfstate`.
```

- [ ] **Step 3: Audit `scripts/` for dead root references**

Run:

```bash
grep -rn 'terraform.tfvars\|terraform.tfstate\|^module "monitor_' scripts/ 2>/dev/null || echo "no dead root references"
```

Expected: either `no dead root references`, or a list of occurrences where scripts assumed repo-root Terraform. For each hit:

- If the script is still used post-M3 (`inventory.sh`, `smoke/*`), update it to iterate over `stacks/services/*/*/terraform.tfvars` instead.
- If it was only useful against the old root (e.g., `check_ec2_mem_metric.sh` called from a `null_resource`), leave it alone — M6 will move it into CI and delete the `null_resource` provisioners.

- [ ] **Step 4: Commit doc + script updates**

```bash
git add README.md CLAUDE.md scripts/
git commit -m "docs: Post-M4 repo-layout and command-path updates.

README and CLAUDE.md point at the per-stack workflow; references to
the old root terraform.tfvars/tfstate are removed. Helper scripts
iterating over the inventory are updated to scan stacks/services/
instead of the repo root."
```

---

## Task 5: Archive `docs/m3-cutover-matrix.md`

The matrix has served its purpose. Move it under `docs/archive/` so it doesn't confuse future contributors who think it's current work.

**Files:**
- Move: `docs/m3-cutover-matrix.md` → `docs/archive/m3-cutover-matrix.md`

- [ ] **Step 1: Create the archive directory**

```bash
mkdir -p docs/archive
```

- [ ] **Step 2: Move the matrix**

```bash
git mv docs/m3-cutover-matrix.md docs/archive/m3-cutover-matrix.md
```

- [ ] **Step 3: Add an archive header note**

Open `docs/archive/m3-cutover-matrix.md` and insert at the top:

```markdown
> **ARCHIVED — completed 20YY-MM-DD.** This matrix tracked the one-time migration from the monolithic root to per-service stacks. Every cell is DONE or N/A. Retained for historical reference only.

```

Replace `20YY-MM-DD` with today's UTC date.

- [ ] **Step 4: Commit**

```bash
git add docs/archive/
git commit -m "docs: Archive M3 cutover matrix after M4 decommission.

Migration is complete; matrix is preserved under docs/archive/ as a
historical record. Not linked from README."
```

---

## Task 6: Final sanity checks

- [ ] **Step 1: `git status` is clean**

Run: `git status`

Expected: `nothing to commit, working tree clean`.

- [ ] **Step 2: No Terraform files at repo root**

```bash
find . -maxdepth 1 -type f \( -name '*.tf' -o -name '*.tfvars' \) 2>/dev/null
```

Expected: no output.

- [ ] **Step 3: Every stack plans cleanly from scratch**

Pick one representative leaf to smoke-test:

```bash
cd stacks/services/<ONE_SERVICE>/<ONE_ALIAS>
rm -rf .terraform/ .terraform.lock.hcl
terraform init -backend-config=backend.hcl
terraform plan -detailed-exitcode
```

Expected: init succeeds; plan exits `0`.

Repeat for `stacks/platform/<ONE_ALIAS>/` and `stacks/foundation/ops/` if you want belt-and-suspenders coverage. Not required — M0 already proved these work.

- [ ] **Step 4: No ghost references remain**

```bash
grep -rn 'monitor_ec2\|monitor_alb\|monitor_rds' --include='*.tf' --include='*.md' --include='*.sh' \
  | grep -v docs/archive/ \
  | grep -v docs/superpowers/ \
  | head -20 || echo "no ghost references"
```

Expected: `no ghost references`, or a small number of matches you can explain (e.g., spec/plan docs under `docs/superpowers/` still describe the old layout for history — that's fine).

---

## Verification summary

1. Repo root has no `.tf` or `.tfvars` files.
2. `git status` is clean.
3. One representative `stacks/services/*/*/` leaf produces `terraform plan -detailed-exitcode` == 0 from a fresh `terraform init`.
4. `docs/m3-cutover-matrix.md` has moved to `docs/archive/`.
5. `backups/pre-m4-final-empty-root.tfstate` exists and is committed.
6. No ghost references to `module "monitor_<type>"` outside of spec/plan/archive directories.

---

## Rollback

Before Task 3 Step 4: `git restore --staged . && git restore .` brings the root files back. Nothing has been destroyed in AWS; the old root was already empty before M4 began.

After Task 3 Step 4 (deletion committed): `git revert <M4-deletion-sha>` restores the files. The old root's state is the snapshot `backups/pre-m4-final-empty-root.tfstate` — push it back with `terraform state push` if anyone needs the old root operational again. But note: the services have moved on (their alarms are owned by per-service stacks now), so reviving the old root just gives you an empty `terraform apply` that creates nothing.

In practice, nobody rolls back M4. It's the simplest milestone.

---

## Known limitations / edge cases

1. **Root `terraform.tfstate.d/` workspaces.** If the old root used `terraform workspace` to manage multiple envs, each workspace has its own state under `terraform.tfstate.d/<workspace>/`. Snapshot each one in Task 1 Step 5 (repeat per workspace, varying `terraform workspace select`) and delete them in Task 2 Step 3.
2. **`scripts/` that shell out to `terraform` with no args.** Anything calling `terraform -chdir=. …` or running inside the repo root will silently fail after Task 3. The Task 4 Step 3 audit catches these — fix them there.
3. **CI pipelines.** If CI has jobs that run `terraform validate` or `terraform plan` in the repo root, they break on the commit from Task 3. Either disable those jobs or repoint them to iterate over `stacks/services/*/*`. Not in scope for this plan — flag it before starting M4.
4. **`IMPLEMENTATION_PLAN.md`** and **`STRUCTURE.md`** may reference the old layout in prose. Leave them alone unless a reader gets confused; their value is historical context.
5. **30-day retention cleanup.** `backups/pre-*.tfstate` files should be deleted after 30 days. Set a calendar reminder; the deletion is one line (`find backups -name 'pre-*.tfstate' -mtime +30 -delete`) and can be committed whenever convenient. Not part of M4.
