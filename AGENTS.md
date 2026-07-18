# Repository Instructions

## macOS Packaging

- Use `$package-macos-app` for every request to create a package, signed package, verification build, trial build, notarized package, or release package, including requests phrased as 打包、签名包、验证包、试用包、公证包、发布包.
- Treat the workflow's Git gates as mandatory. `signed` and `notarized` require a completely clean worktree, including staged and untracked files.
- `notarized` additionally requires branch `main` with `HEAD` exactly equal to the freshly fetched `origin/main`. Never bypass, weaken, or add force flags for these gates.
- Keep detailed packaging procedure in the skill and use `scripts/package.sh` as the only packaging entry point.
