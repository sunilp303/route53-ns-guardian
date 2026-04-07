# Route53 NS Guardian

A Terraform-based solution to detect and manage dangling nameserver (NS) records in AWS Route53.

## Overview

Route53 NS Guardian monitors for dangling NS records in your Route53 zones—records that point to nameservers that are no longer active or associated with any domain. This helps prevent DNS misconfigurations and potential security issues.

## Features

- **Automated Detection**: Lambda-based checker identifies dangling NS records
- **Scheduled Scans**: CloudWatch Events trigger periodic scans
- **Easy Deployment**: Infrastructure as Code using Terraform

## Prerequisites

- **Terraform** >= 1.0
- **AWS Account** with appropriate permissions
- **AWS CLI** configured with valid credentials
- **Python** >= 3.9 (for Lambda function)

## Project Structure

```
.
├── main.tf                    # Main Terraform configuration
├── variables.tf               # Variable definitions
├── outputs.tf                 # Output definitions
├── providers.tf               # Provider configuration
├── terraform.tfvars.example   # Example Terraform variables
└── lambda/
    └── dangling_ns_checker.py # Lambda function code
```

## Installation

1. **Clone or navigate to the project directory**:
   ```bash
   cd route53-ns-guardian
   ```

2. **Copy and configure the variables file**:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```
   Edit `terraform.tfvars` with your desired configuration.

3. **Initialize Terraform**:
   ```bash
   terraform init
   ```

4. **Review the planned changes**:
   ```bash
   terraform plan
   ```

5. **Deploy the infrastructure**:
   ```bash
   terraform apply
   ```

## Usage

Once deployed, the Lambda function runs automatically on a schedule defined in your Terraform configuration. To manually trigger a scan:

```bash
aws lambda invoke \
  --function-name route53-dangling-ns-checker \
  --payload '{}' \
  response.json
```

## Configuration

See `terraform.tfvars.example` for available configuration options. Common variables include:

- `aws_region`: AWS region for deployment
- `lambda_schedule`: CloudWatch schedule expression for scan frequency
- Other configuration as defined in `variables.tf`

## Monitoring and Logs

Lambda logs are available in CloudWatch Logs. Check the log group named after your deployment for detailed execution logs and findings.

## Cleanup

To remove all resources:

```bash
terraform destroy
```

## License

MIT License

## Support

For issues or questions, please create an issue in the repository.
