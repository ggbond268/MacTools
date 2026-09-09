#!/usr/bin/env python3
"""Mirror one published app/plugin release from GitHub to Gitee."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


GITEE_REPOSITORY = "ggbond2700/MacTools"
MAX_ASSET_BYTES = 100_000_000
MAX_RELEASE_BYTES = 1_000_000_000
RETRYABLE_STATUSES = {429, 500, 502, 503, 504}


class MirrorError(RuntimeError):
    pass


class APIError(MirrorError):
    def __init__(self, status: int, method: str, path: str):
        self.status = status
        hint = " Check token permissions and repository attachment quota." if status in {401, 403, 413} else ""
        super().__init__(f"Gitee {method} {path} returned HTTP {status}.{hint}")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        # API requests carry the PAT and must never redirect to an asset host.
        return None


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlsplit(newurl)
        if parsed.scheme != "https" or parsed.username or parsed.password:
            raise MirrorError("Refusing an unsafe asset download redirect.")
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def command(args: list[str], *, env=None) -> str:
    try:
        result = subprocess.run(args, env=env, capture_output=True, text=True, check=False, timeout=600)
    except subprocess.TimeoutExpired:
        raise MirrorError(f"{args[0]} timed out; rerun to reconcile remote state.") from None
    if result.returncode:
        # HTTP diagnostics may contain credentials or signed download URLs.
        raise MirrorError(f"{args[0]} {args[1]} failed (exit {result.returncode}).")
    return result.stdout.strip()


def github(path: str):
    env = dict(os.environ)
    env.pop("GITEE_TOKEN", None)
    return json.loads(command(["gh", "api", "--method", "GET", path], env=env))


def valid_tag(tag: str) -> bool:
    return bool(re.fullmatch(r"(?:v\d+\.\d+\.\d+(?:[.-][0-9A-Za-z.-]+)?|plugins-[0-9A-Za-z][0-9A-Za-z._-]*)", tag))


def github_items(path: str, field: str) -> list[dict]:
    items = []
    page = 1
    while True:
        batch = github(f"{path}?per_page=100&page={page}")[field]
        items.extend(batch)
        if len(batch) < 100:
            return items
        page += 1


def workflow_release_tag(repository: str, event: dict) -> str | None:
    run = event.get("workflow_run", {})
    workflows = {
        "Release": (".github/workflows/release.yml", "v"),
        "Plugin Release": (".github/workflows/plugin-release.yml", "plugins-"),
    }
    expected = workflows.get(run.get("name"))
    if (expected is None or run.get("path") != expected[0]
            or run.get("status") != "completed" or run.get("conclusion") != "success"
            or run.get("event") not in {"push", "workflow_dispatch"}
            or event.get("repository", {}).get("full_name") != repository
            or (run.get("head_repository") or {}).get("full_name") != repository):
        raise MirrorError("Only successful app/plugin release runs from this repository can trigger a mirror.")
    run_id, attempt = run.get("id"), run.get("run_attempt")
    if type(run_id) is not int or run_id <= 0 or type(attempt) is not int or attempt <= 0:
        raise MirrorError("The source workflow run has an invalid ID or attempt.")
    # Both publishers already upload MacTools-<tag>. No new step can block publication.
    artifacts = github_items(f"repos/{repository}/actions/runs/{run_id}/artifacts", "artifacts")
    tags = set()
    for artifact in artifacts:
        name = artifact.get("name", "")
        if name.startswith("MacTools-"):
            tag = name.removeprefix("MacTools-")
            if tag.startswith(expected[1]) and valid_tag(tag):
                tags.add(tag)
    if len(tags) == 1:
        return tags.pop()
    if len(tags) > 1:
        raise MirrorError("The source run contains multiple release tags; use a manual Gitee Release run.")
    if run["name"] == "Plugin Release":
        # An unchanged plugin batch succeeds without publishing or uploading an artifact.
        # Check the exact attempt so expired metadata is not mistaken for a no-op release.
        jobs = github_items(f"repos/{repository}/actions/runs/{run_id}/attempts/{attempt}/jobs", "jobs")
        results = [step.get("conclusion") for job in jobs
                   if job.get("name") == "Build, sign, and release plugins" and job.get("conclusion") == "success"
                   for step in job.get("steps", []) if step.get("name") == "Create or update plugin GitHub Release"]
        if results == ["skipped"]:
            return None
    raise MirrorError("The source run's release artifact metadata is missing or expired; run Gitee Release manually with its tag.")


def github_release(repository: str, tag: str) -> dict:
    release = github(f"repos/{repository}/releases/tags/{urllib.parse.quote(tag, safe='')}")
    if release.get("draft") or release.get("tag_name") != tag:
        raise MirrorError("Only a published GitHub Release with the requested tag can be mirrored.")
    assets = []
    page = 1
    while True:
        batch = github(f"repos/{repository}/releases/{release['id']}/assets?per_page=100&page={page}")
        assets.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    release["assets"] = assets
    validate_assets(assets)
    return release


def validate_assets(assets: list[dict]) -> None:
    names = set()
    total = 0
    for asset in assets:
        name = asset["name"]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", name) or name in names:
            raise MirrorError(f"Unsupported or duplicate GitHub asset filename: {name!r}")
        names.add(name)
        size = asset.get("size")
        if type(size) is not int or not 0 <= size <= MAX_ASSET_BYTES:
            raise MirrorError(f"Asset {name} exceeds Gitee's ordinary 100 MB attachment limit.")
        if asset.get("state") != "uploaded":
            raise MirrorError(f"GitHub asset {name} is not fully uploaded.")
        total += size
    if total > MAX_RELEASE_BYTES:
        raise MirrorError("This release exceeds Gitee's ordinary 1 GB repository attachment quota.")


def release_fingerprint(release: dict) -> tuple:
    # Download counts change when this job fetches the assets; they are not drift.
    return (
        release["tag_name"], release.get("name"), release.get("body"), release["prerelease"],
        tuple(sorted((asset["id"], asset["name"], asset["size"], asset.get("digest"),
                      asset.get("updated_at")) for asset in release["assets"])),
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_github_assets(repository: str, release: dict, directory: Path) -> dict[str, Path]:
    assets = release["assets"]
    if assets:
        env = dict(os.environ)
        env.pop("GITEE_TOKEN", None)
        command([
            "gh", "release", "download", release["tag_name"], "--repo", repository,
            "--dir", str(directory),
        ], env=env)
    paths = {}
    for asset in assets:
        path = directory / asset["name"]
        if path.is_symlink() or not path.is_file() or path.stat().st_size != asset["size"]:
            raise MirrorError(f"Downloaded GitHub asset has unexpected size/type: {asset['name']}")
        digest = sha256_file(path)
        if asset.get("digest") and asset["digest"] != f"sha256:{digest}":
            raise MirrorError(f"Downloaded GitHub asset failed SHA-256 verification: {asset['name']}")
        paths[asset["name"]] = path
    return paths


class Gitee:
    def __init__(self, repository: str, token: str):
        self.repository = repository
        self.token = token
        self.api = urllib.request.build_opener(NoRedirect())
        self.downloads = urllib.request.build_opener(HTTPSRedirect())

    def request(self, method: str, path: str, *, payload=None, data=None, headers=None):
        request_headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        request_headers.update(headers or {})
        if payload is not None:
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            request_headers["Content-Type"] = "application/json"
        url = f"https://gitee.com/api/v5/repos/{self.repository}{path}"
        for attempt in range(3):
            request = urllib.request.Request(url, data=data, headers=request_headers, method=method)
            try:
                with self.api.open(request, timeout=120) as response:
                    body = response.read()
                return json.loads(body) if body else None
            except urllib.error.HTTPError as error:
                error.close()
                if method == "GET" and error.code in RETRYABLE_STATUSES and attempt < 2:
                    time.sleep(2 ** (attempt + 1))
                    continue
                raise APIError(error.code, method, path) from None
            except (OSError, TimeoutError):
                if method == "GET" and attempt < 2:
                    time.sleep(2 ** (attempt + 1))
                    continue
                # Never blindly retry a POST: it may have succeeded before a timeout.
                raise MirrorError(f"Gitee {method} {path} failed; rerun to reconcile remote state.") from None

    def release(self, tag: str):
        try:
            return self.request("GET", f"/releases/tags/{urllib.parse.quote(tag, safe='')}")
        except APIError as error:
            if error.status == 404:
                return None
            raise

    def attachments(self, release_id: int) -> list[dict]:
        attachments = []
        page = 1
        while True:
            batch = self.request("GET", f"/releases/{release_id}/attach_files?per_page=100&page={page}")
            attachments.extend(batch)
            if len(batch) < 100:
                return attachments
            page += 1

    def upload(self, release_id: int, path: Path):
        boundary = "mactools-" + uuid.uuid4().hex
        # Stream the multipart body from disk instead of keeping a DMG in memory.
        with tempfile.TemporaryFile() as body:
            body.write((f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
                        f"filename=\"{path.name}\"\r\nContent-Type: application/octet-stream\r\n\r\n").encode())
            with path.open("rb") as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    body.write(chunk)
            body.write(f"\r\n--{boundary}--\r\n".encode())
            length = body.tell()
            body.seek(0)
            return self.request("POST", f"/releases/{release_id}/attach_files", data=body, headers={
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Content-Length": str(length),
            })

    def matches(self, tag: str, path: Path) -> bool:
        url = (f"https://gitee.com/{self.repository}/releases/download/"
               f"{urllib.parse.quote(tag, safe='')}/{urllib.parse.quote(path.name, safe='')}")
        expected_size = path.stat().st_size
        for attempt in range(3):
            try:
                # Public downloads deliberately carry neither a token nor cookies.
                request = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
                with self.downloads.open(request, timeout=60) as response:
                    if response.headers.get_content_type() == "text/html":
                        raise MirrorError(f"Gitee returned an HTML page instead of attachment {path.name}.")
                    size = 0
                    digest = hashlib.sha256()
                    for chunk in iter(lambda: response.read(1024 * 1024), b""):
                        size += len(chunk)
                        if size > expected_size:
                            return False
                        digest.update(chunk)
                return size == expected_size and digest.hexdigest() == sha256_file(path)
            except urllib.error.HTTPError as error:
                error.close()
                if error.code not in RETRYABLE_STATUSES | {404} or attempt == 2:
                    raise MirrorError(f"Public Gitee download failed for {path.name} (HTTP {error.code}).") from None
            except (OSError, TimeoutError):
                if attempt == 2:
                    raise MirrorError(f"Public Gitee download failed for {path.name}.") from None
            time.sleep(2 ** (attempt + 1))
        return False


def mirror_assets(client: Gitee, release_id: int, tag: str, paths: dict[str, Path]) -> None:
    existing = client.attachments(release_id)
    by_name = {}
    for asset in existing:
        by_name.setdefault(asset["name"], []).append(asset)
    for name, path in paths.items():
        candidates = by_name.get(name, [])
        if len(candidates) == 1 and client.matches(tag, path):
            print(f"Verified existing attachment: {name}")
            continue
        for asset in candidates:
            client.request("DELETE", f"/releases/{release_id}/attach_files/{asset['id']}")
        client.upload(release_id, path)
        if not client.matches(tag, path):
            raise MirrorError(f"Uploaded Gitee attachment failed SHA-256 verification: {name}")
        print(f"Uploaded and verified: {name}")
    # Reconcile only the requested release, after all desired assets are verified.
    for asset in existing:
        if asset["name"] not in paths:
            client.request("DELETE", f"/releases/{release_id}/attach_files/{asset['id']}")
    actual = [asset["name"] for asset in client.attachments(release_id)]
    if sorted(actual) != sorted(paths):
        raise MirrorError("Gitee attachment inventory differs from GitHub; rerun the mirror job.")


def mirror(repository: str, tag: str, token: str) -> None:
    source = github_release(repository, tag)
    client = Gitee(GITEE_REPOSITORY, token)
    target = client.request("GET", "")
    if target.get("private") is not False:
        raise MirrorError("The Gitee download mirror must be a public repository.")
    release = client.release(tag)
    target_commitish = release.get("target_commitish") if release is not None else target.get("default_branch")
    if not isinstance(target_commitish, str) or not target_commitish.strip():
        raise MirrorError("Gitee requires an existing release target or an initialized default branch.")
    notice = (
        f"> Download mirror of the [GitHub release](https://github.com/{repository}/releases/tag/{tag}).\n"
        f"> [Corresponding source](https://github.com/{repository}/tree/{tag}). "
        "Gitee tags identify mirrored releases only; use the linked GitHub source "
        "instead of Gitee's automatically generated source archives."
    )
    metadata = {
        "tag_name": tag, "name": source.get("name") or tag,
        "body": notice + ("\n\n---\n\n" + source["body"] if source.get("body") else ""),
        "prerelease": source["prerelease"],
    }
    with tempfile.TemporaryDirectory(prefix="mactools-gitee-assets-") as directory:
        paths = download_github_assets(repository, source, Path(directory))
        if release is None:
            # Gitee creates its own tag from its existing branch; no Git history is pushed.
            release = client.request("POST", "/releases", payload=dict(metadata, target_commitish=target_commitish))
        # The API resolves a branch to a commit. Preserve that target on every retry.
        commit = release.get("target_commitish")
        if not isinstance(commit, str) or not commit.strip():
            raise MirrorError("Gitee did not return the release target; rerun to reconcile remote state.")
        metadata["target_commitish"] = commit
        mirror_assets(client, release["id"], tag, paths)
        client.request("PATCH", f"/releases/{release['id']}", payload=metadata)
        verified = client.release(tag)
        if not verified or any(verified.get(key) != value for key, value in metadata.items()):
            raise MirrorError("Gitee release metadata does not match the expected mirror after synchronization.")
        latest = github_release(repository, tag)
        if release_fingerprint(latest) != release_fingerprint(source):
            raise MirrorError("The GitHub Release changed during mirroring; rerun to synchronize its latest state.")
    print(f"Mirrored {tag}: {len(source['assets'])} assets at https://gitee.com/{GITEE_REPOSITORY}/releases/tag/{tag}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-repo", required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--tag")
    source.add_argument("--workflow-run-event", type=Path, help="Resolve a tag without publishing or using Gitee credentials")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.github_repo):
            raise MirrorError("Expected --github-repo owner/repository.")
        if args.workflow_run_event:
            if not args.github_output:
                raise MirrorError("--github-output is required when resolving a workflow run.")
            tag = workflow_release_tag(args.github_repo, json.loads(args.workflow_run_event.read_text(encoding="utf-8")))
            with args.github_output.open("a", encoding="utf-8") as output:
                output.write(f"tag={tag or ''}\n")
            print(f"Resolved published release: {tag}" if tag else "No plugin release was published; skipping the mirror.")
            return 0
        if not valid_tag(args.tag):
            raise MirrorError("Only v<version> and plugins-<version> releases are mirrored.")
        token = os.environ.get("GITEE_TOKEN", "").strip()
        if not token:
            raise MirrorError("GITEE_TOKEN must be supplied through an Actions secret or the environment.")
        mirror(args.github_repo, args.tag, token)
    except (MirrorError, ValueError, KeyError, OSError) as error:
        # Do not include raw transport errors, API bodies, or environment values.
        message = str(error) if isinstance(error, MirrorError) else "Invalid release data or a local I/O failure."
        print(f"Gitee mirror failed: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
