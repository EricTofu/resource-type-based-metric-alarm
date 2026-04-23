# Fill placeholders before running terraform init -backend-config=backend.hcl
bucket       = "<ORG>-tfstate"
key          = "account-dev/services/billing/alarms.tfstate"
region       = "<PRIMARY_REGION>"
encrypt      = true
kms_key_id   = "alias/tfstate"
use_lockfile = true
role_arn     = "<OPS_STATE_ROLE_ARN>"
