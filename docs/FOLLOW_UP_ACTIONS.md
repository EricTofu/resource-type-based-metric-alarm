# 后续事项清单

本文档记录所有里程碑计划实现后，需要手动完成的后续操作。

---

## 1. 占位符替换

所有文件中包含以下占位符，需要在执行 Terraform 前替换为实际值。

### 必填占位符列表

| 占位符 | 说明 | 示例值 | 出现位置 |
|--------|------|--------|----------|
| `<ORG>` | 状态桶前缀（组织缩写） | `acme` | backend.hcl, terraform.tfvars, scripts/migrate/scaffold-leaf.sh |
| `<PRIMARY_REGION>` | 主 AWS 区域 | `ap-northeast-1` | backend.hcl, terraform.tfvars |
| `<OPS_ACCOUNT_ID>` | Ops 账户 12 位 ID | `999999999999` | stacks/foundation/ops/terraform.tfvars.example |
| `<OPS_BOOTSTRAP_PROFILE>` | Ops 账户 AWS CLI profile | `myco-ops-admin` | stacks/foundation/ops/terraform.tfvars.example |
| `<OPS_STATE_ROLE_ARN>` | tf-state-access 角色 ARN | `arn:aws:iam::999999999999:role/tf-state-access` | 所有 backend.hcl |
| `<CALLER_PRINCIPAL_ARN>` | 执行 Terraform 的身份 ARN | `arn:aws:iam::999999999999:user/eric` | stacks/foundation/ops/terraform.tfvars.example |
| `<ACCOUNT_ID_dev>` | dev 账户 ID | `111111111111` | stacks/foundation/ops/terraform.tfvars.example |
| `<ACCOUNT_ID_stg>` | stg 账户 ID | `222222222222` | stacks/foundation/ops/terraform.tfvars.example |
| `<ACCOUNT_ID_prod>` | prod 账户 ID | `333333333333` | stacks/foundation/ops/terraform.tfvars.example |
| `<TF_DEPLOYER_ROLE_ARN_dev>` | dev 账户 tf-deployer 角色 | `arn:aws:iam::111111111111:role/tf-deployer` | stacks/foundation/ops/terraform.tfvars.example |
| `<TF_DEPLOYER_ROLE_ARN_stg>` | stg 账户 tf-deployer 角色 | `arn:aws:iam::222222222222:role/tf-deployer` | stacks/foundation/ops/terraform.tfvars.example |
| `<TF_DEPLOYER_ROLE_ARN_prod>` | prod 账户 tf-deployer 角色 | `arn:aws:iam::333333333333:role/tf-deployer` | stacks/foundation/ops/terraform.tfvars.example |
| `<OLD_ROOT_AWS_PROFILE>` | 旧根使用的 AWS profile | `default` | backups/pre-m4-empty-state-placeholder.md |
| `<PILOT_SERVICE>` | M2 试点服务名 | `billing` | scripts/migrate/scaffold-leaf.sh 环境变量 |
| `<PILOT_ALIAS>` | M2 试点账户别名 | `dev` | scripts/migrate/scaffold-leaf.sh 环境变量 |

### 替换方法

```bash
# 方法 1: 使用 sed 批量替换（推荐先备份）
find . -type f \( -name "*.tf" -o -name "*.hcl" -o -name "*.tfvars.example" -o -name "*.sh" \) \
  -exec sed -i 's/<ORG>/acme/g' {} \;

# 方法 2: 使用编辑器全局搜索替换
# VS Code: Ctrl+Shift+H 搜索 `<ORG>` 并替换

# 方法 3: 手动逐个文件编辑
```

---

## 2. 创建 terraform.tfvars 文件

每个堆栈目录都有 `terraform.tfvars.example`，需要复制并填入实际值。

### Foundation/ops

```bash
cd stacks/foundation/ops
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars，填入：
# - aws_region
# - bootstrap_profile
# - ops_account_id
# - caller_principal_arn
# - org
# - accounts (各账户 ID 和角色 ARN)
```

### Platform/<alias>

```bash
for alias in dev stg prod; do
  cd stacks/platform/$alias
  cp terraform.tfvars.example terraform.tfvars
  # 如果有现有 SNS topic 需导入，设置 sns_choice = "import" 并填入 existing_sns_arns
done
```

### Services/<service>/<alias>

```bash
cd stacks/services/billing/dev
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars，从旧根的 terraform.tfvars 复制 billing 服务的资源列表
# 注意：去掉 project 字段，stack 会自动注入 project = var.service
```

---

## 3. Terraform 执行顺序

必须按以下顺序执行，不能跳跃。

### Phase 1: Foundation Bootstrap

```bash
# 1. 初始化并创建 Ops 账户基础资源
cd stacks/foundation/ops
terraform init
terraform plan
terraform apply

# 2. 迁移状态到 S3 backend（在 apply 成功后）
terraform init -backend-config=backend.hcl -migrate-state
terraform plan  # 确认无变更

# 记录输出的 tf_state_access_role_arn，用于后续 backend.hcl
terraform output tf_state_access_role_arn
```

### Phase 2: Platform SNS Topics

```bash
# 按环境顺序执行（dev → stg → prod）
for alias in dev stg prod; do
  cd stacks/platform/$alias
  
  # 更新 backend.hcl 中的 role_arn（从 foundation 输出获取）
  terraform init -backend-config=backend.hcl
  terraform plan
  terraform apply
  
  # 确认 SNS topic 创建成功
  terraform output sns_topic_arns
done
```

### Phase 3: Service Cutover (M2 → M3)

**M2 试点服务迁移：**

```bash
# 1. 在旧根中列出 billing 服务的所有 alarm
cd <REPO_ROOT>
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state list \
  | grep 'module.monitor_.*\["billing"\].aws_cloudwatch_metric_alarm'

# 2. 填充 billing/dev 的 terraform.tfvars（从旧根复制资源列表）
cd stacks/services/billing/dev
# 编辑 terraform.tfvars...

# 3. 生成 import.tf 和 removed.tf
cd <REPO_ROOT>
export ORG=<ORG>
export PRIMARY_REGION=<PRIMARY_REGION>
export OPS_STATE_ROLE_ARN=<OPS_STATE_ROLE_ARN>
export PILOT_SERVICE=billing
export PILOT_ALIAS=dev
scripts/migrate/generate-split.sh billing stacks/services/billing/dev

# 4. Apply 新 leaf（导入 alarm 到新堆栈）
cd stacks/services/billing/dev
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan.bin  # 检查是否只有 import 操作
terraform apply tfplan.bin

# 5. Apply 旧根的 removed blocks（从旧根删除 alarm）
cd <REPO_ROOT>
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform plan
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform apply

# 6. 清理临时文件
rm stacks/services/billing/dev/import.tf
rm removed.tf

# 7. 从旧根 tfvars 删除 billing 项目条目
# 编辑 ./terraform.tfvars，删除所有 project = "billing" 的块

# 8. 等待 24 小时稳定后再进行同服务的其他环境
```

**M3 其他服务迁移：**

```bash
# 使用 scaffold-leaf.sh 创建新服务堆栈
export ORG=<ORG>
export PRIMARY_REGION=<PRIMARY_REGION>
export OPS_STATE_ROLE_ARN=<OPS_STATE_ROLE_ARN>
export PILOT_SERVICE=billing
export PILOT_ALIAS=dev

scripts/migrate/scaffold-leaf.sh checkout dev

# 然后按 M2 的步骤 2-8 执行

# 注意并行规则：
# - 不同服务可以同时迁移
# - 同一服务必须按 dev → stg → prod 顺序
```

### Phase 4: M4 Decommission Old Root

**在 M3 所有服务迁移完成后：**

```bash
# 1. 确认旧根状态为空
cd <REPO_ROOT>
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state list \
  | grep -E '^module\.monitor_[a-z]+\[' | wc -l
# 预期输出: 0

AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform plan -detailed-exitcode
# 预期: exit 0

# 2. 删除旧根文件
rm -rf .terraform/ .terraform.lock.hcl
rm -f terraform.tfstate terraform.tfstate.backup
git rm main.tf variables.tf versions.tf terraform.tfvars terraform.tfvars.example

# 3. 更新文档
# 编辑 README.md 和 CLAUDE.md，指向 per-stack workflow

# 4. Commit
git commit -m "feat: Decommission old monolithic root (M4)"
```

---

## 4. CI/CD 配置

### GitHub Actions Secrets

需要在 GitHub repository settings 中配置以下 secrets：

| Secret Name | 说明 |
|--------------|------|
| `PREFLIGHT_READ_ROLE_ARN` | 用于 preflight workflow 的 read-only IAM 角色 ARN |

### IAM 角色创建

CI 使用的 IAM 角色需要在 foundation/ops 中创建：

```hcl
# 添加到 stacks/foundation/ops/main.tf
resource "aws_iam_role" "github_actions_preflight" {
  name = "github-actions-preflight-read"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::<OPS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:<ORG>/<REPO>:*"
          }
        }
      }
    ]
  })
}
```

### OIDC Provider 配置

如果尚未配置 GitHub OIDC provider：

```bash
# 在 Ops 账户中创建 OIDC provider
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6937fd5e3e6f8e6e8e6f8e6e8e6f8e6e8e6f8e6e
```

---

## 5. Pre-commit Hooks（可选）

创建 `.pre-commit-config.yaml` 以在本地保持代码质量：

```yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.83.5
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
      - id: terraform_tflint
        args:
          - --args=--config=__GIT_WORKING_DIR__/.tflint.hcl
      - id: terraform_tfsec
```

安装：

```bash
pip install pre-commit
pre-commit install
pre-commit run --all-files
```

---

## 6. 验证清单

完成所有步骤后，执行以下验证：

### M0 + M1 验证

```bash
# Foundation 输出正确
cd stacks/foundation/ops
terraform output accounts
terraform output tf_state_access_role_arn

# Platform SNS topics 存在
cd stacks/platform/dev
terraform output sns_topic_arns
aws sns list-topics --query "Topics[].TopicArn" --output text | grep dev
```

### M2 验证

```bash
# Billing alarm 在新堆栈中
cd stacks/services/billing/dev
terraform state list | grep aws_cloudwatch_metric_alarm

# Alarm ARNs 可引用
terraform output alarm_arns

# 旧根中没有 billing alarm
cd <REPO_ROOT>
terraform state list | grep billing
# 预期: 无输出
```

### M4 验证

```bash
# 根目录无 .tf 文件
find . -maxdepth 1 -name "*.tf" -o -name "*.tfvars"
# 预期: 无输出

# 根目录 gitignore 中的文件已删除
ls terraform.tfstate .terraform/
# 预期: No such file or directory
```

### M6 验证

```bash
# CI workflow 存在
ls .github/workflows/terraform-ci.yml .github/workflows/preflight.yml

# 打开一个 PR 测试 CI
# 在 GitHub 上创建 PR，观察 CI 是否运行

# 模块验证生效
cd stacks/services/billing/dev
# 在 terraform.tfvars 中设置 severity = "warn"（小写）
terraform plan
# 预期: 报错 "overrides.severity must be one of WARN, ERROR, CRIT"
```

---

## 7. 添加新服务

M3 完成后，添加新服务的流程：

```bash
# 1. 设置环境变量
export ORG=<ORG>
export PRIMARY_REGION=<PRIMARY_REGION>
export OPS_STATE_ROLE_ARN=<OPS_STATE_ROLE_ARN>
export PILOT_SERVICE=billing  # 已存在的服务
export PILOT_ALIAS=dev        # 已存在的 alias

# 2. 创建新服务堆栈
scripts/migrate/scaffold-leaf.sh <NEW_SERVICE> <ALIAS>

# 3. 填充 terraform.tfvars
cd stacks/services/<NEW_SERVICE>/<ALIAS>
# 编辑 terraform.tfvars

# 4. Init + Apply
terraform init -backend-config=backend.hcl
terraform plan
terraform apply

# 5. Commit
git add stacks/services/<NEW_SERVICE>/<ALIAS>
git commit -m "feat: Add <NEW_SERVICE> service stack for <ALIAS>"
```

---

## 8. 添加新资源类型

添加新的监控模块流程：

```bash
# 1. 创建模块目录
mkdir -p modules/cloudwatch/metrics-alarm/<NEW_TYPE>

# 2. 创建模块文件
# 参考 modules/cloudwatch/metrics-alarm/ec2/ 结构：
# - versions.tf
# - variables.tf (包含 validation blocks)
# - main.tf
# - outputs.tf
# - common_tags.tf

# 3. 在服务堆栈中使用
# 编辑 stacks/services/<SERVICE>/<ALIAS>/variables.tf，添加 <NEW_TYPE>_resources 变量
# 编辑 stacks/services/<SERVICE>/<ALIAS>/main.tf，添加 module "<NEW_TYPE>_alarms" 调用

# 4. 更新文档
# 编辑 docs/m3-cutover-matrix.md（如果需要迁移）
```

---

## 9. 常见问题排查

### 问题: terraform init 报错 "Error: Failed to get existing workspaces"

**原因**: tf-state-access 角色权限不足或角色 ARN 错误。

**解决**:
```bash
# 检查角色 ARN
aws sts assume-role --role-arn <OPS_STATE_ROLE_ARN> --role-session-name test

# 检查角色权限
aws iam get-role-policy --role-name tf-state-access --policy-name tf-state-access-policy
```

### 问题: import 报错 "Cannot import resource that already exists"

**原因**: alarm 已存在于 AWS 但不在旧根状态中。

**解决**:
```bash
# 手动导入到旧根后再执行迁移
terraform import module.monitor_ec2["billing"].aws_cloudwatch_metric_alarm.cpu["billing-web-1"] <ALARM_NAME>
```

### 问题: plan 显示 alarm 会被重建

**原因**: alarm 命名或配置在新堆栈中与旧根不一致。

**解决**:
```bash
# 比较新旧 alarm 配置
aws cloudwatch describe-alarms --alarm-names <ALARM_NAME> --query 'MetricAlarms[0]'

# 确保 terraform.tfvars 中的资源名称与旧根一致
```

### 问题: CI 报错 "tflint: terraform_required_providers"

**原因**: 模块缺少 required_providers 声明。

**解决**:
```bash
# 添加 versions.tf 到模块
cat > modules/cloudwatch/metrics-alarm/<TYPE>/versions.tf <<'EOF'
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
EOF
```

---

## 10. 联系与支持

如有问题：
1. 查阅 `docs/superpowers/plans/` 中的详细计划文档
2. 查阅 `CLAUDE.md` 和 `README.md`
3. 查看 `IMPLEMENTATION_PLAN.md` 的原始规划

---

**文档版本**: 2026-04-23
**对应 Commit**: `420737f`