# Multi-Account Setup Guide

## Overview

The multi-account runner (`multi_account_runner.sh`) generates reports across multiple AWS accounts by assuming a cross-account IAM role in each target account. This guide covers the prerequisite IAM configuration required in each target account.

### What the Role Provides

The cross-account role grants the runner account:
- **ReadOnlyAccess** — AWS managed policy for inventory and configuration data
- **ce:GetCostAndUsage** — Cost Explorer billing data
- **pricing:GetProducts** — AWS Pricing API for optimization reports
- **support:DescribeTrustedAdvisor*** — Trusted Advisor checks (requires Business/Enterprise Support)

---

## Trust Policy

Create this trust policy in each target account. Replace `<RUNNER_ACCOUNT_ID>` with the 12-digit AWS account ID where you run `multi_account_runner.sh`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<RUNNER_ACCOUNT_ID>:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "aws-cloud-report"
        }
      }
    }
  ]
}
```

> **Note:** The `ExternalId` condition is optional but recommended to prevent confused deputy attacks. If you use it, pass `--external-id aws-cloud-report` to the runner (future enhancement).

---

## Permission Policy

### Managed Policy

Attach the AWS managed policy:
- `arn:aws:iam::aws:policy/ReadOnlyAccess`

### Inline Policy (Additional Permissions)

Create an inline policy named `CloudReportAdditionalAccess`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CostExplorerAccess",
      "Effect": "Allow",
      "Action": [
        "ce:GetCostAndUsage",
        "ce:GetCostForecast",
        "ce:GetReservationUtilization",
        "ce:GetSavingsPlansUtilization"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PricingAccess",
      "Effect": "Allow",
      "Action": [
        "pricing:GetProducts",
        "pricing:DescribeServices"
      ],
      "Resource": "*"
    },
    {
      "Sid": "TrustedAdvisorAccess",
      "Effect": "Allow",
      "Action": [
        "support:DescribeTrustedAdvisorChecks",
        "support:DescribeTrustedAdvisorCheckResult",
        "support:DescribeTrustedAdvisorCheckSummaries",
        "support:RefreshTrustedAdvisorCheck"
      ],
      "Resource": "*"
    }
  ]
}
```

---

## AWS CLI Commands

Run these commands in each **target account** (or use CloudFormation below):

```bash
# Variables — customize these
RUNNER_ACCOUNT_ID="123456789012"   # Account where multi_account_runner.sh runs
ROLE_NAME="CrossAccountReportRole"

# 1. Create the IAM role with trust policy
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "AWS": "arn:aws:iam::'"$RUNNER_ACCOUNT_ID"':root"
        },
        "Action": "sts:AssumeRole",
        "Condition": {
          "StringEquals": {
            "sts:ExternalId": "aws-cloud-report"
          }
        }
      }
    ]
  }' \
  --description "Cross-account role for AWS Cloud Report generation"

# 2. Attach ReadOnlyAccess managed policy
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/ReadOnlyAccess"

# 3. Add inline policy for Cost Explorer, Pricing, and Trusted Advisor
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "CloudReportAdditionalAccess" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "CostExplorerAccess",
        "Effect": "Allow",
        "Action": ["ce:GetCostAndUsage","ce:GetCostForecast","ce:GetReservationUtilization","ce:GetSavingsPlansUtilization"],
        "Resource": "*"
      },
      {
        "Sid": "PricingAccess",
        "Effect": "Allow",
        "Action": ["pricing:GetProducts","pricing:DescribeServices"],
        "Resource": "*"
      },
      {
        "Sid": "TrustedAdvisorAccess",
        "Effect": "Allow",
        "Action": ["support:DescribeTrustedAdvisorChecks","support:DescribeTrustedAdvisorCheckResult","support:DescribeTrustedAdvisorCheckSummaries","support:RefreshTrustedAdvisorCheck"],
        "Resource": "*"
      }
    ]
  }'
```

---

## CloudFormation Template

Deploy this stack in each target account:

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Cross-account IAM role for AWS Cloud Report generation

Parameters:
  RunnerAccountId:
    Type: String
    Description: The 12-digit AWS account ID where multi_account_runner.sh runs
    AllowedPattern: '^\d{12}$'
    ConstraintDescription: Must be a valid 12-digit AWS account ID

  RoleName:
    Type: String
    Default: CrossAccountReportRole
    Description: Name of the IAM role to create

Resources:
  CrossAccountReportRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Ref RoleName
      Description: Cross-account role for AWS Cloud Report generation
      MaxSessionDuration: 7200
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              AWS: !Sub 'arn:aws:iam::${RunnerAccountId}:root'
            Action: sts:AssumeRole
            Condition:
              StringEquals:
                sts:ExternalId: aws-cloud-report
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/ReadOnlyAccess
      Policies:
        - PolicyName: CloudReportAdditionalAccess
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Sid: CostExplorerAccess
                Effect: Allow
                Action:
                  - ce:GetCostAndUsage
                  - ce:GetCostForecast
                  - ce:GetReservationUtilization
                  - ce:GetSavingsPlansUtilization
                Resource: '*'
              - Sid: PricingAccess
                Effect: Allow
                Action:
                  - pricing:GetProducts
                  - pricing:DescribeServices
                Resource: '*'
              - Sid: TrustedAdvisorAccess
                Effect: Allow
                Action:
                  - support:DescribeTrustedAdvisorChecks
                  - support:DescribeTrustedAdvisorCheckResult
                  - support:DescribeTrustedAdvisorCheckSummaries
                  - support:RefreshTrustedAdvisorCheck
                Resource: '*'

Outputs:
  RoleArn:
    Description: ARN of the cross-account report role
    Value: !GetAtt CrossAccountReportRole.Arn
    Export:
      Name: !Sub '${AWS::StackName}-RoleArn'
```

**Deploy:**
```bash
aws cloudformation deploy \
  --template-file multi-account-role.yaml \
  --stack-name cross-account-report-role \
  --parameter-overrides RunnerAccountId=123456789012 \
  --capabilities CAPABILITY_NAMED_IAM
```

---

## Verification Steps

Run these commands from the **runner account** to verify the setup:

```bash
# 1. Verify you can assume the role
aws sts assume-role \
  --role-arn "arn:aws:iam::<TARGET_ACCOUNT_ID>:role/CrossAccountReportRole" \
  --role-session-name "verification-test" \
  --external-id "aws-cloud-report" \
  --duration-seconds 900

# 2. Export the temporary credentials (from the output above)
export AWS_ACCESS_KEY_ID="<AccessKeyId>"
export AWS_SECRET_ACCESS_KEY="<SecretAccessKey>"
export AWS_SESSION_TOKEN="<SessionToken>"

# 3. Verify identity in target account
aws sts get-caller-identity
# Should show the target account ID and assumed role ARN

# 4. Verify ReadOnlyAccess works
aws ec2 describe-instances --region us-east-1 --max-items 1

# 5. Verify Cost Explorer access
aws ce get-cost-and-usage \
  --time-period Start=2025-01-01,End=2025-01-31 \
  --granularity MONTHLY \
  --metrics BlendedCost

# 6. Clean up test credentials
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

---

## Troubleshooting

### AccessDenied when assuming role

**Cause:** Trust policy does not allow the runner account.

**Fix:** Verify the `Principal.AWS` in the trust policy matches your runner account ID:
```bash
aws iam get-role --role-name CrossAccountReportRole --query 'Role.AssumeRolePolicyDocument'
```

### MalformedPolicyDocument error

**Cause:** JSON syntax error in the trust or permission policy.

**Fix:** Validate your JSON before applying:
```bash
python3 -m json.tool < policy.json
```

### Trust policy not taking effect

**Cause:** IAM changes can take a few seconds to propagate.

**Fix:** Wait 10-15 seconds after creating/updating the role, then retry.

### Session duration exceeded

**Cause:** The role's `MaxSessionDuration` is shorter than the requested duration.

**Fix:** Update the role's max session duration:
```bash
aws iam update-role --role-name CrossAccountReportRole --max-session-duration 7200
```

### Missing permissions for specific reports

**Cause:** `ReadOnlyAccess` doesn't cover all services (e.g., some newer services).

**Fix:** Check which API call is failing and add the specific permission to the inline policy:
```bash
# Check CloudTrail for AccessDenied events
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=<FailingAPICall> \
  --max-results 5
```

### Organizations API AccessDenied

**Cause:** The runner account doesn't have `organizations:ListAccounts` permission, or it's not the management account.

**Fix:** The `--source organizations` option requires running from the AWS Organizations management account (or a delegated admin). Use `--source file` with `accounts.conf` as an alternative.

### Cannot assume role in own account

**Cause:** The runner account is included in the Organizations list.

**Fix:** The script automatically excludes the current account when using `--source organizations`. If using `--source file`, simply don't list your own account in `accounts.conf`.
