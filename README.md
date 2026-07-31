# Resource Type Based Metric Alarms

A modular Terraform project to manage CloudWatch metric alarms for AWS resources, with DRY configuration patterns and per-resource customization capabilities.

## Features

- **11 Monitoring Modules**: ALB, API Gateway, EC2, ASG, Lambda, RDS, S3, CloudFront, ElastiCache, OpenSearch, SES
- **Three-layer Layout**: stateless library modules → platform stacks (SNS topics) → project stacks (alarms)
- **Severity-based SNS Routing**: WARN/ERROR/CRIT → different SNS topics
- **Per-resource Overrides**: Customize thresholds, severity, and descriptions per resource; opt out of individual alarms via `disabled_alarms`

## Project Structure

```text
.
├── modules/cloudwatch/metrics-alarm/   # Stateless library modules (one per resource type)
│   ├── alb/  apigateway/  asg/  cloudfront/  ec2/  elasticache/
│   ├── lambda/  opensearch/  rds/  s3/  ses/
├── stacks/
│   ├── foundation/ops/                 # Ops account: state bucket, accounts map
│   ├── platform/<env>/                 # Per-account SNS topics (create or import)
│   └── projects/<project>/<env>/       # Alarm stacks — call library modules
└── scripts/                            # Preflight metric checks, migration helpers
```

There is no root Terraform configuration — every `terraform` command runs inside a stack directory.

## Quick Start

1. Pick (or scaffold) a project stack and fill in its configuration:

   ```bash
   cd stacks/projects/<project>/<env>
   cp terraform.tfvars.example terraform.tfvars   # or config.yaml.example → config.yaml
   ```

2. List the resources to monitor per type (`alb_resources`, `ec2_resources`, …). SNS topic ARNs are read from the platform stack via remote state — deploy `stacks/platform/<env>/` first.

3. Initialize and apply:

   ```bash
   terraform init -backend-config=backend.hcl
   terraform plan
   terraform apply
   ```

## Configuration

### Resource List Format

Each project stack takes a flat list per resource type; the stack injects the project name:

```hcl
ec2_resources = [
  { name = "web-server-1" },
  { name = "web-server-2", overrides = { cpu_threshold = 90 } },
  { name = "batch-host", overrides = { severity = "CRIT", disabled_alarms = ["memory"] } }
]
```

### Per-Resource Overrides

| Override Field    | Description                                                  |
| ----------------- | ------------------------------------------------------------ |
| `severity`        | Override default severity (WARN/ERROR/CRIT)                  |
| `description`     | Custom alarm description                                     |
| `*_threshold`     | Metric-specific threshold override                           |
| `disabled_alarms` | Set of metric IDs to skip for this resource (opt-out)        |

### Alarm Naming Convention

```text
{Project}-{ResourceType}-[{ResourceName}]-{MetricName}
```

Example: `project1-EC2-[web-server-1]-CPUUtilization`

## Metrics by Resource Type

| Resource Type   | Metrics                                                                              |
| --------------- | ------------------------------------------------------------------------------------ |
| **ALB**         | HTTPCode_ELB_5XX_Count, HTTPCode_Target_5XX_Count, UnHealthyHostCount (per target group — requires `target_groups`), TargetResponseTime |
| **API Gateway** | 5XXError                                                                             |
| **EC2**         | StatusCheckFailed, StatusCheckFailed_AttachedEBS, CPUUtilization, mem_used_percent   |
| **ASG**         | GroupInServiceCapacity                                                               |
| **Lambda**      | Duration (p90), Errors, Throttles, ClaimedAccountConcurrency (account-level)         |
| **RDS**         | FreeableMemory, CPUUtilization, DatabaseConnections, ReadLatency (p90), WriteLatency (p90), FreeStorageSpace (non-Aurora), EngineUptime (Aurora), ACUUtilization + ServerlessDatabaseCapacity (Serverless v2) |
| **S3**          | 5xxErrors, OperationsFailedReplication (opt-in, requires destination bucket)         |
| **ElastiCache** | CPUUtilization, DatabaseMemoryUsagePercentage                                        |
| **OpenSearch**  | CPUUtilization, JVMMemoryPressure, OldGenJVMMemoryPressure, FreeStorageSpace         |
| **SES**         | Reputation.BounceRate                                                                |
| **CloudFront**  | 5xxErrorRate, OriginLatency (us-east-1, via global SNS topics)                       |

## Requirements

- Terraform >= 1.10
- AWS Provider >= 5.0
- AWS credentials with CloudWatch and resource read permissions

## Credits

Google Antigravity (with Gemini 3 Pro and Claude Opus 4.5)

## License

MIT
