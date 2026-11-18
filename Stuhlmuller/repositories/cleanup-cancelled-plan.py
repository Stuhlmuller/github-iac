#!/usr/bin/env python3
"""Inspect or delete one cancelled, versioned GitHub IaC plan artifact."""

import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

BUCKET = "rstuhlmuller-aws-s3-use1-datalake"
COMMIT = "3895951caad2f0828c9479e2ead97f8d56d38c14"
RUN_ID = "44247272941"
KEY = f"IaC/github-iac/saved-plans/{COMMIT}/{RUN_ID}-1/plan.out"
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
KMS_KEY = re.compile(r"arn:aws:kms:us-east-1:[0-9]{12}:key/[A-Za-z0-9-]+\Z")


def aws(*args):
    result = subprocess.run(["aws", "s3api", *args], capture_output=True,
                            text=True, check=False, timeout=60)
    if result.returncode:
        raise RuntimeError("AWS artifact check failed; private details withheld")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("AWS artifact response was not JSON") from exc


def sole_version(inventory):
    versions = [item for item in inventory.get("Versions", []) if item.get("Key") == KEY]
    markers = [item for item in inventory.get("DeleteMarkers", []) if item.get("Key") == KEY]
    if len(versions) != 1 or markers or not versions[0].get("IsLatest"):
        raise RuntimeError("Cancelled plan key must have exactly one latest version and no delete markers")
    version = versions[0].get("VersionId")
    if (not isinstance(version, str) or not version or version == "null"
            or any(ord(char) < 33 or ord(char) > 126 for char in version)):
        raise RuntimeError("Cancelled plan has no stable version ID")
    return version


def validate_head(head, version):
    metadata = head.get("Metadata") or {}
    if head.get("VersionId") != version or head.get("ServerSideEncryption") != "aws:kms":
        raise RuntimeError("Cancelled plan version or encryption does not match")
    if metadata.get("commit") != COMMIT or metadata.get("run-id") != RUN_ID:
        raise RuntimeError("Cancelled plan provenance does not match")
    if not isinstance(head.get("ContentLength"), int) or head["ContentLength"] <= 0:
        raise RuntimeError("Cancelled plan is empty")
    for name in ("sha256", "before-sha256", "after-sha256"):
        if not HEX64.fullmatch(metadata.get(name, "")):
            raise RuntimeError("Cancelled plan hash metadata is invalid")
    kms_key = head.get("SSEKMSKeyId", "")
    if not KMS_KEY.fullmatch(kms_key):
        raise RuntimeError("Cancelled plan KMS key identity is invalid")
    return {"sha256": metadata["sha256"], "before_sha256": metadata["before-sha256"],
            "after_sha256": metadata["after-sha256"], "kms_key_id": kms_key}


def inspect():
    inventory = aws("list-object-versions", "--bucket", BUCKET, "--prefix", KEY)
    version = sole_version(inventory)
    head = aws("head-object", "--bucket", BUCKET, "--key", KEY,
               "--version-id", version)
    receipt = validate_head(head, version)
    with tempfile.TemporaryDirectory(prefix="cancelled-plan-") as directory:
        plan = Path(directory) / "plan.out"
        aws("get-object", "--bucket", BUCKET, "--key", KEY,
            "--version-id", version, str(plan))
        if hashlib.sha256(plan.read_bytes()).hexdigest() != receipt["sha256"]:
            raise RuntimeError("Cancelled plan bytes do not match metadata")
    return version, receipt


def verify_current_main(expected):
    if not HEX40.fullmatch(expected or ""):
        raise RuntimeError("Expected current main SHA is invalid")
    if os.environ.get("GITHUB_SHA") and os.environ["GITHUB_SHA"] != expected:
        raise RuntimeError("Workflow source commit changed")
    commands = (["git", "rev-parse", "HEAD"],
                ["git", "ls-remote", "https://github.com/Stuhlmuller/github-iac.git",
                 "refs/heads/main"])
    for command in commands:
        result = subprocess.run(command, capture_output=True, text=True,
                                check=False, timeout=20)
        if result.returncode or result.stdout.split()[0:1] != [expected]:
            raise RuntimeError("Current main advanced; refusing cancelled-plan deletion")


def write_receipt(version, receipt):
    output = os.environ.get("GITHUB_OUTPUT")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if os.environ.get("GITHUB_ACTIONS") == "true" and (not output or not summary):
        raise RuntimeError("GitHub review receipt channels are unavailable")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"version_id={version}\nsha256={receipt['sha256']}\n"
                         f"kms_key_id={receipt['kms_key_id']}\n")
    if summary:
        rows = (("Bucket", BUCKET), ("Key", KEY), ("Source commit", COMMIT),
                ("Cancelled run", RUN_ID), ("Version ID", version),
                ("Artifact SHA-256", receipt["sha256"]),
                ("Before policy SHA-256", receipt["before_sha256"]),
                ("After policy SHA-256", receipt["after_sha256"]),
                ("KMS key", receipt["kms_key_id"]))
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("## Cancelled plan cleanup review receipt\n\n")
            for label, value in rows:
                handle.write(f"- {label}: <code>{html.escape(value)}</code>\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("inspect", "delete"))
    parser.add_argument("--expected-version")
    parser.add_argument("--expected-sha256")
    parser.add_argument("--expected-kms-key-id")
    parser.add_argument("--expected-main-sha")
    args = parser.parse_args()
    if args.mode == "delete" and (not args.expected_version or
                                  not HEX64.fullmatch(args.expected_sha256 or "") or
                                  not KMS_KEY.fullmatch(args.expected_kms_key_id or "") or
                                  not HEX40.fullmatch(args.expected_main_sha or "")):
        parser.error("delete requires the reviewed version, hashes, KMS key and main SHA")
    version, receipt = inspect()
    if args.mode == "inspect":
        write_receipt(version, receipt)
        print("Cancelled plan version and bytes verified; no change made")
        return
    if (version != args.expected_version or receipt["sha256"] != args.expected_sha256 or
            receipt["kms_key_id"] != args.expected_kms_key_id):
        raise RuntimeError("Cancelled plan changed after review; refusing deletion")
    verify_current_main(args.expected_main_sha)
    aws("delete-object", "--bucket", BUCKET, "--key", KEY, "--version-id", version)
    remaining = aws("list-object-versions", "--bucket", BUCKET, "--prefix", KEY)
    if any(item.get("Key") == KEY for name in ("Versions", "DeleteMarkers")
           for item in remaining.get(name, [])):
        raise RuntimeError("Cancelled plan still has a version or delete marker")
    print("Exact cancelled plan version removed and absence verified")


if __name__ == "__main__":
    main()
