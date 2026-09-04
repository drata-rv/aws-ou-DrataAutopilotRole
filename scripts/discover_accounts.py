#!/usr/bin/env python3
"""Terraform external-data-source helper: discovers AWS Organizations accounts.

Walks the OU tree top-down (list-organizational-units-for-parent /
list-accounts-for-parent) instead of calling list-parents once per account,
so API call volume is proportional to the number of OUs rather than the
number of accounts. Records each account's full ancestor OU chain so the
Terraform side can match accounts nested at any depth, not just direct
children of a target OU. Only ACTIVE accounts are returned - suspended or
pending-closure accounts can't receive new StackSet instances. Also reports
the calling AWS account so Terraform can verify the AWS CLI and the
Terraform provider operate in the same Organizations management account
(account ID only - not IAM user, role, or STS session), and every root/OU
ID actually seen while walking, so Terraform can reject a target_parent_ids
entry that doesn't exist in this org.

Reads no stdin. Emits a single JSON object on stdout, as required by
Terraform's `external` data source (all top-level values must be strings).
"""
import json
import os
import random
import subprocess
import sys
import time

# Defense in depth: lean on the CLI/SDK's own adaptive retry in addition to our
# explicit backoff below, in case throttling happens deeper inside a single call
# (e.g. mid-pagination) than our retry loop can see.
os.environ.setdefault("AWS_RETRY_MODE", "adaptive")
os.environ.setdefault("AWS_MAX_ATTEMPTS", "10")


def fail(message, exit_code=1):
    sys.stderr.write(message if message.endswith("\n") else message + "\n")
    sys.exit(exit_code)


def aws_json(args, max_attempts=8, timeout_seconds=90):
    cmd = ["aws", *args, "--no-cli-pager", "--output", "json"]

    for attempt in range(1, max_attempts + 1):
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_seconds)
            stderr = proc.stderr or ""
        except subprocess.TimeoutExpired:
            proc = None
            stderr = f"AWS CLI timed out after {timeout_seconds}s: {' '.join(args)}"

        if proc is not None and proc.returncode == 0:
            try:
                return json.loads(proc.stdout or "{}")
            except json.JSONDecodeError as exc:
                fail(f"AWS CLI returned invalid JSON for {args}: {exc}")

        retryable = proc is None or any(
            marker in stderr
            for marker in (
                "Throttling",
                "TooManyRequestsException",
                "RequestLimitExceeded",
                "ServiceUnavailable",
                "InternalError",
                "InternalFailure",
                "Could not connect to the endpoint",
                "Read timeout",
                "Connection reset",
            )
        )
        if retryable and attempt < max_attempts:
            time.sleep(min(2 ** attempt, 30) + random.uniform(0, 1))
            continue

        fail(stderr or f"AWS CLI failed for {args}", proc.returncode if proc is not None else 1)

    fail(f"AWS CLI retry loop exhausted for {args}")


ou_parent = {}
accounts = []
discovered_parent_ids = set()


def walk(parent_id):
    discovered_parent_ids.add(parent_id)
    for account in aws_json(["organizations", "list-accounts-for-parent", "--parent-id", parent_id]).get("Accounts", []):
        if account.get("Status") != "ACTIVE":
            continue
        accounts.append(
            {
                "id": account.get("Id"),
                "name": account.get("Name"),
                "arn": account.get("Arn"),
                "parent_id": parent_id,
            }
        )
    for ou in aws_json(["organizations", "list-organizational-units-for-parent", "--parent-id", parent_id]).get("OrganizationalUnits", []):
        ou_id = ou.get("Id")
        if not ou_id:
            fail(f"AWS Organizations returned an OU without an ID below {parent_id}")
        ou_parent[ou_id] = parent_id
        walk(ou_id)


def ancestor_chain(parent_id):
    chain = [parent_id]
    current = parent_id
    while current in ou_parent:
        current = ou_parent[current]
        chain.append(current)
    return chain


caller_identity = aws_json(["sts", "get-caller-identity"])

roots = aws_json(["organizations", "list-roots"]).get("Roots", [])
if not roots:
    fail("No AWS Organizations roots returned. Use management-account credentials.")

for root in roots:
    root_id = root.get("Id")
    if not root_id:
        fail("AWS Organizations returned a root without an ID.")
    walk(root_id)

for account in accounts:
    account["ancestor_ids"] = ancestor_chain(account["parent_id"])

accounts.sort(key=lambda account: account["id"])

print(json.dumps({
    "accounts_json": json.dumps(accounts),
    "discovered_parent_ids_json": json.dumps(sorted(discovered_parent_ids)),
    "caller_account_id": caller_identity.get("Account", ""),
}))
