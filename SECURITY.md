# Security

Codex Usage Monitor runs on a Mac where Codex is signed in to a ChatGPT account. It starts the local Codex CLI with the user's Codex configuration directory, which holds the login, and it runs the user's login shell to find `CODEX_HOME`. It is meant to read quota and usage numbers and nothing else: it does not read or keep the login itself and opens no network connections of its own.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately through GitHub: **Security → Report a vulnerability** on this repository ([direct link](https://github.com/nervouna/codex-usage-monitor/security/advisories/new)). Include what you did, what happened, your macOS version and the release or commit you tested.

You will get an answer within a week. Fixes land on `main`; there are no maintained release branches.

## In scope

- A way to make the app read, copy, store or send the Codex login or other files from the configuration directory
- A way to make the app start a program other than the Codex CLI, or pass it something other than the usage requests
- A way for data from Codex or the configuration directory to make the app run code

## Out of scope

- Anything that already needs control of the user's account, shell startup files or the Codex installation
- Bugs in the Codex CLI or the ChatGPT app themselves
- Wrong or late quota numbers that do not affect security
