# Doc Truth Consolidation — Design

**Date:** 2026-08-02
**Status:** Approved

## Problem

Five Markdown files sit in the repo root, describing three different eras of the
project. Nothing states which is authoritative, so an agent or a human reading
the repo cannot tell what is true.

Measured state before the rewrite:

| Doc | Last touched | State |
| --- | --- | --- |
| `CLAUDE.md` | 2026-07-31 | Accurate, but dense with code-level detail that will desync |
| `README.md` | 2026-07-31 | Stale: claims 11 modules (13 exist), naming convention omits `{Env}` |
| `IMPLEMENTATION_PLAN.md` | 2026-04-19 | Dead: describes the root `main.tf` removed at M4 |
| `STRUCTURE.md` | 2026-04-19 | Dead: a refactor draft; real layout differs |
| `resource-type-based-metric-alarm.md` | 2026-01-15 | Historical: the original feature request |

The root cause is not that the docs were written carelessly. It is that they
record facts the code also records — thresholds, defaults, metric lists, script
flags. Two copies of the same fact diverge; only one of them is executable.

## Goal

One live agent-facing doc and one live human-facing doc, each holding only what
the code cannot state about itself. Everything else archived, not deleted.

Non-goal: changing any Terraform, script, or workflow behaviour. This is a
documentation-only change.

## Design

### 1. Final doc set

Root, both live:

- `README.md` — human entry point. What the project is, the layout, quick
  start, requirements.
- `CLAUDE.md` — agent operating guide. Decisions, contracts, footguns.

`docs/history/`, archived:

- `IMPLEMENTATION_PLAN.md`
- `STRUCTURE.md`
- `resource-type-based-metric-alarm.md`

Each archived file gets a banner as its first line:

> **Superseded — historical record only.** Describes the pre-M4 layout and is
> not authoritative. Current truth: `CLAUDE.md` and the code.

`docs/superpowers/specs/` and `docs/superpowers/plans/` are untouched. They are
already dated and self-evidently point-in-time.

### 2. The self-enforcing rule

CLAUDE.md opens with its own contract, so the next agent to edit it inherits the
constraint rather than re-deriving it:

> This file records decisions, contracts and footguns — what the code cannot
> state about itself. It deliberately holds no threshold values, defaults, or
> query text; those live in the modules and would desync. **A number in this
> file is a bug.**

Immediately followed by a *where truth lives* table:

| Question | Authority |
| --- | --- |
| Which metrics, thresholds, defaults, query text | the module's `main.tf` / `variables.tf` |
| Which resources are monitored | the stack's `terraform.tfvars` / `config.yaml` |
| Why a design is the way it is | this file, then `docs/superpowers/specs/` |
| What it used to look like | `docs/history/`, `git log` |

### 3. Cut rule

**Keep** identifiers that are structural and change rarely: module names, alarm
resource labels (`heap_used`, `fleet_cpu`), input names (`disabled_alarms`,
`app_name`, `heap_max_bytes`). An agent needs these to grep.

**Cut** volatile values: threshold numbers, defaults, evaluation periods,
script flag lists, SQL query text, metric name tables. Replace with a path
pointer to the file that owns them.

Applied per section of CLAUDE.md:

- Kept near-verbatim, because they are hard-won facts or decisions rather than
  code: the `ORDER BY` rule and the "metric math cannot wrap a multi-series
  query" constraint; identity carriers (EC2 resource tag vs CWAgent dimension);
  severity as a routing contract; the `apigateway error_5xx` canary note; the
  ASG two-applies migration footgun; the "Adding a New Resource Type"
  checklist including the silent YAML-leaf miss at step 6.
- Compressed to decisions plus a path pointer: the 13 per-module bullets, the
  Dashboards section, the Module Pattern section.
- Heavily cut: the Preflight section, currently one ~900-word paragraph,
  becomes purpose, the three invariants that stop a silent pass, how to run,
  and the CI trigger. Per-script coverage detail and flag lists move to
  `scripts/`.

One accepted exception: the CRIT classification list in the routing section
names specific alarms. It is retained because the list *is* the decision, with
`docs/superpowers/specs/2026-07-31-alerting-policy-design.md` cited as
authority.

### 4. README changes

- Correct 11 modules to 13; add EFS and JMX to the structure tree.
- Correct the alarm naming convention to include `{Env}`.
- Drop the "Metrics by Resource Type" table. It is the most desync-prone
  artifact in the repo and has already drifted. Replaced by a list of the 13
  types with a one-line purpose each, pointing at the modules for metrics.
- Drop the per-resource overrides table, which duplicates module `variables.tf`.

### 5. Facts added that no doc currently states

Found while verifying, and worth recording once:

- `modules/cloudwatch/synthetics-canary/heartbeat/` exists and is called by no
  stack. It also takes `project` but not `env`, so it does not follow the
  alarm modules' naming convention.
- `.github/workflows/terraform-ci.yml` runs fmt, validate (per stack and per
  library module) and TFLint on PRs touching `modules/**` or `stacks/**`.
  Only `preflight.yml` was documented.
- `scripts/migrate/` holds `generate-split.sh` and `scaffold-leaf.sh`.

### 6. Verification

Every retained factual claim is checked against the code before it is written.
Anything unverifiable is cut rather than guessed. Verified during design:
13 modules on disk; `name_prefix` includes `var.env` in all 13; all 13 wired in
`stacks/projects/billing/dev/main.tf` plus `jmx_dashboard`; the ASG MIGRATION
FOOTGUN comment and both same-named capacity alarms exist; EFS `period` /
`evaluation_periods` are per-resource overrides as described.

After the rewrite, `terraform fmt -recursive -check` and the CI workflows are
unaffected, since no `.tf` file changes.

## Risk

Information loss. Mitigated by archiving rather than deleting, and by the fact
that everything cut from CLAUDE.md is either present in the code it points at
or in a dated spec under `docs/superpowers/specs/`.
