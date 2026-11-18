#!/usr/bin/env python3
"""Reject ambiguous or changed plan artifacts before versioned deletion."""

import importlib.util
from pathlib import Path
import sys
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
        self.head = {
            "VersionId": "version-1", "ServerSideEncryption": "aws:kms",
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
        self.assertEqual(cleanup.validate_head(self.head, "version-1"), self.digest)
        mutations = (
            {"VersionId": "version-2"}, {"ServerSideEncryption": "AES256"},
            {"ContentLength": 0},
            {"Metadata": dict(self.head["Metadata"], commit="other")},
            {"Metadata": dict(self.head["Metadata"], **{"run-id": "other"})},
            {"Metadata": dict(self.head["Metadata"], sha256="bad")},
        )
        for changed in mutations:
            with self.subTest(changed=changed), self.assertRaises(RuntimeError):
                cleanup.validate_head(dict(self.head, **changed), "version-1")

    def test_changed_reviewed_version_never_deletes(self):
        with mock.patch.object(cleanup, "inspect", return_value=("version-2", self.digest)), \
             mock.patch.object(cleanup, "aws") as aws, \
             mock.patch("sys.argv", [str(SCRIPT), "delete", "--expected-version", "version-1",
                                     "--expected-sha256", self.digest]):
            with self.assertRaisesRegex(RuntimeError, "changed after review"):
                cleanup.main()
            aws.assert_not_called()

    def test_delete_targets_only_reviewed_version(self):
        with mock.patch.object(cleanup, "inspect", return_value=("version-1", self.digest)), \
             mock.patch.object(cleanup, "aws", side_effect=[{}, {"Versions": []}]) as aws, \
             mock.patch("sys.argv", [str(SCRIPT), "delete", "--expected-version", "version-1",
                                     "--expected-sha256", self.digest]):
            cleanup.main()
            self.assertEqual(aws.call_args_list[0], mock.call(
                "delete-object", "--bucket", cleanup.BUCKET, "--key", cleanup.KEY,
                "--version-id", "version-1"))

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
