# Architecture Discovery Scripts

These scripts auto-discover your AWS infrastructure relationships and generate
Mermaid diagrams that can be rendered in GitHub, Confluence, or any Markdown viewer.

## Scripts

| Script | Scope | What It Discovers |
|--------|-------|-------------------|
| `vpc_topology.sh` | VPC-centric | VPC → Subnets → EC2/RDS/ELB/NAT + connections via Security Groups |
| `serverless_topology.sh` | Serverless | Lambda ← triggers (SQS/SNS/Kinesis/DynamoDB/API GW/EventBridge) |
| `edge_topology.sh` | Edge/CDN | Route 53 → CloudFront → Origins (S3/ELB/API GW/Custom) |

## Usage

```bash
# Run all discovery scripts
chmod +x script/discovery/*.sh

# VPC topology (per region)
./script/discovery/vpc_topology.sh -r ap-southeast-1

# Serverless topology
./script/discovery/serverless_topology.sh -r ap-southeast-1

# Edge/CDN topology (global, no region needed)
./script/discovery/edge_topology.sh
```

## Output

Each script generates a Markdown file with embedded Mermaid diagrams:

```
export/aws-cloud-report-YYYY-MM-DD/
├── architecture_vpc_topology.md
├── architecture_serverless_topology.md
└── architecture_edge_topology.md
```

## Rendering

- **GitHub** — renders Mermaid natively in `.md` files
- **VS Code** — install "Markdown Preview Mermaid Support" extension
- **Confluence** — use Mermaid macro or paste into mermaid.live
- **CLI** — use `mmdc` (mermaid-cli): `npx @mermaid-js/mermaid-cli -i file.md -o output.png`

## Limitations

- Only discovers **explicit** relationships (API-level connections)
- Cannot detect SDK-based calls (e.g., Lambda calling S3 via boto3)
- Large accounts (500+ resources) may produce complex diagrams — use region filtering
- Cross-account connections are not discovered
- Some relationships require specific IAM permissions to query

## How Relationships Are Detected

| Relationship | Detection Method |
|-------------|-----------------|
| EC2 → VPC/Subnet | `describe-instances` → VpcId, SubnetId |
| EC2 → ELB | `describe-target-health` → instance targets |
| EC2 → RDS | Shared Security Groups |
| Lambda ← SQS/Kinesis/DDB | `list-event-source-mappings` |
| Lambda ← SNS | `list-subscriptions` → Lambda endpoint |
| Lambda ← API Gateway | `get-integrations` → Lambda URI |
| CloudFront → S3/ELB | `list-distributions` → Origins |
| Route 53 → CloudFront/ELB | `list-resource-record-sets` → AliasTarget |
| NAT Gateway → VPC | `describe-nat-gateways` → VpcId |
| ELB → VPC | `describe-load-balancers` → VpcId |
