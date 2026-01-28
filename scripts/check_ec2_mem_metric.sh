#!/bin/bash
set -e

REGION=$1
INSTANCE_ID=$2

if [ -z "$REGION" ] || [ -z "$INSTANCE_ID" ]; then
  echo "Usage: $0 <REGION_OR_AZ> <INSTANCE_ID>"
  exit 1
fi

# Clean up Region if AZ is passed (e.g. us-east-1a -> us-east-1)
# Simple check: if it ends with a digit, it's likely a region. If a letter, it's an AZ.
if [[ "$REGION" =~ [a-z]$ ]]; then
  REGION=${REGION%?}
fi

# Check if the mem_used_percent metric exists for this instance in CWAgent namespace
METRIC_EXISTS=$(aws cloudwatch list-metrics \
  --namespace CWAgent \
  --metric-name mem_used_percent \
  --dimensions Name=InstanceId,Value=$INSTANCE_ID \
  --region $REGION \
  --output text)

if [ -z "$METRIC_EXISTS" ]; then
  echo "WARNING: Metric 'mem_used_percent' not found for instance $INSTANCE_ID in region $REGION. Please ensure CloudWatch Agent is installed and configured to collect this metric." >&2
fi
