#!/usr/bin/env python3
"""No-network tests for trusted CI resolution and cache preparation metadata."""
import argparse
import base64
from contextlib import redirect_stdout
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error

SPEC = importlib.util.spec_from_file_location("ci_prepare", Path(__file__).resolve().parents[1] / "ci-prepare.py")
prep = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prep)


def sample_identity(head="1" * 40, tree="2" * 40):
    result = {"schema": 1, "candidate_head": head, "candidate_tree": tree,
              "source_tree": "3" * 40, "build_roots": {}, "toolchain": prep.TOOLCHAIN,
              "lakefile_sha256": "4" * 64, "manifest_sha256": "5" * 64}
    result["input_fingerprint"] = prep.publication.fingerprint(result)
    return result


def record(identity):
    return {**identity, "repository": prep.REPO, "build_exit_code": 0,
            "map_sha256": "6" * 64, "map_key": "ci/maps/" + "6" * 64 + ".jsonl",
            "module_manifest_sha256": "7" * 64,
            "module_manifest_key": "ci/module-manifests/" + "7" * 64 + ".jsonl.gz"}


class PreparationTests(unittest.TestCase):
    def test_identity_uses_git_blobs_and_ignores_documentation_tree(self):
        files = {"lakefile.toml": b"config", "lake-manifest.json": b"manifest",
                 "lean-toolchain": prep.TOOLCHAIN.encode()}
        paths = {name: str(index) * 40 for index, name in enumerate(files, 4)}
        root_tree = [{"path": "src", "type": "tree", "mode": "040000", "sha": "3" * 40}]
        root_tree += [{"path": name, "type": "blob", "mode": "100644", "sha": sha} for name, sha in paths.items()]

        def api(path):
            if path.startswith("git/commits/"):
                return {"tree": {"sha": "2" * 40 if path.endswith("1" * 40) else "8" * 40}}
            if path.startswith("git/trees/"):
                return {"tree": root_tree}
            name = next(name for name, sha in paths.items() if path.endswith(sha))
            return {"content": base64.b64encode(files[name]).decode()}

        with patch.object(prep, "api", side_effect=api):
            first, second = prep.identity("1" * 40), prep.identity("9" * 40)
            self.assertEqual(first["input_fingerprint"], second["input_fingerprint"])
            self.assertNotEqual(first["candidate_tree"], second["candidate_tree"])
            self.assertEqual(first["lakefile_sha256"], prep.digest(b"config"))
            root_tree[1]["mode"] = "120000"
            with self.assertRaisesRegex(ValueError, "Unsafe"):
                prep.identity("1" * 40)

    def test_resolve_retries_async_mergeability_and_reuses_matching_build(self):
        head, base, merge = "a" * 40, "b" * 40, "c" * 40
        pending = {"head": {"sha": head}, "base": {"sha": base}, "mergeable": None, "merge_commit_sha": None}
        ready = {**pending, "mergeable": True, "merge_commit_sha": merge}
        identity = sample_identity(merge)
        reusable = record(sample_identity("d" * 40))
        responses = iter([pending, ready])

        def api(path):
            return next(responses) if path.startswith("pulls/") else {"parents": [{"sha": head}, {"sha": base}]}

        with tempfile.TemporaryDirectory() as directory, patch.object(prep, "api", side_effect=api), \
                patch.object(prep, "identity", return_value=identity), \
                patch.object(prep, "get", return_value=json.dumps(reusable).encode()), \
                patch.object(prep.time, "sleep") as sleep, redirect_stdout(io.StringIO()):
            output = Path(directory) / "request.json"
            prep.resolve(SimpleNamespace(pr=7, head=head, output=output))
            request = json.loads(output.read_text())
            self.assertEqual(request["reuse_from"], "d" * 40)
            self.assertEqual(request["expected"], identity)
            sleep.assert_called_once_with(2)

    def test_resolve_retry_is_bounded_and_rejects_moving_head(self):
        pending = {"head": {"sha": "a" * 40}, "base": {"sha": "b" * 40}, "mergeable": None}
        args = SimpleNamespace(pr=7, head="a" * 40, output="unused")
        with patch.object(prep, "api", return_value=pending) as api, patch.object(prep.time, "sleep") as sleep:
            with self.assertRaisesRegex(ValueError, "retry this job"):
                prep.resolve(args)
            self.assertEqual(api.call_count, 5)
            self.assertEqual(sleep.call_count, 4)
        changed = {**pending, "head": {"sha": "d" * 40}}
        with patch.object(prep, "api", side_effect=[pending, changed]), patch.object(prep.time, "sleep"):
            with self.assertRaisesRegex(ValueError, "head changed"):
                prep.resolve(args)

    def test_manual_resolve_accepts_merged_pr_but_still_checks_head_parent(self):
        head, merge = "a" * 40, "c" * 40
        merged = {"head": {"sha": head}, "base": {"sha": merge}, "mergeable": None,
                  "merged": True, "merge_commit_sha": merge}
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(prep, "identity", return_value=sample_identity(merge)), \
                patch.object(prep, "get", return_value=None), patch.object(prep.time, "sleep") as sleep, \
                patch.object(prep, "api", side_effect=[merged, {"parents": [{"sha": head}]}]), redirect_stdout(io.StringIO()):
            prep.resolve(SimpleNamespace(pr=13, head=None, output=Path(directory) / "request.json"))
            sleep.assert_not_called()

    def test_public_records_require_bound_identity_and_content_addresses(self):
        valid = record(sample_identity())
        prep.validate_record(valid)
        for change in ({"map_key": "ci/maps/" + "8" * 64 + ".jsonl"},
                       {"input_fingerprint": "9" * 64}, {"repository": "elsewhere/repo"}):
            with self.assertRaises(ValueError):
                prep.validate_record({**valid, **change})

    def test_manifest_is_bounded_and_binds_exact_modules_to_map(self):
        identity = sample_identity()
        data = b'"2026-03-17"\n["1111111111111111","2222222222222222.ltar"]\n'
        entries = prep.mapping(data)
        header = {key: identity[key] for key in prep.publication.FINGERPRINT}
        header.update(schema=1, modules=1, map_sha256=prep.digest(data), input_fingerprint=identity["input_fingerprint"])
        row = ["Module", "1" * 16, "2" * 16 + ".ltar", "3" * 64]
        encode = lambda h, r: gzip.compress((json.dumps(h) + "\n" + json.dumps(r) + "\n").encode(), mtime=0)
        self.assertEqual(prep.manifest_hashes(encode(header, row), entries, data, identity), {row[2]: row[3]})
        with self.assertRaises(ValueError):
            prep.manifest_hashes(encode({**header, "map_sha256": "0" * 64}, row), entries, data, identity)
        with self.assertRaises(ValueError):
            prep.manifest_hashes(encode(header, ["../outside", *row[1:]]), entries, data, identity)

    def test_downloads_verify_existing_files_and_atomically_replace_partial_cache(self):
        with tempfile.TemporaryDirectory(prefix='rh-prep-"quoted-') as directory:
            cache = Path(directory)
            artifacts = cache / "artifacts"
            artifacts.mkdir()
            name, payload = "1" * 16 + ".ltar", b"completed fixture"
            artifact = artifacts / name
            artifact.write_bytes(b"partial")

            def curl(command, **kwargs):
                self.assertNotIn("AWS_SECRET_ACCESS_KEY", kwargs["env"])
                self.assertNotIn("GH_TOKEN", kwargs["env"])
                config = Path(command[-1]).read_text().splitlines()
                outputs = [json.loads(line.removeprefix("output = ")) for line in config if line.startswith("output = ")]
                self.assertEqual(len(outputs), 1)
                Path(outputs[0]).write_bytes(payload)

            with patch.dict(os.environ, {"AWS_SECRET_ACCESS_KEY": "test-only", "GH_TOKEN": "test-only"}), \
                    patch.object(prep.subprocess, "run", side_effect=curl) as downloader:
                prep.downloads(cache, {"a" * 16: name}, {name: prep.digest(payload)})
                self.assertEqual(artifact.read_bytes(), payload)
                prep.downloads(cache, {"a" * 16: name}, {name: prep.digest(payload)})
                self.assertEqual(downloader.call_count, 1)
            with self.assertRaises(ValueError):
                prep.downloads(cache, {"a" * 16: name}, {})


if __name__ == "__main__":
    unittest.main()
