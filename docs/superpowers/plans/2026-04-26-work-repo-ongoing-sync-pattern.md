# Work-Repo Ongoing Sync Pattern — Implementation Plan

> **For agentic workers:** This is a **reusable procedure**, not a one-time plan. Use it whenever upstream (origin) gains commits that you want reflected in the unrelated-history `<work>` repo. Steps use checkbox (`- [ ]`) syntax — copy the procedure into a fresh checklist for each sync.
>
> **Note:** This is designed for **manual execution on the work machine without AI assistance.**

**Goal:** Port new commits from `origin` (public, generic) into `<work>` (private, deployment) without shared git history, while keeping `<work>`-only artifacts (real `terraform.tfvars`, real-named service stacks, AWS state) untouched.

**Architecture:** `synced` (clean clone of origin on the work machine) is the **bridge**. Pull updates into `synced` from origin via normal `git pull`. Then mechanically port the relevant subset of those changes into `<work>` via `git format-patch` (clean cases) or manual diff+copy (conflicting cases). A `SYNC.md` file in `<work>` records the last-synced commit SHA so the next sync knows where to start.

**Tech Stack:** git, bash, `diff`, `terraform`.

**Placeholders:**

| Placeholder | Meaning |
|---|---|
| `<synced>` | Path to the synced clone of origin |
| `<work>` | Path to the deployment repo |
| `<last-sha>` | The origin commit SHA recorded in `<work>/SYNC.md` from the previous sync |
| `<new-sha>` | The current `HEAD` SHA in `<synced>` after `git pull origin` |

---

## Pre-Conditions

- `<work>` already contains the M0–M6 refactor (i.e., `2026-04-26-work-repo-refactor-transfer.md` has been completed at least once).
- `<work>/SYNC.md` exists and records the last-synced origin commit. *First-time use:* create it pointing at the SHA that was current in origin when the refactor transfer ran.
- Both `<synced>` and `<work>` are clean (`git status` empty in both).

---

## Sync Scope: What Flows and What Doesn't

This is **the most important section** — the rest of the procedure is mechanical.

### Always sync (synced → work)

| Path | Reason |
|---|---|
| `modules/cloudwatch/**` | Library code — generic |
| `scripts/migrate/**`, `scripts/check_*.sh` | Generic helpers |
| `.github/workflows/**`, `.tflint.hcl` | Generic CI/lint config |
| `docs/**` | Specs, plans, runbooks — all generic |
| `CLAUDE.md`, `README.md`, `STRUCTURE.md`, `IMPLEMENTATION_PLAN.md`, `resource-type-based-metric-alarm.md` | Generic documentation |
| `versions.tf`, `.terraform.lock.hcl` (if present) | Provider/version pins |
| `terraform.tfvars.example` | Generic example |
| `stacks/foundation/ops/{main,outputs,variables,versions,providers}.tf`, `stacks/foundation/ops/.gitignore` | Generic foundation scaffold |
| `stacks/platform/<alias>/{main,outputs,variables,data,versions,providers}.tf`, `stacks/platform/<alias>/.gitignore` | Generic platform scaffold |
| `stacks/services/billing/dev/{main,outputs,variables,data,versions,providers}.tf`, `stacks/services/billing/dev/.gitignore` | Template service stack — used by `scaffold-leaf.sh` |

### Never sync (work-only)

| Path | Reason |
|---|---|
| `terraform.tfvars` (anywhere — root, `stacks/**`) | Real values; differ from public `*.example` |
| `terraform.tfstate*`, `.terraform/`, `*.tfstate.backup` | Local state |
| `backend.hcl` (if it carries real bucket/region) | Work-specific |
| `stacks/services/<real-service-name>/<alias>/` (anything *not* matching the upstream `billing/dev` template) | Created by `scaffold-leaf.sh` during M3 — work-specific names |
| `SYNC.md` itself | Sync metadata; lives only in `<work>` |

### Sync with care (conflict-prone)

These paths *do* sync, but often have work-local edits on top. Expect to reconcile manually:

- `main.tf`, `variables.tf` at repo root (work may carry local module instantiation customizations until M4 deletes the old root entirely)
- Any module file under `modules/cloudwatch/metrics-alarm/<type>/` that work has touched locally

---

## Procedure (per sync)

### Task 1: Pull upstream into synced

- [ ] **Step 1: Fetch and fast-forward synced**

```bash
cd "$SYNCED"
git fetch origin
git pull --ff-only origin <branch>   # the branch you track (e.g. main, refactor/m1-m6)
git log --oneline -1
```

Expected: fast-forward succeeds; record the new HEAD SHA as `<new-sha>`. If non-fast-forward: origin's branch was force-pushed — investigate before continuing.

- [ ] **Step 2: Read the last-synced SHA from work**

```bash
cd "$WORK"
cat SYNC.md
```

Expected: a line like `last-synced-from-origin: <last-sha>  (date: 2026-XX-XX)`. Copy `<last-sha>`.

### Task 2: Identify what changed in syncable scope

- [ ] **Step 1: List commits introduced since last sync**

```bash
cd "$SYNCED"
git log --oneline <last-sha>..<new-sha>
```

Expected: a list of new commits. If empty, there's nothing to sync — exit.

- [ ] **Step 2: List touched files, filtered to syncable paths**

```bash
cd "$SYNCED"
git diff --name-status <last-sha>..<new-sha> -- \
  modules/ scripts/ .github/ .tflint.hcl docs/ CLAUDE.md README.md \
  STRUCTURE.md IMPLEMENTATION_PLAN.md resource-type-based-metric-alarm.md \
  versions.tf .terraform.lock.hcl terraform.tfvars.example \
  'stacks/foundation/**' 'stacks/platform/**' 'stacks/services/billing/dev/**'
```

Expected: a list of `M` (modified), `A` (added), `D` (deleted), `R` (renamed) entries. **If the list is empty: all upstream changes were in non-syncable scope (probably real-name service stacks somehow leaked, or just `SYNC.md`-style metadata). Skip to Task 5 to update the marker.**

### Task 3: Generate and attempt to apply a patch series

- [ ] **Step 1: Generate patches from synced, scoped to syncable paths**

```bash
cd "$SYNCED"
mkdir -p /tmp/sync-patches
git format-patch <last-sha>..<new-sha> -o /tmp/sync-patches -- \
  modules/ scripts/ .github/ .tflint.hcl docs/ CLAUDE.md README.md \
  STRUCTURE.md IMPLEMENTATION_PLAN.md resource-type-based-metric-alarm.md \
  versions.tf .terraform.lock.hcl terraform.tfvars.example \
  'stacks/foundation/**' 'stacks/platform/**' 'stacks/services/billing/dev/**'
ls /tmp/sync-patches/
```

Expected: one `.patch` file per new commit that touched a syncable path.

- [ ] **Step 2: Dry-run the patch series against work**

```bash
cd "$WORK"
git checkout -b sync/$(date +%Y%m%d)-from-<new-sha-short>
for p in /tmp/sync-patches/*.patch; do
  echo "--- check: $p ---"
  git apply --check "$p" 2>&1
done
```

Expected: each patch reports either nothing (clean) or a specific error. Common errors:
- `error: patch failed: <file>:N` → conflict; manual reconcile needed (Task 4).
- `error: <file>: No such file or directory` → file is new in synced and unconditionally addable; the dry-run may complain but `git apply` will succeed.

- [ ] **Step 3: Apply the clean patches**

```bash
cd "$WORK"
for p in /tmp/sync-patches/*.patch; do
  if git apply --check "$p" 2>/dev/null; then
    echo "--- apply: $p ---"
    git apply "$p"
    git add -A
    SUBJECT=$(grep '^Subject:' "$p" | head -1 | sed 's/^Subject: \[PATCH[^]]*\] //')
    git commit -m "sync: $SUBJECT"
    mv "$p" /tmp/sync-patches/applied-$(basename "$p")
  fi
done
```

Expected: each clean patch becomes one commit on the sync branch. Patches that didn't pass `--check` remain in `/tmp/sync-patches/` for manual handling in Task 4.

### Task 4: Manually reconcile conflicting patches

For each remaining patch in `/tmp/sync-patches/`:

- [ ] **Step 1: Open the patch and the target file(s) side-by-side**

```bash
$EDITOR /tmp/sync-patches/<patch-file>
# For each file the patch touches:
$EDITOR "$WORK/<conflicting-file>"
```

- [ ] **Step 2: Apply the patch's intent by hand**

For each hunk:
- Locate the surrounding context in `<work>`'s version of the file (search for anchor strings, not line numbers).
- Apply the hunk's `+` and `-` lines, adjusting for any difference between work's local edits and the patch's expected "before" state.
- If the hunk would undo a work-local edit on purpose (e.g., a hotfix you applied locally that's now obsolete because upstream fixed it differently), favor the upstream version unless the local edit was correct and upstream is wrong.

- [ ] **Step 3: Verify the file still parses**

```bash
cd "$WORK"
terraform fmt <conflicting-file>
```

Expected: no errors. Re-format may rewrite whitespace; that's fine.

- [ ] **Step 4: Commit the reconciliation**

```bash
cd "$WORK"
git add <conflicting-file>
SUBJECT=$(grep '^Subject:' /tmp/sync-patches/<patch-file> | head -1 | sed 's/^Subject: \[PATCH[^]]*\] //')
git commit -m "sync: $SUBJECT (reconciled)"
mv /tmp/sync-patches/<patch-file> /tmp/sync-patches/applied-<patch-file>
```

### Task 5: Verify and update the sync marker

- [ ] **Step 1: Validate the result**

```bash
cd "$WORK"
terraform fmt -recursive -check
terraform init -backend=false
terraform validate
```

Expected: all clean. If anything fails: identify which sync commit caused it, revert just that commit (`git revert <sha>`), and investigate before re-attempting.

- [ ] **Step 2: Update `SYNC.md`**

```bash
cd "$WORK"
cat > SYNC.md <<EOF
last-synced-from-origin: <new-sha>
date: $(date +%Y-%m-%d)
synced-by: <your-username-or-machine>
EOF
git add SYNC.md
git commit -m "chore: bump SYNC.md to <new-sha-short>"
```

- [ ] **Step 3: Merge sync branch into your usual deploy branch**

```bash
cd "$WORK"
git checkout <deploy-branch>
git merge --ff-only sync/$(date +%Y%m%d)-from-<new-sha-short>
git branch -d sync/$(date +%Y%m%d)-from-<new-sha-short>
```

Expected: fast-forward merge; sync branch deleted.

- [ ] **Step 4: Clean up patches**

```bash
rm -rf /tmp/sync-patches
```

---

## Edge Cases

### Upstream rebased a branch you track

If `git pull --ff-only` in Task 1 fails because origin's branch was force-pushed: the `<last-sha>` in `SYNC.md` may no longer exist in the new history. Two options:

1. Find a new equivalent commit in the rewritten history (likely the new tip's nearest equivalent — `git log --grep` against subject lines), record that as the new starting point, and re-run the procedure from there.
2. Treat it as a fresh transfer: snapshot `<work>`, follow `2026-04-26-work-repo-refactor-transfer.md` again with the new origin state as the source.

### Upstream deleted a file you locally edited

A `D` (delete) entry in Task 2 Step 2's diff means upstream removed a file. If you have local edits to that file:
- Decide whether the local edits are still relevant. If yes: keep the file in `<work>`, skip the deletion patch.
- If the local edits are obsolete (e.g., the file moved and your edits should follow): apply the delete and port the edits to the new location manually.

### Upstream renamed a file you locally edited

`git format-patch` may emit a rename as a delete + add. Apply manually as a `git mv` in `<work>`, then re-apply your local edits to the new path.

### A patch touches both syncable and non-syncable scope

If an upstream commit touches `modules/cloudwatch/...` *and* `stacks/services/billing/dev/terraform.tfvars` (the example tfvars), the format-patch filter in Task 3 Step 1 only includes the syncable paths. The patch may have hunks that don't apply because the surrounding context refers to the non-syncable file. Edit the patch by hand to drop the non-syncable hunks, then `git apply`.

---

## First-Time Use: Initialize `SYNC.md`

If `<work>` doesn't have `SYNC.md` yet (you're running this procedure for the first time after the refactor transfer), seed it:

- [ ] **Step 1: Find the synced commit that matched what you transferred**

```bash
cd "$SYNCED"
git log --oneline -1
```

Record this SHA as the initial `<last-sha>`.

- [ ] **Step 2: Create `SYNC.md` in work**

```bash
cd "$WORK"
cat > SYNC.md <<EOF
last-synced-from-origin: <sha-from-step-1>
date: $(date +%Y-%m-%d)
synced-by: <your-username-or-machine>
EOF
git add SYNC.md
git commit -m "chore: initialize SYNC.md after refactor transfer"
```

From the next sync onward, the procedure above applies as-written.
