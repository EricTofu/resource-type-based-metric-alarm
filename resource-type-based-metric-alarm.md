# Resource Type Based Metric Alarms

## Request

I have several AWS accounts,using cloudwatch to monitor the metrics and set alarms.

I want to create a terraform project to monitor the metrics and set alarms based on resource type(showed below in ## Resource Type Based Metrics).

Since the large number of targets, i want a DRY way to create the alarms, using template or module.

Each resource type has its own metric alarms, with a bunch of resources from different projects.

When given a list of resources(using resource name,for better visibility), we can create every metric alarm in that resource type.

For the list of resources, we can define the resource type, project name, and resource name like this:

```hcl
resource_type = "ec2"
project_name = "project1"
resource_name = [
    "ec2-1",
    "ec2-2"
    ]

resource_type = "ec2"
project_name = "project2"
resource_name = [
    "ec2-3",
    "ec2-4"
    ]

resource_type = "alb"
project_name = "project1"
resource_name = [
    "alb-1",
    "alb-2"
]
```

The metrics alarm for every resource type should be expandable for further tuning.

For those need special treatment, i want to be able to override the default settings

All default values for alarm actions, alarm description, alarm name, alarm severity, etc. should be defined in variables for further tuning.

I also want a complete terraform project structure
and a detailed walkthrough

## Additional Definition for Alarms

- AlarmName:
  - naming convention: {Project}-{ResourceType}-[{ResourceName}]-{MetricName}
- AlarmDescription:
  - Default is ``` {AlarmName} is in ALARM state ```
  - Can be overwriten in individual alarm
- AlarmActions:
  - Default is SNS topic arn based on severity
  - Can be overwriten in individual alarm
- Project
  - Default is ""
  - Can be overwriten in individual alarm
- ResourceType
  - Default is the resource type
  - Can be overwriten in individual alarm
- ResourceName
  - Should be resource name or identifier of resource
  - for ec2, it should be ec2 Name tag, not instance id
  - for others, it should be resource name(not ARN)
- Severity
  - Default is "WARN"
  - Can be overwriten in individual alarm
  - WARN, ERROR, CRIT, each has a notification mapping for different SNS topic arn used in alarm_actions.

## Resource Type Based Metrics

### ALB

- metric: HTTPCode_ELB_5XX_Count
  - statistic: Sum
  - comparison_operator: GreaterThanThreshold
  - threshold: 5
  - evaluation_periods: 5
  - data_points_to_alarm: 5
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: WARN

- metric: HTTPCode_Target_5XX_Count
  - statistic: Sum
  - comparison_operator: GreaterThanThreshold
  - threshold: 5
  - evaluation_periods: 5
  - data_points_to_alarm: 5
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: WARN

- metric: UnHealthyHostCount
  - statistic: Minimum
  - comparison_operator: GreaterThanThreshold
  - threshold: 1
  - evaluation_periods: 5
  - data_points_to_alarm: 5
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: ERROR

- metric: TargetResponseTime
  - statistic: p90
  - comparison_operator: GreaterThanThreshold
  - threshold: 20
  - evaluation_periods: 5
  - data_points_to_alarm: 5
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: WARN

### API Gateway

- metric: 5XXError
  - statistic: Average
  - comparison_operator: GreaterThanThreshold
  - threshold: 0.05
  - evaluation_periods: 3
  - data_points_to_alarm: 3
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: WARN

### EC2

- metric: StatusCheckFailed
  - statistic: Maximum
  - comparison_operator: GreaterThanOrEqualToThreshold
  - threshold: 1
  - evaluation_periods: 2
  - data_points_to_alarm: 2
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: ERROR

- metric: StatusCheckFailed_AttachedEBS
  - statistic: Maximum
  - comparison_operator: GreaterThanOrEqualToThreshold
  - threshold: 1
  - evaluation_periods: 2
  - data_points_to_alarm: 2
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: ERROR

- metric: CPUUtilization
  - statistic: Average
  - comparison_operator: GreaterThanThreshold
  - threshold: 80
  - evaluation_periods: 3
  - data_points_to_alarm: 3
  - period: 300
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: WARN

- metric: mem_used_percent
  - statistic: Average
  - comparison_operator: GreaterThanThreshold
  - threshold: 80
  - evaluation_periods: 3
  - data_points_to_alarm: 3
  - period: 300
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: WARN

### Auto Scaling Group

- metric: GroupInServiceCapacity
  - statistic: Average
  - comparison_operator: LessThanThreshold
  - threshold: 2(GroupDesiredCapacity, this one should be set individually for different ASG)
  - evaluation_periods: 10
  - data_points_to_alarm: 10
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: ERROR

### Lambda

- metric: Duration
  - statistic: p90
  - comparison_operator: GreaterThanThreshold
  - threshold: 172000(90% of lambda timeout, this one should be set individually for different lambda)
  - evaluation_periods: 15
  - data_points_to_alarm: 15
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: WARN

- metric: ClaimedAccountConcurrency
  - statistic: Average
  - comparison_operator: GreaterThanThreshold
  - threshold: 900
  - evaluation_periods: 10
  - data_points_to_alarm: 10
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: WARN
  
### Aurora & RDS

- metric: FreeableMemory
  - statistic: Average
  - comparison_operator: LessThanThreshold
  - threshold: TBD(10% of instance type capacity, this one should be set individually for different instance type)
  - evaluation_periods: 5
  - data_points_to_alarm: 5
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: ERROR
  
- metric: CPUUtilization
  - statistic: Average
  - comparison_operator: GreaterThanThreshold
  - threshold: 90
  - evaluation_periods: 5
  - data_points_to_alarm: 5
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: ERROR

- metric: DatabaseConnections
  - statistic: Average
  - comparison_operator: GreaterThanThreshold
  - threshold: 2700(90% of max_connections, this one should be set individually for different database instance type)
  - evaluation_periods: 5
  - data_points_to_alarm: 5
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: ERROR

- metric: FreeStorageSpace
  - statistic: Minimum
  - comparison_operator: LessThanThreshold
  - threshold: TBD(10% of allocated storage, this one should be set individually for different instance type)
  - evaluation_periods: 5
  - data_points_to_alarm: 5
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: ERROR

- metric: EngineUptime
  - statistic: Average
  - comparison_operator: LessThanOrEqualToThreshold
  - threshold: 0
  - evaluation_periods: 2
  - data_points_to_alarm: 2
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: CRIT

### S3

- metric: 5XXErrors
  - statistic: Average
  - comparison_operator: GreaterThanThreshold
  - threshold: 0.05
  - evaluation_periods: 15
  - data_points_to_alarm: 15
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: WARN

- metric: OperationsFailedReplication
  - statistic: Maximum
  - comparison_operator: GreaterThanThreshold
  - threshold: 0
  - evaluation_periods: 5
  - data_points_to_alarm: 5
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: WARN

### ElastiCache(Redis)

- metric: CPUUtilization
  - statistic: Average
  - comparison_operator: GreaterThanThreshold
  - threshold: 90
  - evaluation_periods: 5
  - data_points_to_alarm: 5
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: ERROR

- metric: DatabaseMemoryUsagePercentage
  - statistic: Average
  - comparison_operator: GreaterThanThreshold
  - threshold: 90
  - evaluation_periods: 5
  - data_points_to_alarm: 5
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: ERROR

### OpenSearch(ElasticSearch)

- metric: CPUUtilization
  - statistic: Maximum
  - comparison_operator: GreaterThanOrEqualToThreshold
  - threshold: 80
  - evaluation_periods: 3
  - data_points_to_alarm: 3
  - period: 300
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: ERROR

- metric: JVMMemoryPressure
  - statistic: Maximum
  - comparison_operator: GreaterThanOrEqualToThreshold
  - threshold: 95
  - evaluation_periods: 3
  - data_points_to_alarm: 3
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: ERROR

- metric: OldGenJVMMemoryPressure
  - statistic: Maximum
  - comparison_operator: GreaterThanOrEqualToThreshold
  - threshold: 95
  - evaluation_periods: 3
  - data_points_to_alarm: 3
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: ERROR

- metric: FreeStorageSpace
  - statistic: Minimum
  - comparison_operator: LessThanOrEqualToThreshold
  - threshold: 20480(20GiB or 25% of storage space for each node, this one should be set individually for different node type)
  - evaluation_periods: 5
  - data_points_to_alarm: 5
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: WARN

### SES

- metric: Reputation.BounceRate
  - statistic: Average
  - comparison_operator: GreaterThanOrEqualToThreshold
  - threshold: 0.03
  - evaluation_periods: 5
  - data_points_to_alarm: 5
  - period: 60
  - alarm_actions: using severity based alarm_actions or overwriten in individual alarm
  - severity: WARN


