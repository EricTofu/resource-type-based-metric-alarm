#!/bin/bash
set -e

REGION=$1
BUCKET_NAME=$2

if [ -z "$REGION" ] || [ -z "$BUCKET_NAME" ]; then
  echo "Usage: $0 <REGION> <BUCKET_NAME>"
  exit 1
fi

# Check if request metrics configuration exists for 'EntireBucket'
# get-bucket-metrics-configuration will error if not found or return JSON
METRIC_CONFIG=$(aws s3api get-bucket-metrics-configuration \
  --bucket "$BUCKET_NAME" \
  --id "EntireBucket" \
  --region $REGION \
  2>/dev/null || true)

if [ -z "$METRIC_CONFIG" ]; then
  echo "WARNING: Request metrics configuration 'EntireBucket' not found for S3 bucket $BUCKET_NAME in region $REGION. 5xx error alarms may not have data." >&2
fi
