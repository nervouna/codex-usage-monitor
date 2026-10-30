# Contributing

Codex Usage Monitor is a personal project, but bug reports and fixes are welcome.

## Issues

- **Bugs:** use the bug report form. Give your macOS version, how Codex is installed (ChatGPT app, Codex app, Homebrew, npm), what happened and what you expected; a suggested fix is a bonus.
- **Security problems:** report them privately, see [SECURITY.md](SECURITY.md).
- **Feature ideas:** open an issue to discuss it first. The app stays small on purpose, so not every idea will fit.

## How the project is developed

Most of the code is written by coding agents. `AGENTS.md` holds the rules they follow; they apply to human contributions too. In short:

- The XCTest suite passes (`xcodebuild ... test`, see the README).
- `scripts/package.sh` is the only way to build a package. Its Git checks are mandatory: `signed` and `notarized` need a completely clean worktree, including staged and untracked files, and `notarized` needs `main` equal to the freshly fetched `origin/main`. Never bypass or weaken them.
- The interface is in Simplified Chinese.

## Pull requests

Describe the change, list the commands you ran and their results, and say what you checked in the running app.
