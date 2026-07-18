---
name: package-macos-app
description: Package Codex Usage Monitor as an ad hoc, Developer ID signed, or Apple-notarized universal macOS ZIP. Use for any request to package, sign, create a local verification build, create a trial build, notarize, publish, or produce a macOS release artifact from this repository.
---

# Package the macOS app

Use `scripts/package.sh` from the repository root as the only packaging entry point. Do not copy its logic, invoke `xcodebuild` as an alternative packaging path, weaken its gates, or add force options.

## Select the mode

- Choose `adhoc` for a local verification package. Allow a dirty worktree and disclose every uncommitted file that will be included. Do not commit or push.
- Choose `signed` for a shareable Developer ID trial package that is not claimed to be notarized. Require a completely clean worktree. Allow any branch. Commit only the generated build-number bump and do not push.
- Choose `notarized` for a formal release package. Require a clean `main` with local `HEAD` exactly equal to freshly fetched `origin/main`. Commit the build bump, push only that new commit to `main`, submit to Apple, and staple the accepted ticket.

Do not create tags, GitHub releases, or marketing-version changes unless the user separately requests them.

## Preview and confirm

Run the matching dry run first:

```bash
./scripts/package.sh <adhoc|signed|notarized> --dry-run
```

Present the mode, branch, HEAD, worktree state, current and next build, expected filename, and external effects. For `adhoc`, enumerate the dirty files included in the package.

Obtain explicit user confirmation after presenting that preview and before running a real package. For `notarized`, state that one confirmation authorizes all three external effects: creating the build commit, pushing `main`, and uploading the archive to Apple's notarization service. Do not perform any of them before confirmation.

## Execute

After confirmation, run exactly one command:

```bash
./scripts/package.sh adhoc
./scripts/package.sh signed
NOTARYTOOL_PROFILE=<keychain-profile> ./scripts/package.sh notarized --confirm-publish
```

Use `NOTARYTOOL_PROFILE` only as the name of a Keychain profile. Never request, store, print, or place an Apple ID, password, app-specific password, token, or private signing material in the repository. The script must validate the profile before consuming a build number.

Let the script enforce tests, build-number changes, scoped commits, signing, notarization, staging, ZIP re-extraction, architecture and signature checks, Team ID, bundle build number, Gatekeeper checks, and SHA-256 generation.

## Handle failure

- Never bypass a Git, certificate, credential, test, output-conflict, signing, or verification failure.
- If tests fail, report that the build number was not consumed.
- If a build commit was created before a later build or notarization failure, preserve it. Do not reset, amend, revert, or reuse that build number.
- If a notarized preflight reports ahead, behind, diverged, detached, dirty, or non-`main`, stop and explain the exact gate. Do not automatically push pre-existing commits or reconcile branches.
- Treat only ZIPs atomically published in `.build/releases/` as completed artifacts. Files under `.build/staging/` are incomplete.

## Report evidence

Report the mode, final build number, package path, SHA-256, test result when applicable, universal architectures, signature type, Team ID when applicable, and notarization, stapler, and Gatekeeper results when applicable. State any skipped or blocked verification explicitly.
