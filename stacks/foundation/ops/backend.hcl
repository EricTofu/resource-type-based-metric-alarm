# Fill placeholders before running terraform init -backend-config=backend.hcl
# <ORG>              — short slug used in the state bucket name (e.g. acme)
# <PRIMARY_REGION>   — AWS region for the state bucket (e.g. ap-northeast-1)
# <OPS_BOOTSTRAP_PROFILE> — AWS CLI profile with admin access to the Ops account

bucket       = "<ORG>-tfstate"
key          = "foundation/ops.tfstate"
region       = "<PRIMARY_REGION>"
encrypt      = true
kms_key_id   = "alias/tfstate"
use_lockfile = true
profile      = "<OPS_BOOTSTRAP_PROFILE>"
