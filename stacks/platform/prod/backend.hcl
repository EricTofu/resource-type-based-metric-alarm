# Fill placeholders before running terraform init -backend-config=backend.hcl
bucket       = "<ORG>-tfstate"
key          = "account-prod/platform/sns.tfstate"
region       = "<PRIMARY_REGION>"
encrypt      = true
kms_key_id   = "alias/tfstate"
use_lockfile = true
role_arn     = "<OPS_STATE_ROLE_ARN>"
