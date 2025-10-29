# terraform-aws-drata-autopilot-role

Terraform module that provisions the Drata Autopilot IAM role across every selected account in an AWS Organization. The module:

- Enumerates organization accounts and filters them by OU, explicit ID lists, or account tags (e.g., `Environment = PROD`).
- Deploys the same tightly-scoped IAM role to each targeted account using a service-managed CloudFormation StackSet, and optionally creates the role in the management account running Terraform.
- Emits both a per-account ARN map and a single management-account ARN that Drata’s OU integration expects.

This guide walks through usage from a beginner’s perspective—no existing Terraform project required.

> **Notes:**  
> • If you received this module as a zipped package, unzip it somewhere convenient and reference the extracted folder in the `module "drata_autopilot_role"` block shown below.  
> • Ensure CloudFormation StackSets has trusted access enabled with AWS Organizations before running Terraform (`aws organizations enable-aws-service-access --service-principal stacksets.cloudformation.amazonaws.com`).  
> • The module shells out to the AWS CLI (via Python) to enumerate organization accounts, so Terraform must run in an environment where the CLI is installed and authenticated.

---

## 1. Prerequisites

Make sure you have:

1. **Terraform CLI ≥ 1.3** (validated with 1.13.x) – download from [terraform.io/downloads](https://developer.hashicorp.com/terraform/downloads).
2. **AWS provider 5.x** – the module pins `< 6.0` because AWS provider v6 dropped the Organizations account listing data sources used for filtering.
3. **AWS CLI** configured with credentials for the **management account** (a profile or environment variables that let you run `aws sts get-caller-identity` successfully).
4. **Python 3.x** available in your shell (used by the module’s helper script that enumerates accounts via the AWS CLI).
5. The management account permissions:
   - `organizations:DescribeOrganization`, `organizations:ListAccounts`, `organizations:ListTagsForResource`, `organizations:ListParents`
   - `sts:AssumeRole` into the member account access role (default `OrganizationAccountAccessRole`)
   - IAM permissions to create roles/policies if deploying to the management account.
6. **CloudFormation StackSets trusted access enabled** for your organization (one-time setup: `aws organizations enable-aws-service-access --service-principal stacksets.cloudformation.amazonaws.com`).
7. (Recommended) Organization accounts tagged with something like `Environment = PROD|DEV|TEST` if you want tag-based filtering.

---

## 2. First-Time Setup (no existing Terraform project)

Follow these steps from an empty working directory.

### Step 1 – Create a project folder

```sh
mkdir drata-autopilot-setup
cd drata-autopilot-setup
```

### Step 2 – Create `main.tf`

Paste the following, adjusting the module `source` path to wherever you unzipped this package (or to a registry/Git source if you are consuming a published release).

```hcl
terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3"
    }
  }
}

provider "aws" {
  region = "us-east-1" # pick any region; IAM itself is global
}

module "drata_autopilot_role" {
  source = "../terraform-aws-drata-autopilot-role" # adjust to the relative path where you unzipped this module (or point to a registry/Git source)

  # Required Drata settings
  drata_aws_account_arn = "arn:aws:iam::269135526815:root"
  role_sts_externalid   = "REPLACE-WITH-YOUR-DRATA-EXTERNAL-ID"

  # Optional targeting controls – tailor to your org
  # target_parent_ids   = ["ou-ab12-cdef3456"]
  # account_tag_filters = { Environment = ["PROD"] }
  # include_account_ids = ["111111111111"]
  # exclude_account_ids = ["999999999999"]

  include_management_account    = true
  # target_region               = "us-west-2" # defaults to provider region when omitted

  role_name        = "DrataAutopilotRole"
  role_description = "Cross-account read-only access for Drata Autopilot"
  role_path        = "/"
  tags             = { ManagedBy = "terraform" }
}

output "management_role_arn" {
  value       = module.drata_autopilot_role.management_role_arn
  description = "Role ARN in the management account (if enabled)."
}

output "drata_role_arn" {
  value       = module.drata_autopilot_role.drata_role_arn
  description = "Single ARN to paste into Drata’s AWS OU connection."
}

output "member_role_arns" {
  value       = module.drata_autopilot_role.member_role_arns
  description = "Map of member account IDs to their Drata role ARN."
}
```

### Step 3 – Provide your Drata External ID

- Sign in to Drata → **Account Settings → Connections → AWS**.
- Copy the **External ID** value and replace `REPLACE-WITH-YOUR-DRATA-EXTERNAL-ID` in the module block above.

Alternatively, keep the placeholder and create a `terraform.tfvars` file (see [Section 4](#4-configuring-module-variables)).

### Step 4 – Initialize Terraform

```sh
terraform init
```

This downloads the AWS provider and the module.

### Step 5 – Review the plan

```sh
terraform plan
```

Look for:
- The management account role (if `include_management_account = true`).
- One module instance for each member account that passed your filters.
- No unexpected accounts being targeted.

### Step 6 – Apply

```sh
terraform apply
```

Type `yes` when you are satisfied with the plan. Terraform will create the IAM role in every targeted account.

### Step 7 – Grab the ARNs

When the apply completes, capture the `drata_role_arn` output for Drata’s connection panel and keep the `management_role_arn` / `member_role_arns` handy for validation or downstream automation. StackSet deployments may take a few minutes; monitor progress in AWS CloudFormation → StackSets if you need to troubleshoot per-account rollouts.

---

## 3. Existing Terraform Projects

If you already use Terraform:

1. Add the module block shown above to an existing `.tf` file.
2. Ensure your root module defines the AWS provider (with the region of your choice).
3. Decide how to pass `role_sts_externalid` and other variables (locals, `.tfvars`, etc.).
4. Run `terraform init -upgrade` (if new module) and follow the usual plan/apply flow.

You can pin a released version via the Terraform Registry or a Git ref, e.g.

```hcl
module "drata_autopilot_role" {
  source  = "git::https://github.com/drata/terraform-aws-drata-autopilot-role.git?ref=v1.0.7"
  # ...
}
```

---

## 4. Configuring Module Variables

You can supply variables three common ways:

1. **Directly in the module block** (as shown above).
2. **`terraform.tfvars` or `*.auto.tfvars` files**:
   ```hcl
   role_sts_externalid     = "abc123"
   account_tag_filters     = { Environment = ["PROD", "SHARED"] }
   include_management_account = false
   ```
   Terraform loads these automatically.
3. **CLI flags** when running plan/apply:
   ```sh
   terraform apply -var='role_sts_externalid=abc123'
   ```

For sensitive values, consider `terraform.tfvars` combined with a `.gitignore`, or inject them from your CI/CD secrets manager.

---

## 5. Important Inputs

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `drata_aws_account_arn` | string | `arn:aws:iam::269135526815:root` | Drata principal allowed to assume the role. Override only if Drata instructs you. |
| `role_sts_externalid` | string | `null` | External ID Drata requires when assuming the role. Almost always mandatory. |
| `target_parent_ids` | list(string) | `[]` | OU IDs you want to include. Empty = organization root. |
| `account_tag_filters` | map(list(string)) | `{}` | Filter accounts by tag (e.g. `{ Environment = ["PROD"] }`). All tag conditions must match. |
| `include_account_ids` | list(string) | `[]` | Allow-list specific accounts (in addition to OU/tag filters). |
| `exclude_account_ids` | list(string) | `[]` | Remove specific accounts after other filters. |
| `include_management_account` | bool | `true` | Create the role in the management account. Set to `false` if Drata should never assume into it. |
| `target_region` | string | `null` | Region where the StackSet instances are deployed. Defaults to the caller’s AWS provider region when omitted. |
| `role_name` / `role_description` / `role_path` | string | Defaults in `variables.tf` | IAM metadata for the created role. |
| `tags` | map(string) | `{}` | Tags applied to the role and inline policy in every account. |

See `variables.tf` for any additional inputs.

---

## 6. Outputs

- `drata_role_arn` – Single ARN to paste into Drata’s AWS OU connection (mirrors the management account role when created).
- `management_role_arn` – ARN of the IAM role in the management account (or `null` if disabled).
- `member_role_arns` – Map of `account_id => role_arn` for each targeted member account.

Use `drata_role_arn` for Drata’s setup wizard. The remaining outputs help with validation or additional automation.

---

## 7. How the Module Works

1. Queries AWS Organizations for every account and its tags.
2. Applies OU, tag, and explicit account filters to determine the deployment set.
3. Optionally creates the IAM role in the management account (same policy surface as the original single-account module).
4. Creates a service-managed CloudFormation StackSet that provisions the IAM role, SecurityAudit attachment, and inline policy into every targeted member account.
5. Returns a map of ARNs for Drata.

IAM permissions remain tightly scoped: the module only attaches the AWS managed `SecurityAudit` policy plus a short Drata-specific inline policy (`backup:ListBackupJobs`, `backup:ListRecoveryPointsByResource`).

---

## 8. Troubleshooting Tips

- **AccessDenied when listing accounts** – confirm your management-account credentials have the Organizations permissions listed in the prerequisites.
- **StackSet instance failures** – confirm CloudFormation StackSets trusted access is enabled and review the StackSet operation detail for failed accounts (common causes are service control policies or pre-existing roles with the same name).
- **Unexpected accounts targeted** – run `terraform plan` and inspect the module keys. Adjust `target_parent_ids`, tag filters, or include/exclude lists accordingly.
- **Region concerns** – the module inherits the region from your provider block unless `target_region` is explicitly set. IAM is global, so the choice primarily impacts STS calls; pick any supported region.

---

## 9. Next Steps

1. Keep the Drata External ID and IAM role name handy for Drata’s onboarding form.
2. Store your Terraform state securely (consider remote state in S3 with locking if you adopt this in production).
3. Review the resulting IAM roles periodically to ensure the `tags`, `description`, and trust policy match your governance standards.
4. Update to newer module releases as Drata requirements evolve.

With these steps, you can deploy the Drata Autopilot role across an AWS Organization confidently and repeatably. Happy automating!
