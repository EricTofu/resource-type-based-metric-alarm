#!/bin/bash
set -e

REGION=$1
ASG_NAME=$2

if [ -z "$REGION" ] || [ -z "$ASG_NAME" ]; then
  echo "Usage: $0 <REGION> <ASG_NAME>"
  exit 1
fi

# Check if GroupInServiceInstances metric is enabled
# descibe-metric-collection-types doesn't explicitly show per-ASG status easily,
# better to check the ASG details for EnabledMetrics
ENABLED_METRICS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region $REGION \
  --query "AutoScalingGroups[0].EnabledMetrics[*].Metric" \
  --output text)

if [[ ! "$ENABLED_METRICS" == *"GroupInServiceInstances"* ]]; then
  echo "WARNING: Metric 'GroupInServiceInstances' is not enabled for ASG $ASG_NAME in region $REGION. Please enable group metrics collection." >&2
fi
