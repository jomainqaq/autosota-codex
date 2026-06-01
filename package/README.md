# autosota-codex

Codex-backed autosota package for local paper-code optimization loops.

This build is based on autosota 0.2.1 and keeps its legacy orchestration, but
routes all model-coding subprocesses through a bundled Codex compatibility shim.
No separate global Codex install is required after `npm install -g` because the
package resolves its bundled `@openai/codex` binary at startup and prepends it to
the subprocess `PATH`.

## Install

```bash
npm install -g ./autosota-codex-0.2.1-codex.9.tgz
codex login
autosota doctor
```

Alternatively set `CODEX_API_KEY` in the shell or run `codex login`.

## Quick Start

```bash
mkdir -p ~/autosota-work
cd ~/autosota-work
autosota init
# edit config.yaml and paper/target.md
autosota --repo /path/to/your/local/repo --devices 0,1
```

Important workspace config fields:

```yaml
research_model: "gpt-5.5"
research_api_key: ""
research_base_url: ""
openrouter_api_key: ""
```

The legacy `claude` subprocess calls are intentionally handled by
`dist/codex-shim-bin/claude`, which invokes `codex exec`.

Existing paper configs are refreshed from an input snapshot before each run. The
snapshot captures `paper/target.md` and `paper/priors/{references.md,ideas.md,directions.md}`,
then passes the snapshot priors into idea generation. Editing the target or
priors files therefore affects the next `autosota --repo ...` run without
rerunning onboarding.
