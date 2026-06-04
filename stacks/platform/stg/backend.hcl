bucket       = "<ORG>-tfstate"
key          = "account-stg/platform/sns.tfstate"
region       = "<PRIMARY_REGION>"
encrypt      = true
kms_key_id   = "alias/tfstate"
use_lockfile = true
role_arn     = "<OPS_STATE_ROLE_ARN>"