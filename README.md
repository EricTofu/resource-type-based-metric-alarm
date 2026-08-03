# Resource Type Based Metric Alarms

A modular Terraform project managing CloudWatch metric alarms for AWS
resources, with DRY configuration and per-resource customization.

## Features

- **13 alarm modules**, one per resource type
- **Three-layer layout**: stateless library modules → platform stacks (SNS
  topics) → project stacks (alarms)
- **Severity-based SNS routing**: WARN / ERROR / CRIT to different topics
- **Per-resource overrides**: thresholds, severity, description; opt out of
  individual alarms with `disabled_alarms`
- **Fleet alarms**: one alarm covers a whole auto-scaling fleet and re-resolves
  its members every evaluation, so CodeDeploy churn needs no re-apply
- **Preflight checks** in CI that confirm a metric exists before an alarm is
  built on it

## Project structure

```text
.
├── modules/cloudwatch/
│   ├── metrics-alarm/       # Stateless library modules, one per resource type
│   │   ├── alb/  apigateway/  asg/  cloudfront/  ec2/  efs/  elasticache/
│   │   └── jmx/  lambda/  opensearch/  rds/  s3/  ses/
│   ├── dashboard/jmx/       # JVM dashboard (Metrics Insights, resolves at render time)
│   └── synthetics-canary/   # Heartbeat canary module (not yet wired to a stack)
├── stacks/
│   ├── foundation/ops/      # Ops account: state bucket, accounts map
│   ├── platform/<env>/      # Per-account SNS topics (create or import)
│   └── projects/<project>/<env>/   # Alarm stacks — call the library modules
├── cwagent/                 # CloudWatch Agent config templates
├── dashboards/              # Importable dashboard snapshots
├── scripts/                 # Preflight metric checks, migration helpers
└── docs/                    # Design specs, implementation plans, history
```

There is no root Terraform configuration — every `terraform` command runs
inside a stack directory.

## Quick start

Deploy `stacks/platform/<env>/` first; project stacks read its SNS topic ARNs
through remote state.

```bash
cd stacks/projects/<project>/<env>
cp terraform.tfvars.example terraform.tfvars   # or config.yaml.example → config.yaml

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

## Configuration

Each project stack takes a flat list per resource type. The stack supplies the
project and environment names.

```hcl
ec2_resources = [
  { name = "web-server-1" },
  { name = "web-server-2", overrides = { cpu_threshold = 90 } },
  { name = "batch-host",   overrides = { severity = "CRIT", disabled_alarms = ["memory"] } },
]
```

Each module's `variables.tf` is authoritative for the fields its `resources`
and `overrides` objects accept, and for every default. Terraform **silently
drops** object attributes a module does not declare, so a field that looks
accepted may simply be ignored — check the module before relying on one.

### Alarm naming

```text
{Project}-{Env}-{ResourceType}-[{ResourceName}]-{MetricName}
```

For example `billing-dev-EC2-[web-server-1]-CPUUtilization`, with the alarm
description prefixed `[WARN]-` / `[ERROR]-` / `[CRIT]-`.

### Which metrics each type alarms on

Read the module: `modules/cloudwatch/metrics-alarm/<type>/main.tf`, where one
`aws_cloudwatch_metric_alarm` block corresponds to one metric. That file is the
only authoritative list — this README deliberately does not duplicate it.

| Module | Covers |
| --- | --- |
| `alb` | 5xx rates, unhealthy hosts per target group, target response time |
| `apigateway` | Server-side error rate |
| `asg` | In-service capacity; optional per-instance CPU/memory/disk fleet guardrails |
| `cloudfront` | Error rate and origin latency (us-east-1, via global SNS topics) |
| `ec2` | Status checks, CPU, and CloudWatch Agent memory/disk |
| `efs` | Throughput utilization sustained over a long window |
| `elasticache` | CPU and memory usage |
| `jmx` | JVM heap and GC time for Java hosts, scoped by `AppName` |
| `lambda` | Duration against configured timeout, errors, throttles, account concurrency |
| `opensearch` | CPU, JVM memory pressure, free storage |
| `rds` | Memory, CPU, connections, latency, storage; Aurora and Serverless v2 variants |
| `s3` | Server-side errors and optional replication failures |
| `ses` | Bounce reputation |

## Requirements

- Terraform >= 1.10
- AWS Provider >= 5.0
- AWS credentials with CloudWatch and resource read permissions

## Documentation

- [`CLAUDE.md`](CLAUDE.md) — architecture, design decisions, and the footguns
  worth knowing before changing anything
- `docs/superpowers/specs/` — dated design specs
- `docs/history/` — superseded documents, kept for provenance only

## Credits

Google Antigravity (with Gemini 3 Pro and Claude Opus 4.5)

## License

MIT
