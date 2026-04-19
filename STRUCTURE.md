# Refactor the project structure

## Target
Refactor the project with the new structure(draft) below with most safety approach

## Structure(Draft)
```
main.tf
modules/
    cloudwatch/
		template/ # use template to call other modules
		    standard/
		        main.tf # wrapper that call other modules
		        variables.tf
		metrics-alarm/ # all alarm modules go here
            monitor-alb/
                main.tf
                variables.tf
            monitor-apigateway/
                ...(same as others)
            ...(other modules)
	    synthetics-canary # add synthetics canary module
		    main.tf
		    variables.tf
    stacks/ # here are all deployments go(`terraform` excutes)
        services/ # multiple services with separeted environments(accounts) across multiple region
            service-1/ # using service name to seperate services
                dev/ # using env name to seperate accounts
                    region-1/ # using region name to seperate regions
                        cloudwatch-alarms/ # organized by AWS services
                            main.tf # calls template/main.tf to reduce duplication
                            varialbes.tf
                            output.tf
                        synthetics-canary/
                            main.tf
                            varialbes.tf
                            ooutput.tf
                    region-2/
                        ...(same as others)
                stg/
                    ...(same as others)
                prod/
                    ...(same as others)
            service-2/
                ...(same as others)
            ...
README.md
resource-type-based-metric-alarm.md
scripts # remove entirly if not useful
    check_asg_metrics.sh
    check_ec2_mem_metric.sh
    check_s3_metrics.sh
terraform.tfvars.example
variables.tf
versions.tf
```

## Concerns
1. Is the structure over complicated/nested?
2. Is the template approach anti-pattern?
3. No 3rd party tools, at least for the beginning(must)
4. Other weak point or anti-patterns?
