# Gitee Release Mirror

Official app (`v*`) and plugin batch (`plugins-*`) releases are mirrored from GitHub to
[ggbond2700/MacTools on Gitee](https://gitee.com/ggbond2700/MacTools/releases).
The independent `Gitee Release` workflow listens for successful `Release` and `Plugin Release`
runs through `workflow_run`. Pages deployment and mirroring run independently after GitHub
publication; a mirror failure cannot change the publisher's result or delay Pages deployment.
A plugin run with no release changes skips the mirror. Nightly releases remain on their
existing independent publication path.

## Configuration

Create the GitHub repository Actions **secret** `GITEE_TOKEN` using a Gitee personal access
token with repository permissions (`projects`). Its account must have write access to
`ggbond2700/MacTools`. The target must be a public, initialized repository with a default
branch; its code does not need to match GitHub. No Apple signing or catalog private keys are
passed to the mirror job; its GitHub token has only `contents: read` permission. A separate
tag-resolution job also has `actions: read` to inspect the source run's artifact and job metadata.
Only the upload job receives `GITEE_TOKEN`.

Automatic runs use the existing `MacTools-<tag>` artifact name from the successful source
run to identify the release, including manually dispatched releases whose workflow branch
differs from the requested tag. No build artifact is downloaded or executed. If a plugin run
has no artifact, its publication step must have been skipped in that exact run attempt before
the mirror can be skipped. Missing or ambiguous metadata otherwise fails with instructions
for manual recovery. Both mirror jobs check out tooling from the repository's default branch;
merge this workflow there before publishing so GitHub can trigger it.

The destination is fixed in `scripts/sync-gitee-release.py`. Release tags are supplied as
environment data, never interpolated into shell commands. The Gitee token stays in the
environment and authenticated API headers, not command arguments, public download
requests, or release files. Synchronization uses the Gitee API and never pushes Git history.

## Synchronization

GitHub is authoritative for release tag names, titles, original Markdown notes, prerelease
flags, asset names, and asset bytes. A mirror notice precedes the original notes and links
to the GitHub release and its corresponding source. GitHub's `Latest` designation,
platform-generated source archives, release IDs, timestamps, asset counters, and URLs are
platform-specific and are not copied.

Gitee requires a tag for each release. When creating a release, its API creates a same-name
tag using Gitee's existing default branch if that tag does not already exist. Gitee tags
identify mirrored release versions; their commits do not need to match GitHub. No code or
commit history is synchronized, no branches are moved, and existing release targets are
preserved on retries. Use the linked GitHub source for the downloaded binaries: Gitee's
automatic source archives reflect its own repository code and may differ from the build source.

1. Read the published GitHub Release and its complete, paginated asset inventory. Reject
   draft releases, incomplete uploads, duplicate or unsafe filenames, and files over the
   ordinary Gitee attachment limit before mutating Gitee.
2. Download the existing GitHub assets without rebuilding, signing, repacking, or changing
   any versions. Check file size and GitHub's SHA-256 digest when it is available.
3. Create the matching Gitee Release when absent, using its existing default branch as the
   tag target. Preserve the target returned by Gitee when updating an existing release.
4. For each attachment, verify the complete
   public download against the source SHA-256. Reuse matching files; replace changed files
   with the same name and reconcile duplicates left by an earlier attempt.
5. Once the desired files are verified, remove extra attachments from this release only,
   then check the final inventory and synchronize the title, notes, and prerelease flag.
   Older releases are never deleted to reclaim space.
6. Confirm that GitHub's release metadata and asset identities did not change during the run.

Both APIs are paginated. Read failures have bounded retries. A mutating request whose result
is uncertain is not blindly repeated: the job fails, and a rerun inspects the remote state
before uploading again. Multipart uploads stream from temporary disk files. Public Gitee
download verification sends no credentials or cookies, rejects HTML challenge pages, and
requires HTTPS redirects and matching file size and SHA-256.

The [ordinary Gitee community quotas](https://help.gitee.com/account/usage-quota) are 100 MB
per attachment and 1 GB of attachments per repository across releases and repository
attachments. The helper conservatively uses 100,000,000 and 1,000,000,000 bytes for the
single-file and single-release preflight. Existing attachments also consume the repository
quota; the server enforces the remaining capacity. A quota or authentication failure fails
the mirror job rather than silently omitting files or removing old releases.

## Recovery

A failed mirror job marks only the independent **Gitee Release** workflow as failed. GitHub
publication, Sparkle metadata, and plugin catalog deployment continue through their existing
workflows. Use **Re-run failed jobs** on the failed **Gitee Release** run to retry it; do not
rerun **Release** or **Plugin Release** merely to repair the mirror.

For a standalone repair or to mirror an older release, run **Actions → Gitee Release → Run
workflow**, choose `main`, and enter the already-published GitHub tag. This does not bump
versions or rebuild packages, and works even if the original build artifact metadata has
expired. Manual and automatic uploads of the same tag share a concurrency group. A standalone
repair leaves earlier run results unchanged; it does not retrigger Pages deployment.

Maintainers can also run the helper with an authenticated GitHub CLI; a full checkout or
local release tags are unnecessary. Supply `GITEE_TOKEN` through the environment:

```bash
python3 scripts/sync-gitee-release.py --github-repo ggbond268/MacTools --tag plugins-1.3.0
```

This command publishes to Gitee. Script tests use fake APIs and temporary files and never
publish test releases. Validate changes with `make script-tests` and `actionlint`.

## Client Downloads

This change adds release distribution only. Existing signed catalog URLs, package URLs,
Sparkle feeds, PluginKit ABI versions, and client download behavior remain unchanged.
Users may download the mirrored packages from Gitee manually. Automatic source selection
or fallback requires a separate client change and must retain all existing package checks.
