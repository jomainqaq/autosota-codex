# autosota-codex

Codex-backed autosota package for local paper-code optimization loops.

This build is based on autosota 0.2.1 and keeps its legacy orchestration, but
routes all model-coding subprocesses through a bundled Codex compatibility shim.
No separate global Codex install is required after `npm install -g` because the
package resolves its bundled `@openai/codex` binary at startup and prepends it to
the subprocess `PATH`.

## Attribution

This package is a modified distribution adapted from AutoSOTA:
https://github.com/tsinghua-fib-lab/AutoSOTA

AutoSOTA is licensed under the MIT License. Original copyright notices and
license terms belong to the upstream authors. This package only distributes a
modified prebuilt `autosota-codex` build.

## Install

```bash
npm install -g ./autosota-codex-0.2.1-codex.5.tgz
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
research_api_key: "sk-example-change-me"
research_base_url: "http://127.0.0.1:8080/v1"
openrouter_api_key: ""
```

Replace `research_api_key` with your real key and `research_base_url` with
your OpenAI-compatible API endpoint. For local/proxy endpoints, keep the `/v1`
suffix, for example `http://your-openai-compatible-server:8080/v1` instead of
`http://your-openai-compatible-server:8080`.

The legacy `claude` subprocess calls are intentionally handled by
`dist/codex-shim-bin/claude`, which invokes `codex exec`.

Existing paper configs are refreshed from an input snapshot before each run. The
snapshot captures `paper/target.md` and `paper/priors/{references.md,ideas.md,directions.md}`,
then passes the snapshot priors into idea generation. Editing the target or
priors files therefore affects the next `autosota --repo ...` run without
rerunning onboarding.
