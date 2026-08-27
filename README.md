# terraform-aws-drata-autopilot-role

Terraform module that provisions the Drata Autopilot IAM role across every selected account in an AWS Organization. The module:

- Enumerates organization accounts and filters them by OU, explicit ID lists, or account tags (e.g., `Environment = PROD`).
- Deploys the same tightly-scoped IAM role to each targeted account using a service-managed CloudFormation StackSet, and optionally creates the role in the management account running Terraform.
- Emits both a per-account ARN map and a single management-account ARN that Drata’s OU integration expects.

This guide walks through usage from a beginner’s perspective—no existing Terraform project required.

> **Notes:**  
> • If you received this module as a zipped package, unzip it somewhere convenient and reference the extracted folder in the `module "drata_autopilot_role"` block shown below.  
> • Ensure CloudFormation StackSets has trusted access enabled with AWS Organizations before running Terraform - either via the CloudFormation console (**StackSets → Activate trusted access**) or `aws organizations enable-aws-service-access --service-principal=member.org.stacksets.cloudformation.amazonaws.com`.  
> • The module shells out to the AWS CLI (via `scripts/discover_accounts.py`) to enumerate organization accounts, so Terraform must run in an environment where the CLI and Python 3 are installed and authenticated. **This must be the exact same AWS identity your Terraform AWS provider is configured with** - the module verifies this at plan time and fails with a clear error if they don't match (see Troubleshooting).  
> • Terraform must run **from the AWS Organizations management account itself** - delegated-administrator execution is not currently supported.  
> • An empty `target_parent_ids` deploys the role to **every account in the entire organization**. The module requires `confirm_organization_wide_deployment = true` as an explicit opt-in if you actually want that; otherwise, set `target_parent_ids`.

---

## 1. Prerequisites

Make sure you have:

1. **Terraform CLI ≥ 1.9** (validated with 1.13.x) – download from [terraform.io/downloads](https://developer.hashicorp.com/terraform/downloads). Cross-variable references inside a variable's own `validation` block (used to reject overlapping `include_account_ids`/`exclude_account_ids`) require 1.9+.
2. **AWS provider 5.x** – the module pins `< 6.0` as a conservative compatibility bound. The AWS provider's `aws_organizations_organization` data source does list every account, but not each account's OU/parent - which OU-based filtering needs - so account discovery still shells out to the AWS CLI via an `external` data source.
3. **AWS CLI** configured with credentials for the **management account**, using the *same* identity/profile your Terraform AWS provider block will use (a profile or environment variables that let you run `aws sts get-caller-identity` successfully).
4. **Python 3.x** available in your shell (used by `scripts/discover_accounts.py`, the module's helper that enumerates accounts via the AWS CLI). Windows is untested - use WSL or a Linux/macOS runner.
5. The management account permissions, matching what the module actually calls:
   - `organizations:DescribeOrganization`, `organizations:ListRoots`, `organizations:ListAccountsForParent`, `organizations:ListOrganizationalUnitsForParent`
   - `organizations:ListTagsForResource` (only needed if you use `account_tag_filters`)
   - `sts:GetCallerIdentity`
   - `cloudformation:CreateStackSet`, `UpdateStackSet`, `DeleteStackSet`, `DescribeStackSet`, `CreateStackInstances`, `UpdateStackInstances`, `DeleteStackInstances`, `DescribeStackInstance`, `ListStackInstances`
   - IAM permissions to create/read/delete roles and inline policies, if deploying to the management account (`include_management_account = true`)
6. **CloudFormation StackSets trusted access enabled** for your organization (one-time setup, from the management account: CloudFormation console → StackSets → Activate trusted access, or `aws organizations enable-aws-service-access --service-principal=member.org.stacksets.cloudformation.amazonaws.com`).
7. (Recommended) Organization accounts tagged with something like `Environment = PROD|DEV|TEST` if you want tag-based filtering.

---

## 2. First-Time Setup (no existing Terraform project)

Follow these steps from an empty working directory.

### Step 1 – Create a project folder

```sh
mkdir drata-autopilot-setup
cd drata-autopilot-setup
git init
printf '*.tfvars\n*.tfvars.json\n.terraform/\n*.tfstate\n*.tfstate.*\n' > .gitignore
```

That last step matters: your `terraform.tfvars` file (Step 3) will hold your Drata External ID in plaintext. Without a `.gitignore` in *this* new project directory specifically, a later `git add .` commits it - the module's own `.gitignore` doesn't extend to a project you create alongside it.

### Step 2 – Create `main.tf`

Paste the following, adjusting the module `source` path to wherever you unzipped this package (or to a registry/Git source if you are consuming a published release). The example below assumes the unzipped module folder is a sibling of `drata-autopilot-setup` (i.e. `source = "../terraform-aws-drata-autopilot-role"` resolves one directory up) — if you placed it elsewhere, adjust the relative path accordingly.

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3, < 3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1" # pick any region; IAM itself is global
  # Must resolve to the SAME AWS identity as the AWS CLI in this environment -
  # the module verifies this at plan time and fails clearly if they diverge.
}

# Root-level variables so terraform.tfvars / -var work as documented in Section 4 -
# they must be declared here AND wired into the module block below, or Terraform
# will warn that the .tfvars value is unused and the module keeps its own default.
variable "role_sts_externalid" {
  type        = string
  sensitive   = true
  description = "External ID from Drata → Account Settings → Connections → AWS."
}

variable "target_parent_ids" {
  type        = list(string)
  default     = []
  description = "OU/root IDs to scope this deployment to. Leave empty only if you want every account in the org (see confirm_organization_wide_deployment)."
}

module "drata_autopilot_role" {
  source = "../terraform-aws-drata-autopilot-role" # adjust to the relative path where you unzipped this module (or point to a registry/Git source)

  # Required Drata settings
  drata_aws_account_arn = "arn:aws:iam::269135526815:root"
  role_sts_externalid   = var.role_sts_externalid

  # Targeting controls – tailor to your org. Leaving target_parent_ids empty deploys
  # to the ENTIRE organization and requires confirm_organization_wide_deployment = true.
  target_parent_ids   = var.target_parent_ids
  # confirm_organization_wide_deployment = true  # only if target_parent_ids is intentionally empty
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

output "resolved_member_account_ids" {
  value       = module.drata_autopilot_role.resolved_member_account_ids
  description = "Review this list on every plan - it's the actual account set that will receive the role."
}
```

### Step 3 – Provide your Drata External ID

- Sign in to Drata → **Account Settings → Connections → AWS**.
- Copy the **External ID** value.
- Create a `terraform.tfvars` file (gitignored by the `.gitignore` you just created) next to this `main.tf`:
  ```hcl
  role_sts_externalid = "paste-your-drata-external-id-here"
  target_parent_ids   = ["ou-ab12-cdef3456"] # or set confirm_organization_wide_deployment = true in the module block instead
  ```

See [Section 4](#4-configuring-module-variables) for other ways to supply variables (CLI flags, CI secrets, etc.).

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
- The `resolved_member_account_ids` output - this is the actual account list, one StackSet instance resource per account.
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

A minimal, working root module is also in [`examples/basic`](examples/basic) if you'd rather start from a file than copy-paste this README.

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
   Terraform loads these automatically. Only works for variables you've declared at the root and wired into the module block (as `role_sts_externalid`/`target_parent_ids` are in the Step 2 example) - a `.tfvars` entry for anything else needs the same root `variable` + wiring added, or set it directly in the module block instead.
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
| `role_sts_externalid` | string | *(required, no default)* | External ID Drata requires when assuming the role. `terraform plan` fails if left unset, since deploying without it leaves the org-wide trust policy with no ExternalId condition. Marked `sensitive`. |
| `target_parent_ids` | list(string) | `[]` | Root ID(s) (`r-xxxx`) or OU ID(s) (`ou-xxxx-xxxxxxxx`) you want to include. Matches accounts nested at **any depth** beneath the given parent(s) — not just direct children. Empty = organization root (every account) - see `confirm_organization_wide_deployment`. |
| `confirm_organization_wide_deployment` | bool | `false` | Required `true` if `target_parent_ids` is intentionally left empty. Blocks `terraform plan` otherwise, so an org-wide rollout can never happen by accident. |
| `account_tag_filters` | map(list(string)) | `{}` | Filter accounts by tag (e.g. `{ Environment = ["PROD"] }`). All tag conditions must match. Empty-string values are rejected (see Troubleshooting). |
| `include_account_ids` | list(string) | `[]` | Optional allow-list that **narrows** the set already scoped by `target_parent_ids`/`account_tag_filters` down to only these account IDs. This is an AND, not an OR — it cannot pull in an account from outside your OU/tag scope. |
| `exclude_account_ids` | list(string) | `[]` | Remove specific accounts after other filters. Cannot overlap with `include_account_ids`. |
| `include_management_account` | bool | `true` | Create the role in the management account. Set to `false` if Drata should never assume into it - note this makes the `drata_role_arn` output fail its own precondition, since Drata's AWS OU integration expects a management-account role ARN. |
| `target_region` | string | `null` | AWS region the CloudFormation StackSet instances are recorded/operated in (each instance is a regional resource, not just a naming detail). Defaults to the caller’s AWS provider region when omitted. |
| `role_name` / `role_description` / `role_path` | string | Defaults in `variables.tf` | IAM metadata for the created role. `role_name` also derives the StackSet name, so it's restricted to letters/digits/hyphens starting with a letter. |
| `tags` | map(string) | `{}` | Tags applied to the management-account IAM role, the StackSet resource, and the member-account role deployed by the StackSet template. (The inline `DrataAdditionalPermissions` policy - management-account and member-account both - isn't taggable via this path.) |

See `variables.tf` for any additional inputs.

---

## 6. Outputs

- `drata_role_arn` – Single ARN to paste into Drata’s AWS OU connection (mirrors the management-account role; fails at plan time if `include_management_account = false`, since Drata's integration needs this to be non-null).
- `management_role_arn` – ARN of the IAM role in the management account (or `null` if disabled).
- `member_role_arns` – Map of `account_id => role_arn` for each targeted member account. Constructed deterministically from validated inputs, not read back from the deployed StackSet.
- `resolved_member_account_ids` / `resolved_member_account_count` – The actual account set that filtering resolved to. **Check this on every plan**, especially with `target_parent_ids` left empty.

Use `drata_role_arn` for Drata’s setup wizard. The remaining outputs help with validation or additional automation.

---

## 7. How the Module Works

1. Runs `scripts/discover_accounts.py` to walk the AWS Organizations OU tree (via the AWS CLI) and list every **active** account with its full OU ancestry.
2. Applies OU, include/exclude, and tag filters (in that order) to determine the deployment set. Tags are only fetched for accounts that already passed the OU/include/exclude filters, and only if `account_tag_filters` is set - not for the whole organization.
3. Optionally creates the IAM role in the management account.
4. Creates a service-managed CloudFormation StackSet, then one StackSet instance resource per selected member account. One resource per account, not one pooled resource for all of them, so that adding or removing a single account only touches that account's own resource - proved directly against the provider that a pooled resource forces a full destroy-and-recreate of every account's role on any membership change, which is a worse failure mode than what per-account resources trade for it (see the note on `OperationInProgressException` below).
5. Returns ARNs and the resolved account list for Drata and for your own review.

IAM permissions remain tightly scoped: the module only attaches the AWS managed `SecurityAudit` policy plus a short Drata-specific inline policy (`backup:ListBackupJobs`, `backup:ListRecoveryPointsByResource`).

**This module does not auto-reconcile.** New accounts, or accounts moved into a target OU after `apply`, are not deployed to until you run Terraform again - the StackSet's own `auto_deployment` is intentionally disabled so this module's OU/include/exclude/tag filtering (not AWS's) stays the source of truth. Re-run `terraform plan`/`apply` on whatever cadence matches how often your org structure changes.

**Removing an account from scope removes its role.** If an account drops out of `target_parent_ids`/`include_account_ids`/`account_tag_filters`, or gets added to `exclude_account_ids`, the next `apply` deletes that account's StackSet instance (and the role with it) - the same as any other Terraform resource removed from desired state. Review `resolved_member_account_ids` in the plan output before applying a filter change on an existing deployment.

**A large first-time apply can hit `OperationInProgressException`.** AWS allows only one operation in flight per StackSet at a time. Terraform applies the per-account StackSet instance resources with its default parallelism (multiple at once), so a first-time rollout to many accounts can have some of them collide and need a retry. Re-running `terraform apply` resolves it; for a very large initial rollout, `terraform apply -parallelism=1` (slower, but collision-free) is worth using for that first run.

---

## 8. Troubleshooting Tips

- **AccessDenied when listing accounts** – confirm your management-account credentials have the Organizations permissions listed in the prerequisites.
- **"Account discovery ran as AWS account X, but the Terraform AWS provider is authenticated as account Y"** – your shell's AWS CLI credentials and your Terraform `provider "aws"` block are resolving to different identities (common if the provider block uses `assume_role`/a different profile than your default AWS CLI credentials). Point both at the same identity.
- **"This module must be run from the AWS Organizations management account"** – this module doesn't support delegated-administrator execution; run it from the actual management account.
- **"target_parent_ids is empty, which deploys the role to every account..."** – set `target_parent_ids`, or set `confirm_organization_wide_deployment = true` if that's genuinely what you want.
- **StackSet instance failures** – confirm CloudFormation StackSets trusted access is enabled and review the StackSet operation detail for failed accounts (common causes are service control policies or pre-existing roles with the same name). Each account has its own StackSet instance resource, so `terraform apply` output tells you exactly which account(s) failed.
- **`Error: ... OperationInProgressException`** – expected on a large first-time apply (see Section 7); re-run `terraform apply`, or use `-parallelism=1` for that first run.
- **Unexpected accounts targeted** – check the `resolved_member_account_ids` output. Adjust `target_parent_ids`, tag filters, or include/exclude lists accordingly. Remember `include_account_ids` only narrows an already-scoped set (see Section 5) — it will not add an account that falls outside `target_parent_ids`.
- **Invalid value for variable errors on `terraform plan`** – account IDs must be 12-digit strings, OU IDs must look like `ou-xxxx-xxxxxxxx` (or `r-xxxx` for a root), `role_sts_externalid` must be set, and `account_tag_filters` values can't be an empty string. These are enforced by variable validation so mistakes surface immediately instead of silently matching zero accounts.
- **Region concerns** – the module inherits the region from your provider block unless `target_region` is explicitly set. IAM itself is global, but each CloudFormation StackSet instance is a regional resource - `target_region` determines where those are recorded and operated, which affects where you'll look in the CloudFormation console to troubleshoot.

---

## 9. Next Steps

1. Keep the Drata External ID and IAM role name handy for Drata’s onboarding form.
2. Store your Terraform state securely (consider remote state in S3 with locking if you adopt this in production). `role_sts_externalid` is marked `sensitive` so it won't appear in CLI/plan output, but Terraform still writes its actual value into state - state is where this module's confused-deputy protection actually lives, not just a place with "descriptive" data in it. Treat an unencrypted or overly-accessible state file as equivalent to leaking that ExternalId.
3. Review the resulting IAM roles periodically to ensure the `tags`, `description`, and trust policy match your governance standards.
4. Update to newer module releases as Drata requirements evolve.

With these steps, you can deploy the Drata Autopilot role across an AWS Organization confidently and repeatably. Happy automating!
