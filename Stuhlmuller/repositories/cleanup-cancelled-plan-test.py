#!/usr/bin/env python3
"""Reject ambiguous or changed plan artifacts before versioned deletion."""

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("cleanup-cancelled-plan.py")
SPEC = importlib.util.spec_from_file_location("cleanup_cancelled_plan", SCRIPT)
cleanup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cleanup)


class CleanupTest(unittest.TestCase):
    def setUp(self):
        self.version = {"Key": cleanup.KEY, "VersionId": "version-1", "IsLatest": True}
        self.digest = "a" * 64
        self.kms = "arn:aws:kms:us-east-1:716182248480:key/11111111-2222-3333-4444-555555555555"
        self.receipt = {"sha256": self.digest, "before_sha256": "b" * 64,
                        "after_sha256": "c" * 64, "kms_key_id": self.kms}
        self.head = {
            "VersionId": "version-1", "ServerSideEncryption": "aws:kms",
            "SSEKMSKeyId": self.kms,
            "ContentLength": 64,
            "Metadata": {
                "commit": cleanup.COMMIT, "run-id": cleanup.RUN_ID,
                "sha256": self.digest, "before-sha256": "b" * 64,
                "after-sha256": "c" * 64,
            },
        }

    def test_exact_single_version_and_no_marker(self):
        self.assertEqual(cleanup.sole_version({"Versions": [self.version]}), "version-1")
        for inventory in (
            {},
            {"Versions": [self.version, self.version]},
            {"Versions": [dict(self.version, IsLatest=False)]},
            {"Versions": [self.version], "DeleteMarkers": [{"Key": cleanup.KEY}]},
            {"Versions": [dict(self.version, Key=cleanup.KEY + ".other")]},
            {"Versions": [dict(self.version, VersionId="null")]},
            {"Versions": [dict(self.version, VersionId="one\nsha256=forged")]},
        ):
            with self.subTest(inventory=inventory), self.assertRaises(RuntimeError):
                cleanup.sole_version(inventory)

    def test_metadata_and_encryption_must_match_exact_run(self):
        self.assertEqual(cleanup.validate_head(self.head, "version-1"), self.receipt)
        mutations = (
            {"VersionId": "version-2"}, {"ServerSideEncryption": "AES256"},
            {"ContentLength": 0},
            {"Metadata": dict(self.head["Metadata"], commit="other")},
            {"Metadata": dict(self.head["Metadata"], **{"run-id": "other"})},
            {"Metadata": dict(self.head["Metadata"], sha256="bad")},
            {"SSEKMSKeyId": "alias/unreviewed"},
        )
        for changed in mutations:
            with self.subTest(changed=changed), self.assertRaises(RuntimeError):
                cleanup.validate_head(dict(self.head, **changed), "version-1")

    def test_changed_reviewed_version_never_deletes(self):
        with mock.patch.object(cleanup, "inspect", return_value=("version-2", self.receipt)), \
             mock.patch.object(cleanup, "aws") as aws, \
             mock.patch("sys.argv", [str(SCRIPT), "delete", "--expected-version", "version-1",
                                     "--expected-sha256", self.digest,
                                     "--expected-kms-key-id", self.kms,
                                     "--expected-main-sha", cleanup.COMMIT]):
            with self.assertRaisesRegex(RuntimeError, "changed after review"):
                cleanup.main()
            aws.assert_not_called()

    def test_delete_targets_only_reviewed_version(self):
        with mock.patch.object(cleanup, "inspect", return_value=("version-1", self.receipt)), \
             mock.patch.object(cleanup, "verify_current_main") as verify, \
             mock.patch.object(cleanup, "aws", side_effect=[{}, {"Versions": []}]) as aws, \
             mock.patch("builtins.print"), \
             mock.patch("sys.argv", [str(SCRIPT), "delete", "--expected-version", "version-1",
                                     "--expected-sha256", self.digest,
                                     "--expected-kms-key-id", self.kms,
                                     "--expected-main-sha", cleanup.COMMIT]):
            cleanup.main()
            verify.assert_called_once_with(cleanup.COMMIT)
            self.assertEqual(aws.call_args_list[0], mock.call(
                "delete-object", "--bucket", cleanup.BUCKET, "--key", cleanup.KEY,
                "--version-id", "version-1"))

    def test_main_advance_after_inspection_blocks_delete(self):
        with mock.patch.object(cleanup, "inspect", return_value=("version-1", self.receipt)), \
             mock.patch.object(cleanup, "verify_current_main",
                               side_effect=RuntimeError("Current main advanced")), \
             mock.patch.object(cleanup, "aws") as aws, \
             mock.patch("sys.argv", [str(SCRIPT), "delete", "--expected-version", "version-1",
                                     "--expected-sha256", self.digest,
                                     "--expected-kms-key-id", self.kms,
                                     "--expected-main-sha", cleanup.COMMIT]):
            with self.assertRaisesRegex(RuntimeError, "Current main advanced"):
                cleanup.main()
            aws.assert_not_called()

    def test_receipt_identity_is_delete_input(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            summary = Path(directory) / "summary"
            with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true",
                                            "GITHUB_OUTPUT": str(output),
                                            "GITHUB_STEP_SUMMARY": str(summary)}):
                cleanup.write_receipt("version-1", self.receipt)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(values, {"version_id": "version-1", "sha256": self.digest,
                                      "kms_key_id": self.kms})
            for value in (cleanup.KEY, cleanup.COMMIT, cleanup.RUN_ID,
                          values["version_id"], values["sha256"], values["kms_key_id"]):
                self.assertIn(value, summary.read_text())

    def test_inspection_session_policy_has_no_delete_capability(self):
        workflow = Path(__file__).parents[2] / ".github/workflows/cleanup-cancelled-homelab-plan.yml"
        lines = workflow.read_text().splitlines()
        start = lines.index("          inline-session-policy: |") + 1
        policy_lines = []
        for line in lines[start:]:
            if line and not line.startswith("            "):
                break
            policy_lines.append(line[12:])
        policy = json.loads("\n".join(policy_lines))
        statements = policy["Statement"]
        actions = {action for statement in statements for action in
                   ([statement["Action"]] if isinstance(statement["Action"], str)
                    else statement["Action"])}
        self.assertEqual(actions, {"s3:ListBucketVersions", "s3:GetObjectVersion", "kms:Decrypt"})
        self.assertFalse(any("*" in action or "Delete" in action or "Put" in action
                             for action in actions))
        self.assertEqual(statements[0]["Condition"]["StringEquals"]["s3:prefix"], cleanup.KEY)
        self.assertEqual(statements[1]["Resource"],
                         f"arn:aws:s3:::{cleanup.BUCKET}/{cleanup.KEY}")

    def test_byte_hash_mismatch_never_passes_inspection(self):
        def fake_aws(*args):
            if args[0] == "list-object-versions":
                return {"Versions": [self.version]}
            if args[0] == "head-object":
                return self.head
            if args[0] == "get-object":
                Path(args[-1]).write_bytes(b"wrong bytes")
                return {}
            self.fail("unexpected AWS command")

        with mock.patch.object(cleanup, "aws", side_effect=fake_aws):
            with self.assertRaisesRegex(RuntimeError, "bytes do not match"):
                cleanup.inspect()


if __name__ == "__main__":
    unittest.main()
