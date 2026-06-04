# M3 Cutover Matrix

**Pilot (M2, already done):** `billing × dev`

**Target:** every (service, account) pair that currently has alarms in the old root.

| Service    | dev  | stg  | prod | prod-apac |
|------------|------|------|------|-----------|
| billing    | DONE | ☐    | ☐    | N/A       |
| checkout   | ☐    | ☐    | ☐    | ☐         |
| inventory  | ☐    | ☐    | ☐    | N/A       |
| notification | ☐  | ☐    | ☐    | N/A       |

Legend: ☐ pending · IN PROGRESS · DONE · N/A (service not deployed in that account)

**Parallelism rules:**
- Across rows (different services): parallel safe. Multiple engineers can cut over `checkout-dev` and `inventory-dev` simultaneously.
- Within a row (same service): SERIAL dev → stg → prod. Each column must be stable ≥ 1h before starting the next.

**Per-row stability:** after flipping a cell to DONE, run `terraform plan -detailed-exitcode` in that leaf and in the old root. Both must exit 0.