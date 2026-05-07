# Inventory Reports

This tool generates detailed CSV reports for 60+ AWS services. Each report script collects resource metadata via AWS CLI and outputs a structured CSV file.

## Supported Services

| Script | AWS Service | Description |
|--------|-------------|-------------|
| `acm_report.sh` | AWS ACM | Certificates (domain, status, type, key algo, expiry, in-use) |
| `apigateway_report.sh` | Amazon API Gateway | REST/HTTP/WebSocket APIs (name, type, endpoint, protocol) |
| `asg_report.sh` | Auto Scaling Group | ASGs (min/max/desired capacity, instance count) |
| `aws_billing_report.sh` | AWS Billing | All consumed services and costs from Cost Explorer |
| `aws_ec2_report.sh` | Amazon EC2 | Instances with specs and CPU/Memory utilization |
| `aws_rds_report.sh` | Amazon RDS | Instances with specs, CPU, memory, disk, latency metrics |
| `aws_ri_report.sh` | EC2 Reserved Instances | Purchased RIs (type, term, payment, state) |
| `aws_sp_report.sh` | AWS Savings Plans | SPs (type, commitment, payment option). Global API |
| `aws_workspaces_report.sh` | Amazon WorkSpaces | WorkSpaces (compute, volumes, running mode, last active) |
| `backup_report.sh` | AWS Backup | Vaults + Plans (recovery points, encryption, last execution) |
| `bedrock_report.sh` | Amazon Bedrock | Provisioned throughput, custom models, agents |
| `cloudfront_report.sh` | Amazon CloudFront | Distributions. Global API |
| `cloudwatch_report.sh` | Amazon CloudWatch | Alarms (state, threshold) + Log Groups (size, retention) |
| `codepipeline_report.sh` | AWS CodePipeline | Pipelines (name, ARN, stage count, dates) |
| `config_report.sh` | AWS Config | Rules (compliance status, source type, noncompliant count) |
| `data_transfer_report.sh` | AWS Data Transfer | Cost breakdown + Network In/Out per EC2 (GB) |
| `directconnect_report.sh` | AWS Direct Connect | Connections (state, bandwidth, location, VLAN) |
| `dynamodb_report.sh` | Amazon DynamoDB | Tables (status, item count, size) |
| `ebs_report.sh` | Amazon EBS | Volumes (type, size, IOPS, throughput, state) |
| `ebs_utilization_report.sh` | Amazon EBS | Volumes with utilization metrics (read/write, disk %) |
| `ecr_report.sh` | Amazon ECR | Repositories (image count, tag mutability, scan config) |
| `ecs_report.sh` | Amazon ECS | Clusters (running/pending tasks, active services) |
| `efs_report.sh` | Amazon EFS | File systems (size by storage class, state) |
| `eks_report.sh` | Amazon EKS | Clusters (version, status, creation date) |
| `elasticache_report.sh` | Amazon ElastiCache | Clusters (node type, engine) |
| `elb_report.sh` | Elastic Load Balancing | ALB/NLB/GWLB (type, scheme, state, DNS) |
| `eventbridge_report.sh` | Amazon EventBridge | Rules across event buses (state, schedule, targets) |
| `glue_report.sh` | AWS Glue | Jobs + Crawlers + Databases |
| `iam_report.sh` | AWS IAM | Users (create date, password last used). Global API |
| `kinesis_report.sh` | Amazon Kinesis | Streams (status, mode, shards, retention, encryption) |
| `kms_report.sh` | AWS KMS | Keys (alias, state, usage, spec, rotation) |
| `lambda_report.sh` | AWS Lambda | Functions (runtime, handler, code size) |
| `lightsail_report.sh` | Amazon Lightsail | Instances, databases, LBs, container services |
| `natgateway_report.sh` | NAT Gateway | NAT Gateways (state, VPC, subnet, IPs) |
| `opensearch_report.sh` | Amazon OpenSearch | Domains (engine, instance type, storage, endpoint) |
| `redshift_report.sh` | Amazon Redshift | Clusters (node type, nodes, status, encryption) |
| `route53_report.sh` | Amazon Route 53 | Hosted zones (name, type, record count). Global API |
| `s3_report.sh` | Amazon S3 | Buckets (objects, size, versioning, MFA delete) |
| `sagemaker_report.sh` | Amazon SageMaker | Endpoints, notebook instances, models |
| `secrets_manager_report.sh` | AWS Secrets Manager | Secrets (rotation, last accessed, created) |
| `ses_report.sh` | Amazon SES | Email/domain identities (verification status) |
| `sns_report.sh` | Amazon SNS | Topics (subscription count) |
| `sqs_report.sh` | Amazon SQS | Queues (type, messages, visibility, retention) |
| `ssm_params_report.sh` | AWS SSM Parameter Store | Parameters (type, tier, version). No values exposed |
| `stepfunctions_report.sh` | AWS Step Functions | State machines (type, status, creation date) |
| `transitgateway_report.sh` | AWS Transit Gateway | TGWs (state, ASN, attachment count) |
| `transfer_family_report.sh` | AWS Transfer Family | Servers (protocol, state, endpoint type, identity provider) |
| `vpc_report.sh` | Amazon VPC | VPC resources (subnets, IGW, NAT, SGs, EIPs) |
| `vpn_report.sh` | AWS VPN | Site-to-Site VPN connections (state, gateway IDs) |
| `waf_report.sh` | AWS WAF | Web ACLs with allowed/blocked request counts |
| `apprunner_report.sh` | AWS App Runner | Services (status, source type, CPU, memory, URL) |
| `cognito_report.sh` | Amazon Cognito | User Pools (user count, MFA config, status) |
| `documentdb_report.sh` | Amazon DocumentDB | Clusters (engine version, status, instances, encryption) |
| `grafana_report.sh` | Amazon Managed Grafana | Workspaces (status, authentication, endpoint) |
| `mq_report.sh` | Amazon MQ | Brokers (engine type/version, instance type, deployment mode) |
| `msk_report.sh` | Amazon MSK | Kafka clusters (type, state, version, broker nodes) |
| `neptune_report.sh` | Amazon Neptune | Graph DB clusters (version, status, instances, encryption) |

## Global vs Regional Services

Most scripts loop through specified regions. These are **global APIs** (no region loop):
- IAM, CloudFront, Billing, Savings Plans, Route 53, S3 (bucket listing)

## Output Format

Each script produces a CSV file in `export/aws-cloud-report-YYYY-MM-DD/`. All CSVs are combined into a single Excel file with formatting:
- AWS Account info header
- Formatted column headers
- Conditional highlighting (e.g., stopped EC2 instances highlighted in red)
- Row numbering

## CloudWatch Metrics

Scripts that report utilization data require `-b` and `-e` date arguments:
- `aws_ec2_report.sh` — CPU and Memory utilization
- `aws_rds_report.sh` — CPU, memory, disk, latency
- `ebs_utilization_report.sh` — Read/write bytes, disk used %
- `waf_report.sh` — Request counts

**Note:** Memory utilization for EC2 requires CloudWatch Agent installed on instances. If unavailable, the field shows "N/A".
