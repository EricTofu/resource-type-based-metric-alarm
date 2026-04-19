# M3: Remaining Service Cutovers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the M2 cutover pattern to every remaining `(service, account-alias)` pair until the old monolithic root owns zero alarms. After M3 completes, the old root is empty and ready for M4 to delete it.

**Architecture:**
- M3 is M2 repeated N−1 times (where N = `N_services × N_accounts`). No new Terraform constructs — just orchestration, file duplication, and verification at scale.
- **Parallelism rule (from spec §Apply ordering):** parallel across `(service, account)` pairs; **serial `dev → stg → prod`** within a single service.
- **Leaf duplication strategy:** since no Terragrunt, each leaf is self-contained. `versions.tf`, `providers.tf`, `main.tf`, `variables.tf`, `outputs.tf`, and `.gitignore` are bit-identical across every `stacks/services/<service>/<alias>/`. Only `backend.hcl` and `terraform.tfvars` differ per leaf. A small scaffolder script copies the invariant files and substitutes the variants.
- **Resumability.** M3 spans days; the cutover matrix + progress log (Task 1) is the authoritative state across sessions.

**Tech Stack:** Terraform ≥ 1.10, AWS provider ≥ 5.0, bash, jq, aws CLI.

**Prerequisites:**
- M2 complete and the pilot has been stable ≥ 24h.
- `scripts/migrate/generate-split.sh` from M2 works.
- Every target account has an applied `stacks/platform/<alias>/` stack (from M0b) — no cutover can target an account whose platform SNS topics don't yet exist.
- All resources in the old root's tfvars are covered by one `(service, account)` pair in the planned M3 matrix. Anything unmapped must be resolved before starting (add to matrix or explicitly retire).

---

## Inputs to fill before executing

Same tokens as M2, plus:

| Token | Meaning | Example |
|---|---|---|
| `<ORG>` | State bucket prefix | `acme` |
| `<PRIMARY_REGION>` | Default provider region | `ap-northeast-1` |
| `<OPS_STATE_ROLE_ARN>` | Ops state-access role ARN | `arn:aws:iam::999999999999:role/tf-state-access` |
| `<OLD_ROOT_AWS_PROFILE>` | Profile used by the old root | `default` |
| `<SERVICE_LIST>` | Every service except the M2 pilot | `checkout inventory notification` |
| `<ACCOUNT_ALIASES>` | Aliases in deploy order | `dev stg prod` |

---

## Task 1: Build the cutover matrix and progress log

Inventory what's left, in what order, and track progress as rows get completed.

**Files:**
- Create: `docs/m3-cutover-matrix.md`

- [ ] **Step 1: Enumerate the matrix**

From the repo root, with `<OLD_ROOT_AWS_PROFILE>` active:

```bash
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state list \
  | grep -E '^module\.monitor_[a-z]+\["[^"]+"\]\.aws_cloudwatch_metric_alarm\.' \
  | awk -F'"' '{print $2}' \
  | sort -u
```

Expected: one line per `project` value still in the old root's state. This is the list of **services** that still need cutover. If the M2 pilot is still listed, M2 didn't finish — do not start M3.

- [ ] **Step 2: Compose the cutover matrix document**

Create `docs/m3-cutover-matrix.md`. Use actual service names from Step 1 and your own account aliases:

```markdown
# M3 Cutover Matrix

**Pilot (M2, already done):** `billing × account-dev`

**Target:** every (service, account) pair that currently has alarms in the old root.

| Service    | dev  | stg  | prod | prod-apac |
|------------|------|------|------|-----------|
| billing    | DONE | ☐    | ☐    | N/A       |
| checkout   | ☐    | ☐    | ☐    | ☐         |
| inventory  | ☐    | ☐    | ☐    | N/A       |
| notification | ☐  | ☐    | ☐    | N/A       |

Legend: ☐ pending · IN PROGRESS · DONE · N/A (service not deployed in that account)

**Parallelism rules:**
- Across rows (different services): parallel safe. Multiple engineers can cut over `checkout-dev` and `inventory-dev` simultaneously.
- Within a row (same service): SERIAL dev → stg → prod. Each column must be stable ≥ 1h before starting the next.

**Per-row stability:** after flipping a cell to DONE, run `terraform plan -detailed-exitcode` in that leaf and in the old root. Both must exit 0.
```

Edit the services and aliases to match your environment.

- [ ] **Step 3: Commit the matrix**

```bash
git add docs/m3-cutover-matrix.md
git commit -m "docs(m3): Add cutover matrix and progress log.

Tracks remaining (service, account) cutovers after M2 pilot.
Each row flips DONE as its leaf is applied and verified."
```

---

## Task 2: Write the leaf-scaffolder script

Single script stamps out the invariant files for a new `(service, alias)` leaf, based on the one M2 produced. Saves ~20 minutes per leaf and guarantees the shape stays identical.

**Files:**
- Create: `scripts/migrate/scaffold-leaf.sh`

- [ ] **Step 1: Create the script**

Create `scripts/migrate/scaffold-leaf.sh`:

```bash
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

: "${ORG:?ORG environment variable required, e.g. export ORG=acme}"
: "${PRIMARY_REGION:?PRIMARY_REGION required, e.g. export PRIMARY_REGION=ap-northeast-1}"
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
primary_region = "${PRIMARY_REGION}"
ops_bucket     = "${ORG}-tfstate"
ops_state_role_arn = "${OPS_STATE_ROLE_ARN}"

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
EOF

echo "Scaffolded $DST"
echo "Next: fill $DST/terraform.tfvars with the old root's entries for project=\"${SERVICE}\""
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/migrate/scaffold-leaf.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/migrate/scaffold-leaf.sh
git commit -m "feat(migrate): Add leaf-scaffolder script for M3 cutovers.

Copies the invariant files (versions, providers, variables, main,
outputs, .gitignore) from the M2 pilot leaf and generates a per-leaf
backend.hcl plus a skeleton tfvars. Operator fills the *_resources
lists before running the generate-split + apply cycle."
```

---

## Task 3: Per-pair runbook (repeat for every matrix cell)

This is the unit of work you repeat for every non-DONE cell. Each iteration is ~1 hour of operator time. Do not skip verification steps.

**Variables in scope:** `<SERVICE>`, `<ALIAS>` (both WITHOUT the `account-` prefix), plus all M2 tokens from the Inputs section.

**Parallelism:** run multiple iterations concurrently only if they target **different services** or the **same service but non-adjacent tiers** (e.g., `checkout-dev` and `inventory-prod` are safe together; `billing-dev` and `billing-stg` are not).

- [ ] **Step 1: Scaffold the leaf**

From the repo root:

```bash
export ORG=<ORG>
export PRIMARY_REGION=<PRIMARY_REGION>
export OPS_STATE_ROLE_ARN=<OPS_STATE_ROLE_ARN>
export PILOT_SERVICE=<PILOT_SERVICE_FROM_M2>
export PILOT_ALIAS=<PILOT_ALIAS_FROM_M2>

scripts/migrate/scaffold-leaf.sh <SERVICE> <ALIAS>
```

Expected: new dir at `stacks/services/<SERVICE>/<ALIAS>/` with every file from the pilot plus a fresh `backend.hcl` and a skeleton `terraform.tfvars`.

- [ ] **Step 2: Fill the tfvars from the old root**

Open `stacks/services/<SERVICE>/<ALIAS>/terraform.tfvars`. For each `*_resources` list, copy the resources that live under `{ project = "<SERVICE>", resources = [...] }` in the root `./terraform.tfvars`. Drop the outer `project`/`resources` wrap — each entry is now bare (`{ name = "…" }`, `{ name = "…", overrides = { … } }`, etc.).

**Scope caveat:** if a service's resources in the old root are not yet split by account (e.g., all `checkout` EC2s are in one list regardless of which account they live in), you need to split them here. Filter by actual account membership (name prefix, tag, or direct knowledge). **Do NOT cut over resources that belong in a different account** — they'll fail provider calls and you'll have to revert.

- [ ] **Step 3: Inventory cross-check**

From the repo root:

```bash
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state list \
  | grep 'module.monitor_.*\["<SERVICE>"\].aws_cloudwatch_metric_alarm' \
  | wc -l
```

Expected: some positive count `<N>`. Record it.

Then count the leaf tfvars entries:

```bash
grep -oE 'name += +"[^"]+"|distribution_id += +"[^"]+"' \
  stacks/services/<SERVICE>/<ALIAS>/terraform.tfvars | wc -l
```

The leaf count × (avg alarms per resource) should roughly match `<N>`. Exact match isn't required because multiple alarms share one resource. A leaf count of **zero** means you filled nothing; a leaf count larger than the state count means you double-listed.

- [ ] **Step 4: Snapshot the old root state**

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state pull > backups/pre-<SERVICE>-<ALIAS>-${TS}.tfstate
```

- [ ] **Step 5: Generate import.tf + removed.tf**

```bash
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> \
  scripts/migrate/generate-split.sh <SERVICE> stacks/services/<SERVICE>/<ALIAS>
```

- [ ] **Step 6: Init + apply the new leaf**

```bash
cd stacks/services/<SERVICE>/<ALIAS>
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan.bin
# Review: expect "Plan: 0 to add, 0 to change, 0 to destroy. <N> to import."
terraform apply tfplan.bin
terraform plan -detailed-exitcode   # expect exit 0
```

If Step 6 shows a non-zero add/change/destroy, STOP. Either the tfvars miss/duplicate an entry, or a resource in the target account has drifted relative to the old root's state. Fix the tfvars or reconcile drift in the old root first.

- [ ] **Step 7: Apply the removed blocks in the old root**

```bash
cd <REPO_ROOT>
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform plan -out=tfplan-removed.bin
# Review: expect "Plan: 0 to add, 0 to change, 0 to destroy. <M> to forget."
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform apply tfplan-removed.bin
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform plan -detailed-exitcode  # expect exit 0
```

- [ ] **Step 8: Zero-flicker audit**

```bash
aws cloudwatch describe-alarms --alarm-name-prefix "<SERVICE>-" \
  --query 'MetricAlarms[].[AlarmName, AlarmConfigurationUpdatedTimestamp]' \
  --output json > backups/post-<SERVICE>-<ALIAS>-audit.json

# Confirm NO timestamp falls inside the window between Step 6 start and Step 7 end.
jq -r '.[] | .[1]' backups/post-<SERVICE>-<ALIAS>-audit.json | sort | tail -5
```

Expected: all timestamps predate Step 6.

- [ ] **Step 9: Remove pilot entries from root tfvars**

Edit `./terraform.tfvars` and delete every `{ project = "<SERVICE>", resources = [...] }` block inside every `*_resources` list. Commit this as part of Step 11.

- [ ] **Step 10: Clean up transient files**

```bash
rm stacks/services/<SERVICE>/<ALIAS>/import.tf
rm ./removed.tf
```

- [ ] **Step 11: Commit the cutover atomically**

```bash
git add stacks/services/<SERVICE>/<ALIAS>/ \
        backups/pre-<SERVICE>-<ALIAS>-*.tfstate \
        backups/post-<SERVICE>-<ALIAS>-audit.json \
        ./terraform.tfvars
git commit -m "feat(services): Cut over <SERVICE> x <ALIAS>.

Moves all <SERVICE> alarms out of the old root into
stacks/services/<SERVICE>/<ALIAS>/ via import + removed blocks
(Terraform 1.7+). Zero-flicker: no AlarmConfigurationUpdatedTimestamp
falls inside the cutover window. Old root's tfvars strip the
corresponding entries."
```

- [ ] **Step 12: Update the matrix**

Edit `docs/m3-cutover-matrix.md` and flip `<SERVICE> × <ALIAS>` from `☐` to `DONE`.

Commit separately so each row flip is its own commit (readable log):

```bash
git add docs/m3-cutover-matrix.md
git commit -m "docs(m3): <SERVICE> x <ALIAS> cutover complete."
```

- [ ] **Step 13: Wait ≥ 1h before the next tier of this same service**

No action — just elapsed time. During this window, watch for unexpected alarm transitions.

---

## Task 4: Orchestration — walk the matrix to completion

Task 3 is per-pair; Task 4 is about running Task 3 the right number of times in the right order.

- [ ] **Step 1: Pick the next eligible pair**

Rules:
- Any cell in a different service from pairs currently IN PROGRESS is eligible.
- Within the same service, only the leftmost pending column is eligible. E.g., for `checkout`, if `dev` is pending and `stg` is pending, you may only start `dev`.
- A cell may be marked N/A if that service isn't deployed in that account — no cutover needed.

- [ ] **Step 2: Run Task 3 for that pair**

Follow every step. Commit atomically per Task 3 Step 11 and 12.

- [ ] **Step 3: Watch for matrix-wide invariants**

After every row flip, verify:

```bash
# No DONE row has any resource still in the old root.
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state list \
  | grep 'module.monitor_.*\["<DONE_SERVICE>"\]' | wc -l
```

Expected: `0` for every `<DONE_SERVICE>`.

- [ ] **Step 4: Repeat until the matrix is all DONE or N/A**

No shortcut — each pair is its own atomic cutover.

---

## Task 5: Post-M3 sanity — confirm the old root is empty

This proves the invariant M4 relies on.

- [ ] **Step 1: Enumerate anything still in the old root state**

```bash
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state list \
  | grep -E '^module\.monitor_[a-z]+\[' | wc -l
```

Expected: `0`. Any non-zero means a cutover was missed — find the matching pair in the matrix, add it, run Task 3.

- [ ] **Step 2: Plan-based verification**

```bash
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform plan -detailed-exitcode
```

Expected: exit `0`.

If exit `2`, the old root still has some Terraform resources defined whose state was removed (because you deleted their tfvars entries but not the module source they resolve to). That's expected and harmless — M4 will delete the `main.tf` source definitions entirely.

Wait — if exit is `2` for that reason, the plan actually wants to **create** resources (empty `*_resources` lists produce no alarms, but stale projects in tfvars would). If you've removed all project entries from `./terraform.tfvars` in each Task 3 Step 9, the plan should show zero changes, because each module's `for_each` becomes an empty map.

If the plan proposes creates: some service's entries didn't get stripped from root tfvars. Find it via `grep project ./terraform.tfvars` and run another Task 3 iteration.

- [ ] **Step 3: Optional — snapshot the empty root state**

```bash
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state pull > backups/post-m3-empty-root.tfstate
git add backups/post-m3-empty-root.tfstate
git commit -m "backup: Empty old-root state after M3 completion.

All (service, account) cutovers done; old root owns zero alarms.
M4 can now proceed to delete old root sources."
```

---

## Task 6: Update documentation

- [ ] **Step 1: Update `README.md`**

In the deployment section, replace any "run `terraform apply` in the repo root" instructions with "each service has its own stack at `stacks/services/<service>/<alias>/`; run `terraform apply` there." Point at `scripts/migrate/scaffold-leaf.sh` for adding new leaves post-M3.

- [ ] **Step 2: Update `CLAUDE.md`**

Replace the "Adding a New Resource Type" section to reflect that new resource types now live at `modules/cloudwatch/metrics-alarm/<type>/` and get wired into `stacks/services/<service>/<alias>/main.tf` (not the old root).

Also add an "Adding a new service" section:

```markdown
### Adding a new service

1. Choose a target account alias (e.g., `dev`).
2. `scripts/migrate/scaffold-leaf.sh <service> <alias>` (set the env vars documented at the top of the script).
3. Fill `stacks/services/<service>/<alias>/terraform.tfvars` with the service's resources (no `project` field; the stack injects `project = var.service`).
4. `cd stacks/services/<service>/<alias> && terraform init -backend-config=backend.hcl && terraform apply`.
5. Repeat for other aliases (`stg`, `prod`, etc.) once dev is stable.
```

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: Update README and CLAUDE.md for per-service stack model post-M3."
```

---

## Verification summary (all of M3 done)

1. `docs/m3-cutover-matrix.md` shows every cell DONE or N/A.
2. Old root `terraform state list` returns zero `module.monitor_*` entries.
3. Old root `terraform plan -detailed-exitcode` exits `0`.
4. Every new leaf exits `0` on `terraform plan -detailed-exitcode`.
5. Every `backups/post-<service>-<alias>-audit.json` shows no timestamps inside its respective cutover window.
6. Every cutover has its own git commit; rolling back any one cell is `git revert <sha>` plus the rollback recipe from M2.

---

## Rollback

Per-pair rollback uses M2's recipe with substitutions. M3-wide rollback (undoing *all* cutovers) is not offered — the pattern is to revert individual pairs as needed while leaving already-stable pairs alone.

---

## Known limitations / edge cases

1. **A service owns resources across multiple accounts, and the root tfvars doesn't distinguish.** Task 3 Step 2's scope caveat applies: you must partition by account explicitly, usually by resource-name prefix or by direct team knowledge. Get this wrong and `tf-deployer` in the wrong account will fail to look up the resource, surfacing as an `InvalidParameterValue` at plan time.
2. **Services with no dev/stg — prod-only.** No serial ordering needed; cut over the single pair and mark others N/A.
3. **Cross-account shared resources** (e.g., a CloudFront distribution in the Ops account monitored from a service account). These are an open design question — the spec doesn't commit to a pattern. If you hit one during M3: skip that specific alarm from the cutover, leave it in the old root, and note it in the matrix for later resolution.
4. **The pilot rule doesn't require waiting 24h between every matrix cell** — only between dev → stg → prod within the *same* service. Across services, proceed in parallel.
5. **If a service is getting decommissioned anyway:** don't bother migrating it. Mark its row `RETIRE` and delete its root-tfvars entries. Apply in the old root to destroy the orphaned alarms, then proceed.
