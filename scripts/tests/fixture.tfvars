aws_region = "ap-northeast-1"

ec2_resources = [
  { name = "keep-ec2" },
  {
    name      = "skip-ec2"
    overrides = { disabled_alarms = ["memory"] }
  },
]

asg_resources = [
  { name = "keep-asg", desired_capacity = 2 },
  {
    name             = "skip-asg"
    desired_capacity = 2
    overrides        = { disabled_alarms = ["in_service_capacity"] }
  },
]

s3_resources = [
  { name = "keep-bucket" },
  {
    name      = "skip-bucket"
    overrides = { disabled_alarms = ["error_5xx"] }
  },
]
