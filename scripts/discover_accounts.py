#!/usr/bin/env python3
"""Terraform external-data-source helper: discovers AWS Organizations accounts.

Walks the OU tree top-down (list-organizational-units-for-parent /
list-accounts-for-parent) instead of calling list-parents once per account,
so API call volume is proportional to the number of OUs rather than the
number of accounts. Records each account's full ancestor OU chain so the
Terraform side can match accounts nested at any depth, not just direct
children of a target OU. Only ACTIVE accounts are returned - suspended or
pending-closure accounts can't receive new StackSet instances. Also reports
the calling identity so Terraform can verify this script ran as the same
AWS identity as the Terraform AWS provider itself (they can diverge if the
provider uses assume_role/profile settings this subprocess doesn't see).

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


def aws_json(args, max_attempts=8):
    cmd = ["aws"] + args + ["--output", "json"]
    for attempt in range(1, max_attempts + 1):
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode == 0:
            return json.loads(proc.stdout or "{}")
        stderr = proc.stderr or ""
        retryable = any(
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
        sys.stderr.write(stderr)
        sys.exit(proc.returncode or 1)
    return {}


ou_parent = {}
accounts = []


def walk(parent_id):
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

for root in aws_json(["organizations", "list-roots"]).get("Roots", []):
    walk(root.get("Id"))

for account in accounts:
    account["ancestor_ids"] = ancestor_chain(account["parent_id"])

print(json.dumps({
    "accounts_json": json.dumps(accounts),
    "caller_account_id": caller_identity.get("Account", ""),
}))
