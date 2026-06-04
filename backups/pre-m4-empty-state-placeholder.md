# Pre-M4 Empty State Snapshot

This file documents that the old root state is empty after M3 completion.

**Verification steps (before M4):**

```bash
# 1. List any remaining monitoring modules in old root state
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state list | grep -E '^module\.monitor_[a-z]+\[' | wc -l
# Expected: 0

# 2. Confirm terraform plan is clean
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform plan -detailed-exitcode
# Expected: exit 0

# 3. Pull final empty-state snapshot
AWS_PROFILE=<OLD_ROOT_AWS_PROFILE> terraform state pull > backups/pre-m4-final-empty-root.tfstate
jq '.resources | length' backups/pre-m4-final-empty-root.tfstate
# Expected: 0
```

**After verification, M4 proceeds to:**
- Delete `./.terraform/`, `./.terraform.lock.hcl`, local state files
- Delete `./main.tf`, `./variables.tf`, `./versions.tf`, `./terraform.tfvars`, `./terraform.tfvars.example`
- Update README.md and CLAUDE.md to point to per-stack workflow
- Archive `docs/m3-cutover-matrix.md` to `docs/archive/`

**Placeholder tokens to fill:**
- `<OLD_ROOT_AWS_PROFILE>`: AWS CLI profile the old root used (e.g., `default`)