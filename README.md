# Codex Usage Monitor

English | [简体中文](README.zh-CN.md)

[![Release](https://img.shields.io/github/v/release/nervouna/codex-usage-monitor)](https://github.com/nervouna/codex-usage-monitor/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

<!-- banner -->

A native macOS menu bar app that shows the Codex quota and token usage of the ChatGPT account you are signed in with. It gets the numbers from the Codex CLI on your Mac and keeps no login data of its own.

<!-- screenshots -->

## Status

Codex Usage Monitor is a personal project, built by its author for their own Codex account and shared as is. It needs macOS 14 or later (Apple silicon or Intel), the ChatGPT app or the Codex CLI, and Codex signed in with a ChatGPT account. The interface is in Simplified Chinese only. Releases on GitHub are notarized universal ZIPs; the latest is v1.0.1. It relies on an experimental Codex interface, so a Codex update can break it.

## How it is built

Most of the code is written by coding agents. `AGENTS.md` holds the rules they follow, which cover packaging: `scripts/package.sh` is the only way to build a package, and its Git checks (a clean worktree for signed builds, `main` equal to `origin/main` for notarized ones) are never bypassed. See [CONTRIBUTING.md](CONTRIBUTING.md) to report a bug or send a fix, and [SECURITY.md](SECURITY.md) for security problems.

## What it does

- Shows the remaining percentage of the standard Codex 7-day rolling quota in the menu bar.
- Shows when the quota resets, and the separate quotas of other models (for example Codex Spark).
- Shows total and daily average token usage over the last 7 and 30 full days, and the account's all-time total.
- Refreshes every 5 minutes, and on demand. Can start at login.
- When a refresh fails, keeps the last good data and marks it as possibly out of date.
- Sends a local notification when it sees the standard weekly quota go from below 100 % back to 100 %. The notification gives the remaining quota, the next reset time and the last 7 days' usage.
- Warns once per quota period when the quota first falls to 20 % or below.

## Install

1. Download the ZIP from the [latest release](https://github.com/nervouna/codex-usage-monitor/releases/latest) and unzip it.
2. Move `Codex Usage Monitor.app` to `/Applications` and open it. It appears in the menu bar, not in the Dock.
3. To start it at login, turn on 开机时启动 (Launch at login) in its menu.

## Quota notifications

The first time you open the menu after installing or updating, the app asks for permission to send notifications. The 额度通知 (Quota notifications) switch in the menu is on by default and can be turned off at any time. If macOS permission is denied, 打开系统设置 (Open System Settings) in the menu takes you to the setting.

The quota state is saved on the Mac after each successful refresh. The first reading only sets a baseline, so it never notifies by mistake. After that, it notifies only when it actually sees the remaining quota go from below 100 % back to 100 %; if it never saw 100 %, no reset notification is sent afterwards. Detection runs at the 5-minute refresh interval, so with Codex in use on several devices a notification can come a little late.

## What it reads and what goes online

The app does not open network connections itself. On each refresh it:

1. Works out the Codex configuration directory (see below). To find it, it checks whether `auth.json` exists in the candidate directories; it does not read, copy or store that file or any token.
2. Starts the Codex CLI from a fixed list of locations (the ChatGPT or Codex app bundle in `/Applications`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` and mise's Node LTS) as `codex app-server --stdio`, with `CODEX_HOME` set to that directory.
3. Asks it for the account's rate limits and usage over its experimental JSON-RPC interface (`account/rateLimits/read`, `account/usage/read`). Codex answers with the login in its own configuration directory and fetches the numbers from OpenAI.

To find `CODEX_HOME` when the app was not started from a terminal, it runs your login shell once (`$SHELL -ilc`, which runs your shell's startup files) to print the variable, and stops it after 2 seconds.

The app stores, in its user defaults (`io.damao.CodexUsageMonitor`): the directory you chose by hand, the notification switch, whether it has asked for notification permission, and the last observed quota state for notifications.

### Codex configuration directory

The app picks the directory in this order and passes it to the local Codex process:

1. A directory chosen by hand in the menu.
2. `CODEX_HOME` in the app's environment.
3. `CODEX_HOME` in your login shell, for when the app starts from Finder or at login and has no terminal environment.
4. The login file in `~/Library/Application Support/Codex/home` and `~/.codex`: if only one has it, that one is used; if both do, the app asks you to choose; if neither does, it uses `~/.codex`.

The directory is worked out again on every refresh. A directory chosen by hand under Codex 数据目录 (Codex data directory) with 选择… (Choose…) is saved on the Mac; 自动检测 (Detect automatically) goes back to automatic detection. The directory can be anywhere; it does not have to be `~/.codex`.

## Uninstall

1. Turn off 开机时启动 (Launch at login) in the menu, then choose 退出 (Quit).
2. Move `Codex Usage Monitor.app` to the Trash.
3. To remove its settings: `defaults delete io.damao.CodexUsageMonitor`.

Nothing in the Codex configuration directory is changed by the app.

## Build

```bash
xcodebuild \
  -project CodexUsageMonitor.xcodeproj \
  -scheme CodexUsageMonitor \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  build
```

The app is built to `.build/DerivedData/Build/Products/Debug/Codex Usage Monitor.app`.

Run the tests:

```bash
xcodebuild \
  -project CodexUsageMonitor.xcodeproj \
  -scheme CodexUsageMonitor \
  -derivedDataPath .build/DerivedData \
  test
```

Launch at login only works when the app runs from its `.app` bundle; when the executable inside it is run directly, macOS may refuse to register the login item.

## Packaging

`scripts/package.sh` builds every Release universal ZIP. Run it with `--dry-run` first to see the Git checks, the current and next build number, the output path and the external steps; a dry run changes no files, makes no commits, pushes nothing and uploads nothing for notarization.

```bash
./scripts/package.sh adhoc --dry-run
./scripts/package.sh signed --dry-run
NOTARYTOOL_PROFILE=codex-usage-monitor ./scripts/package.sh notarized --dry-run
```

After checking the dry run, run the real command:

```bash
./scripts/package.sh adhoc
./scripts/package.sh signed
NOTARYTOOL_PROFILE=codex-usage-monitor \
  ./scripts/package.sh notarized --confirm-publish
```

- `adhoc`: ad hoc signature, for testing on your own Mac. A dirty worktree is allowed and uncommitted changes go into the app; the build number change stays in the worktree and is not committed.
- `signed`: Developer ID Application signature, for sharing test builds; it is not notarized for Gatekeeper. Needs a completely clean worktree; after the tests pass it commits only the build number change and does not push. With one signing identity it picks it; with several, set `DEVELOPER_ID_APPLICATION` and optionally `DEVELOPMENT_TEAM`.
- `notarized`: for releases. Needs a completely clean worktree, the `main` branch, and local `main` equal to the latest `origin/main` at the start. After the tests pass it commits and pushes the build number change, submits the app for notarization, staples the ticket and checks it with Gatekeeper. The real run needs `--confirm-publish`.

`signed` and `notarized` run the full XCTest suite before raising the build number, so failed tests do not use up a build number. Once the build commit exists it stays, even if the build or notarization fails later; do not revert or reuse it. The script creates no Git tag or GitHub release and does not change the marketing version.

Keep notarization credentials in the Keychain only. Create the profile interactively on your Mac; never put an Apple ID password or app-specific password in the repository:

```bash
xcrun notarytool store-credentials codex-usage-monitor
```

Intermediate files go to `.build/staging/`. The final ZIP moves to `.build/releases/` only after every check passes, named:

```text
Codex-Usage-Monitor-macOS-universal-<adhoc|signed|notarized>-YYYY-MM-DD-build-N.zip
```

## License

MIT, see [LICENSE](LICENSE).
