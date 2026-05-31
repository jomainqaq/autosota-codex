# Repository Guidelines

## Project Structure & Module Organization

This repository is a release snapshot for `autosota-codex`. The publishable npm package lives under `package/`, and the runtime implementation is in `package/dist/`. Key entry points are `package/dist/bin/autosota.js` for the CLI and `package/dist/run.sh` for the main orchestration flow. Optimizer scripts, shell helpers, and prompts live under `package/dist/optimizer/`; examples are in `package/dist/examples/`; user scaffolding templates are in `package/dist/paper_template/`.

There is no conventional `src/` or `tests/` tree in this snapshot. Treat `package/dist` as source for bug fixes unless a future upstream source layout is added.

## Build, Test, and Development Commands

- `node package/dist/bin/autosota.js --help`: verify the CLI loads.
- `bash -n package/dist/run.sh`: syntax-check the main shell runner.
- `bash -n package/dist/optimizer/scripts/record_score.sh`: syntax-check score recording.
- `npm --prefix package pack --dry-run`: inspect the package contents before publishing.
- `autosota doctor`: verify the currently installed user CLI environment.

For runtime bug fixes, create the smallest temporary workspace that reproduces the issue and run a dry-run path such as `bash package/dist/run.sh paper --skip-onboard --skip-research --dry-run`.

## Coding Style & Naming Conventions

Match existing style. Bash scripts use `set -euo pipefail`, quoted variables, uppercase environment/config variables, and small helper functions. Python snippets use straightforward functions, standard library modules first, and `pyyaml` for YAML. Node CLI files use CommonJS. Keep paths stable inside `package/dist`; avoid broad refactors or generated rewrites.

## Testing Guidelines

Prefer targeted smoke tests over full workflow runs. Verify both repository files and the current user install when fixing installed autosota behavior. Useful sync check:

```sh
cmp -s package/dist/run.sh /home/lmy/.nvm/versions/node/v24.14.1/lib/node_modules/autosota-codex/dist/run.sh
```

Do not commit generated logs, `.autosota/`, virtual environments, package tarballs, or temporary workspaces.

## Commit & Pull Request Guidelines

Follow the existing commit style: `fix: ...`, `docs: ...`, or `chore: ...`. Keep commits focused and include only repository-tracked source or documentation changes. Pull requests should describe the bug, reproduction steps, fix, verification commands, and whether the current user installed package was synced.

## Agent-Specific Instructions

This repository backs the current server user's installed autosota. When fixing a runtime bug, patch `package/dist/...`, sync the same change to `/home/lmy/.nvm/versions/node/v24.14.1/lib/node_modules/autosota-codex/dist/...`, verify behavior, then commit the repository change. Do not push unless explicitly requested.
