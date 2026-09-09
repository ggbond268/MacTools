from __future__ import annotations

import copy
from email.message import Message
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("gitee_release", ROOT / "scripts/sync-gitee-release.py")
mirror = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mirror)


def asset(name="Demo.mactoolsplugin.zip", data=b"signed archive", asset_id=1):
    return {"id": asset_id, "name": name, "size": len(data), "state": "uploaded",
            "digest": "sha256:" + hashlib.sha256(data).hexdigest()}


def source_release(assets=None):
    return {"id": 50, "tag_name": "plugins-1.3.0", "name": "MacTools Plugins 1.3.0",
            "body": "Release notes\n\n- Preserve literal `$(text)` and Unicode: 插件.\n",
            "prerelease": False, "draft": False, "assets": assets or []}


def workflow_event(name="Plugin Release", trigger="push"):
    path = "plugin-release.yml" if name == "Plugin Release" else "release.yml"
    return {"repository": {"full_name": "owner/repo"}, "workflow_run": {
        "id": 123, "run_attempt": 2, "name": name, "path": f".github/workflows/{path}",
        "status": "completed", "conclusion": "success", "event": trigger,
        "head_repository": {"full_name": "owner/repo"}, "head_branch": "main",
    }}


class Response(io.BytesIO):
    def __init__(self, data: bytes, content_type="application/octet-stream"):
        super().__init__(data)
        self.headers = Message()
        self.headers["Content-Type"] = content_type


class FakeGitee:
    def __init__(self):
        self.items = []
        self.payloads = {}
        self.calls = []
        self.next_id = 1
        self.fail_upload_once = False
        self.download_error = None
        self.corrupt_upload = False

    def add(self, name, data):
        self.items.append({"id": self.next_id, "name": name, "size": len(data)})
        self.payloads[self.next_id] = data
        self.next_id += 1

    def attachments(self, release_id):
        return copy.deepcopy(self.items)

    def matches(self, tag, path):
        if self.download_error:
            raise self.download_error
        items = [item for item in self.items if item["name"] == path.name]
        return len(items) == 1 and self.payloads[items[0]["id"]] == path.read_bytes()

    def upload(self, release_id, path):
        self.calls.append(("UPLOAD", path.name))
        self.add(path.name, b"corrupt" if self.corrupt_upload else path.read_bytes())
        if self.fail_upload_once:
            self.fail_upload_once = False
            raise mirror.MirrorError("Connection closed after the upload was stored.")

    def request(self, method, path, **kwargs):
        self.calls.append((method, path))
        if method == "DELETE":
            item_id = int(path.rsplit("/", 1)[1])
            self.items = [item for item in self.items if item["id"] != item_id]
            self.payloads.pop(item_id)


class GiteeReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.path = self.root / "Demo.mactoolsplugin.zip"
        self.path.write_bytes(b"signed archive")

    def test_github_asset_inventory_fetches_every_page(self):
        first = [asset(f"plugin-{index}.zip", asset_id=index) for index in range(100)]
        last = [asset("last.zip", asset_id=100)]
        with mock.patch.object(mirror, "github", side_effect=[source_release(), first, last]) as api:
            result = mirror.github_release("owner/repo", "plugins-1.3.0")
        self.assertEqual(len(result["assets"]), 101)
        self.assertIn("page=2", api.call_args.args[0])

    def test_rejects_drafts_and_wrong_tags_before_downloading(self):
        for change in [{"draft": True}, {"tag_name": "plugins-other"}]:
            source = dict(source_release(), **change)
            with self.subTest(change=change), mock.patch.object(mirror, "github", return_value=source) as api:
                with self.assertRaises(mirror.MirrorError):
                    mirror.github_release("owner/repo", "plugins-1.3.0")
                self.assertEqual(api.call_count, 1)

    def test_rejects_oversized_incomplete_unsafe_and_duplicate_assets(self):
        cases = [[dict(asset(), size=100_000_001)], [dict(asset(), state="new")],
                 [asset("../escape.zip")], [asset("--option")], [asset("a\n.zip")],
                 [asset(), asset()], [dict(asset(), size=-1)], [dict(asset(), size=True)]]
        for assets in cases:
            with self.subTest(assets=assets), self.assertRaises(mirror.MirrorError):
                mirror.validate_assets(assets)
        with self.assertRaisesRegex(mirror.MirrorError, "1 GB"):
            mirror.validate_assets([dict(asset(f"p-{i}.zip"), size=100_000_000) for i in range(11)])

    def test_source_download_checks_sha256_without_exposing_gitee_token_to_gh(self):
        source = source_release([asset(data=b"other payload!")])
        with mock.patch.object(mirror, "command") as run, mock.patch.dict(mirror.os.environ, GITEE_TOKEN="secret"):
            with self.assertRaisesRegex(mirror.MirrorError, "SHA-256"):
                mirror.download_github_assets("owner/repo", source, self.root)
        self.assertNotIn("GITEE_TOKEN", run.call_args.kwargs["env"])

    def test_source_download_rejects_symlinks(self):
        self.path.unlink()
        actual = self.root / "actual"
        actual.write_bytes(b"signed archive")
        self.path.symlink_to(actual)
        with mock.patch.object(mirror, "command"), self.assertRaisesRegex(mirror.MirrorError, "size/type"):
            mirror.download_github_assets("owner/repo", source_release([asset()]), self.root)

    def test_mirrors_identical_bytes_and_rerun_does_not_upload_twice(self):
        client = FakeGitee()
        for _ in range(2):
            mirror.mirror_assets(client, 10, "plugins-1.3.0", {self.path.name: self.path})
        self.assertEqual(client.calls, [("UPLOAD", self.path.name)])
        self.assertEqual(next(iter(client.payloads.values())), self.path.read_bytes())

    def test_replaces_changed_asset_and_removes_only_extra_assets_in_this_release(self):
        client = FakeGitee()
        client.add(self.path.name, b"old bytes")
        client.add("old.zip", b"old")
        mirror.mirror_assets(client, 10, "plugins-1.3.0", {self.path.name: self.path})
        self.assertEqual(client.calls, [("DELETE", "/releases/10/attach_files/1"),
                                       ("UPLOAD", self.path.name), ("DELETE", "/releases/10/attach_files/2")])
        self.assertEqual([a["name"] for a in client.items], [self.path.name])

    def test_reconciles_duplicate_names_from_an_earlier_partial_sync(self):
        client = FakeGitee()
        client.add(self.path.name, self.path.read_bytes())
        client.add(self.path.name, b"old")
        mirror.mirror_assets(client, 10, "plugins-1.3.0", {self.path.name: self.path})
        self.assertEqual(len(client.items), 1)
        self.assertTrue(client.matches("plugins-1.3.0", self.path))

    def test_retry_after_uncertain_upload_reuses_the_stored_asset(self):
        client = FakeGitee()
        client.fail_upload_once = True
        with self.assertRaises(mirror.MirrorError):
            mirror.mirror_assets(client, 10, "plugins-1.3.0", {self.path.name: self.path})
        mirror.mirror_assets(client, 10, "plugins-1.3.0", {self.path.name: self.path})
        self.assertEqual(client.calls, [("UPLOAD", self.path.name)])

    def test_download_failure_does_not_delete_existing_assets(self):
        client = FakeGitee()
        client.add(self.path.name, self.path.read_bytes())
        client.download_error = mirror.MirrorError("Captcha")
        with self.assertRaises(mirror.MirrorError):
            mirror.mirror_assets(client, 10, "plugins-1.3.0", {self.path.name: self.path})
        self.assertEqual(client.calls, [])

    def test_corrupt_upload_stops_before_removing_other_assets(self):
        client = FakeGitee()
        client.add("old.zip", b"keep until verified")
        client.corrupt_upload = True
        with self.assertRaisesRegex(mirror.MirrorError, "SHA-256"):
            mirror.mirror_assets(client, 10, "plugins-1.3.0", {self.path.name: self.path})
        self.assertIn("old.zip", [a["name"] for a in client.items])

    def test_catalog_only_release_can_have_no_attachments(self):
        mirror.mirror_assets(FakeGitee(), 10, "plugins-1.3.0", {})

    def test_attachment_listing_is_paginated(self):
        client = mirror.Gitee("owner/repo", "secret")
        with mock.patch.object(client, "request", side_effect=[[{"id": i} for i in range(100)], [{"id": 101}]]) as api:
            self.assertEqual(len(client.attachments(10)), 101)
        self.assertIn("page=2", api.call_args.args[1])

    def test_multipart_upload_preserves_filename_and_bytes(self):
        client = mirror.Gitee("owner/repo", "secret")
        def request(method, path, *, data, headers):
            body = data.read()
            self.assertEqual(method, "POST")
            self.assertEqual(path, "/releases/10/attach_files")
            self.assertEqual(int(headers["Content-Length"]), len(body))
            self.assertIn(f'filename="{self.path.name}"'.encode(), body)
            self.assertIn(b"\r\n\r\nsigned archive\r\n", body)
        with mock.patch.object(client, "request", side_effect=request):
            client.upload(10, self.path)

    def test_api_uses_bearer_header_and_does_not_retry_uncertain_post(self):
        client = mirror.Gitee("owner/repo", "secret")
        with mock.patch.object(client.api, "open", side_effect=TimeoutError("secret")) as send:
            with self.assertRaisesRegex(mirror.MirrorError, "rerun") as error:
                client.request("POST", "/releases", payload={"body": "line 1\nline 2"})
        self.assertNotIn("secret", str(error.exception))
        self.assertEqual(send.call_count, 1)
        request = send.call_args.args[0]
        self.assertEqual(request.get_header("Authorization"), "Bearer secret")
        self.assertNotIn("secret", request.full_url)
        self.assertEqual(json.loads(request.data), {"body": "line 1\nline 2"})

    def test_api_retries_transient_reads_but_not_authentication_errors(self):
        client = mirror.Gitee("owner/repo", "secret")
        error = urllib.error.HTTPError("https://gitee.com", 503, "error", {}, io.BytesIO())
        with mock.patch.object(client.api, "open", side_effect=[error, Response(b'{}')]) as send, mock.patch.object(mirror.time, "sleep"):
            self.assertEqual(client.request("GET", ""), {})
            self.assertEqual(send.call_count, 2)
        error = urllib.error.HTTPError("https://gitee.com", 403, "error", {}, io.BytesIO())
        with mock.patch.object(client.api, "open", side_effect=error) as send:
            with self.assertRaisesRegex(mirror.APIError, "permissions.*quota"):
                client.request("GET", "")
            self.assertEqual(send.call_count, 1)

    def test_public_download_has_no_credentials_and_checks_the_complete_file(self):
        client = mirror.Gitee("owner/repo", "secret")
        with mock.patch.object(client.downloads, "open", return_value=Response(self.path.read_bytes())) as send:
            self.assertTrue(client.matches("plugins-1.3.0", self.path))
        request = send.call_args.args[0]
        self.assertIsNone(request.get_header("Authorization"))
        self.assertIsNone(request.get_header("Cookie"))
        self.assertNotIn("secret", request.full_url)

    def test_public_download_rejects_captcha_html_and_bad_bytes(self):
        client = mirror.Gitee("owner/repo", "secret")
        with mock.patch.object(client.downloads, "open", return_value=Response(b"captcha", "text/html")):
            with self.assertRaisesRegex(mirror.MirrorError, "HTML"):
                client.matches("plugins-1.3.0", self.path)
        for body in [b"bad", b"x" * 100, b"unsigned bytes"]:
            with mock.patch.object(client.downloads, "open", return_value=Response(body)):
                self.assertFalse(client.matches("plugins-1.3.0", self.path))

    def test_api_redirects_are_disabled_and_downloads_cannot_downgrade_to_http(self):
        request = urllib.request.Request("https://gitee.com/api/v5", headers={"Authorization": "Bearer secret"})
        self.assertIsNone(mirror.NoRedirect().redirect_request(request, None, 302, "", {}, "https://other.example"))
        for url in ["http://other.example/file", "https://user:password@other.example/file"]:
            with self.assertRaises(mirror.MirrorError):
                mirror.HTTPSRedirect().redirect_request(request, None, 302, "", {}, url)

    def test_missing_gitee_release_target_stops_before_downloads_or_mutations(self):
        for existing in [None, {"id": 10}]:
            with self.subTest(existing=existing):
                client = mock.Mock()
                client.request.return_value = {"private": False}
                client.release.return_value = existing
                with mock.patch.object(mirror, "github_release", return_value=source_release()), mock.patch.object(
                    mirror, "Gitee", return_value=client
                ), mock.patch.object(mirror, "download_github_assets") as download:
                    with self.assertRaisesRegex(mirror.MirrorError, "initialized default branch"):
                        mirror.mirror("owner/repo", "plugins-1.3.0", "secret")
                    download.assert_not_called()
                client.request.assert_called_once_with("GET", "")

    def test_release_drift_check_ignores_download_counts_but_detects_replaced_assets(self):
        source = source_release([asset()])
        latest = copy.deepcopy(source)
        latest["assets"][0]["download_count"] = 100
        self.assertEqual(mirror.release_fingerprint(source), mirror.release_fingerprint(latest))
        latest["assets"][0]["id"] = 99
        self.assertNotEqual(mirror.release_fingerprint(source), mirror.release_fingerprint(latest))

    def test_release_uses_gitee_branch_and_preserves_its_target_on_retry_without_git(self):
        source = dict(source_release(), prerelease=True, target_commitish="a" * 40)
        commit = "b" * 40
        for existing in [None, {"id": 10, "target_commitish": commit}]:
            with self.subTest(existing=existing):
                client = mock.Mock()
                stored = dict(existing or {})
                target = {"private": False, "default_branch": "main"}
                client.release.side_effect = lambda tag: dict(stored) if stored else None
                def request(method, path, **kwargs):
                    if method == "GET" and path == "":
                        return target
                    stored.update(kwargs["payload"], id=10)
                    if method == "POST":
                        stored["target_commitish"] = commit
                    return dict(stored)
                client.request.side_effect = request
                with mock.patch.object(mirror, "github_release", return_value=source), mock.patch.object(
                    mirror, "Gitee", return_value=client
                ), mock.patch.object(mirror, "download_github_assets", return_value={}), mock.patch.object(
                    mirror, "command"
                ) as run, mock.patch.object(mirror, "mirror_assets"):
                    mirror.mirror("owner/repo", source["tag_name"], "secret")
                    first_body = stored["body"]
                    target["default_branch"] = "new-default-branch"
                    mirror.mirror("owner/repo", source["tag_name"], "secret")
                    run.assert_not_called()
                self.assertEqual(stored["tag_name"], source["tag_name"])
                self.assertEqual(stored["name"], source["name"])
                self.assertTrue(stored["prerelease"])
                self.assertEqual(stored["target_commitish"], commit)
                self.assertEqual(stored["body"], first_body)
                self.assertTrue(stored["body"].endswith(source["body"]))
                self.assertIn("https://github.com/owner/repo/tree/plugins-1.3.0", stored["body"])
                self.assertIn("https://github.com/owner/repo/releases/tag/plugins-1.3.0", stored["body"])
                self.assertIn("instead of Gitee's automatically generated source archives", stored["body"])
                creates = [call for call in client.request.call_args_list if call.args[0] == "POST"]
                self.assertEqual(len(creates), 1 if existing is None else 0)
                if creates:
                    self.assertEqual(creates[0].kwargs["payload"]["target_commitish"], "main")
                updates = [call for call in client.request.call_args_list if call.args[0] == "PATCH"]
                self.assertEqual(len(updates), 2)
                for update in updates:
                    self.assertEqual(update.kwargs["payload"]["target_commitish"], commit)

    def test_created_release_without_resolved_target_stops_before_asset_uploads(self):
        client = mock.Mock()
        client.request.side_effect = [{"private": False, "default_branch": "main"}, {"id": 10}]
        client.release.return_value = None
        with mock.patch.object(mirror, "github_release", return_value=source_release()), mock.patch.object(
            mirror, "Gitee", return_value=client
        ), mock.patch.object(mirror, "download_github_assets", return_value={}), mock.patch.object(
            mirror, "mirror_assets"
        ) as upload:
            with self.assertRaisesRegex(mirror.MirrorError, "did not return the release target"):
                mirror.mirror("owner/repo", "plugins-1.3.0", "secret")
            upload.assert_not_called()

    def test_failed_asset_sync_does_not_claim_updated_release_metadata(self):
        client = mock.Mock()
        client.request.return_value = {"private": False}
        client.release.return_value = {"id": 10, "target_commitish": "b" * 40}
        with mock.patch.object(mirror, "github_release", return_value=source_release()), mock.patch.object(
            mirror, "Gitee", return_value=client
        ), mock.patch.object(mirror, "download_github_assets", return_value={}), mock.patch.object(
            mirror, "mirror_assets", side_effect=mirror.MirrorError("quota")
        ):
            with self.assertRaisesRegex(mirror.MirrorError, "quota"):
                mirror.mirror("owner/repo", "plugins-1.3.0", "secret")
        self.assertFalse(any(call.args[0] == "PATCH" for call in client.request.call_args_list))

    def test_private_mirror_is_rejected_before_downloads_or_mutations(self):
        client = mock.Mock()
        client.request.return_value = {"private": True}
        with mock.patch.object(mirror, "github_release", return_value=source_release()), mock.patch.object(
            mirror, "Gitee", return_value=client
        ), mock.patch.object(mirror, "download_github_assets") as download:
            with self.assertRaisesRegex(mirror.MirrorError, "public"):
                mirror.mirror("owner/repo", "plugins-1.3.0", "secret")
            download.assert_not_called()
        client.request.assert_called_once_with("GET", "")

    def test_cli_rejects_nightly_tags_and_missing_credentials(self):
        for tag in ["nightly-1-1", "v1.3.0"]:
            with mock.patch("sys.argv", ["sync", "--github-repo", "owner/repo", "--tag", tag]), mock.patch.dict(
                mirror.os.environ, {}, clear=True
            ), mock.patch.object(mirror, "mirror") as publish, mock.patch("sys.stderr", new_callable=io.StringIO):
                self.assertEqual(mirror.main(), 1)
                publish.assert_not_called()

    def test_resolves_the_published_tag_instead_of_the_workflow_dispatch_branch(self):
        for name, tag in [("Release", "v1.3.0"), ("Plugin Release", "plugins-1.3.0")]:
            for trigger in ["push", "workflow_dispatch"]:
                with self.subTest(name=name, trigger=trigger), mock.patch.object(
                    mirror, "github", return_value={"artifacts": [{"name": f"MacTools-{tag}"}]}
                ) as api:
                    self.assertEqual(mirror.workflow_release_tag("owner/repo", workflow_event(name, trigger)), tag)
                    api.assert_called_once_with("repos/owner/repo/actions/runs/123/artifacts?per_page=100&page=1")

    def test_source_artifact_metadata_is_paginated_and_does_not_download_expired_files(self):
        batches = [{"artifacts": [{"name": f"unrelated-{i}"} for i in range(100)]},
                   {"artifacts": [{"name": "MacTools-plugins-1.3.0", "expired": True}]}]
        with mock.patch.object(mirror, "github", side_effect=batches) as api:
            self.assertEqual(mirror.workflow_release_tag("owner/repo", workflow_event()), "plugins-1.3.0")
        self.assertEqual(api.call_count, 2)
        self.assertIn("page=2", api.call_args.args[0])

    def test_ambiguous_release_artifacts_require_an_explicit_manual_tag(self):
        with mock.patch.object(mirror, "github", return_value={"artifacts": [
            {"name": "MacTools-v1.2.0"}, {"name": "MacTools-v1.3.0"},
        ]}), self.assertRaisesRegex(mirror.MirrorError, "multiple release tags"):
            mirror.workflow_release_tag("owner/repo", workflow_event("Release"))

    def test_plugin_noop_is_confirmed_from_the_exact_source_attempt(self):
        batches = [{"artifacts": []}, {"jobs": [{
            "name": "Build, sign, and release plugins", "conclusion": "success",
            "steps": [{"name": "Create or update plugin GitHub Release", "conclusion": "skipped"}],
        }]}]
        with mock.patch.object(mirror, "github", side_effect=batches) as api:
            self.assertIsNone(mirror.workflow_release_tag("owner/repo", workflow_event()))
        self.assertEqual(api.call_args.args[0], "repos/owner/repo/actions/runs/123/attempts/2/jobs?per_page=100&page=1")

    def test_missing_artifacts_do_not_silently_skip_a_published_plugin_release(self):
        batches = [{"artifacts": []}, {"jobs": [{
            "name": "Build, sign, and release plugins", "conclusion": "success",
            "steps": [{"name": "Create or update plugin GitHub Release", "conclusion": "success"}],
        }]}]
        with mock.patch.object(mirror, "github", side_effect=batches), self.assertRaisesRegex(
            mirror.MirrorError, "missing or expired"
        ):
            mirror.workflow_release_tag("owner/repo", workflow_event())

    def test_app_resolution_never_uses_unrelated_or_malformed_artifacts(self):
        for name in ["MacTools-plugins-1.3.0", "MacTools-Nightly-1.2", "MacTools-v1.3.0\nmalformed=true", "MacTools-Debug"]:
            with self.subTest(name=name), mock.patch.object(mirror, "github", return_value={
                "artifacts": [{"name": name}],
            }), self.assertRaisesRegex(mirror.MirrorError, "missing or expired"):
                mirror.workflow_release_tag("owner/repo", workflow_event("Release"))

    def test_untrusted_or_unsuccessful_source_runs_are_rejected_before_api_access(self):
        changes = [{"conclusion": "failure"}, {"conclusion": "cancelled"}, {"status": "in_progress"},
                   {"name": "Nightly"}, {"path": ".github/workflows/other.yml"}, {"event": "pull_request"},
                   {"head_repository": {"full_name": "other/repo"}}, {"head_repository": None},
                   {"id": True}, {"id": -1}, {"run_attempt": 0}]
        for change in changes:
            event = workflow_event()
            event["workflow_run"].update(change)
            with self.subTest(change=change), mock.patch.object(mirror, "github") as api:
                with self.assertRaises(mirror.MirrorError):
                    mirror.workflow_release_tag("owner/repo", event)
                api.assert_not_called()
        with mock.patch.object(mirror, "github") as api, self.assertRaises(mirror.MirrorError):
            mirror.workflow_release_tag("other/repo", workflow_event())
        api.assert_not_called()

    def test_cli_resolves_source_runs_without_gitee_credentials_or_publication(self):
        event_path, output = self.root / "event.json", self.root / "output"
        event_path.write_text(json.dumps(workflow_event()))
        for tag in ["plugins-1.3.0", None]:
            output.write_text("")
            args = ["sync", "--github-repo", "owner/repo", "--workflow-run-event", str(event_path), "--github-output", str(output)]
            with mock.patch("sys.argv", args), mock.patch.dict(mirror.os.environ, {}, clear=True), mock.patch.object(
                mirror, "workflow_release_tag", return_value=tag
            ), mock.patch.object(mirror, "mirror") as publish:
                self.assertEqual(mirror.main(), 0)
                publish.assert_not_called()
            self.assertEqual(output.read_text(), f"tag={tag or ''}\n")

    def test_gitee_failure_cannot_change_publisher_or_pages_workflow_conclusions(self):
        app = (ROOT / ".github/workflows/release.yml").read_text()
        plugin = (ROOT / ".github/workflows/plugin-release.yml").read_text()
        shared = (ROOT / ".github/workflows/gitee-release.yml").read_text()
        pages = (ROOT / ".github/workflows/pages.yml").read_text()
        for workflow in [app, plugin]:
            self.assertNotIn("gitee", workflow.lower())
            self.assertIn("name: MacTools-${{ env.TAG }}", workflow)
        self.assertNotIn("Gitee Release", pages)
        self.assertIn("github.event.workflow_run.conclusion == 'success'", pages)
        self.assertIn("workflow_run:\n    workflows:\n      - Release\n      - Plugin Release\n", shared)
        self.assertIn("github.event.workflow_run.conclusion == 'success'", shared)
        self.assertNotIn("workflow_call:", shared)
        self.assertNotIn("continue-on-error", shared)
        self.assertIn("needs.resolve.outputs.tag", shared)
        self.assertIn("actions: read", shared)
        self.assertEqual(shared.count("GITEE_TOKEN:"), 1)
        self.assertIn("ref: ${{ github.event.repository.default_branch }}", shared)
        self.assertIn("workflow_dispatch:", shared)
        self.assertIn("persist-credentials: false", shared)
        self.assertNotIn("fetch-depth: 0", shared)
        self.assertIn("contents: read", shared)
        self.assertNotIn("secrets: inherit", shared)
        self.assertNotIn("gitee-release.yml", (ROOT / ".github/workflows/nightly.yml").read_text())


if __name__ == "__main__":
    unittest.main()
