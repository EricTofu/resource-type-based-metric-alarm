bucket       = "<ORG>-tfstate"
key          = "foundation/ops.tfstate"
region       = "<PRIMARY_REGION>"
encrypt      = true
kms_key_id   = "alias/tfstate"
use_lockfile = true
# role_arn will be added after initial bootstrap