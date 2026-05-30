# autosota-codex release

This repository distributes a modified, prebuilt `autosota-codex` npm package.
It is not a complete source-code release: the package is provided as an
installable `.tgz` artifact through GitHub Releases.

## Install

Download and install the release package:

```bash
npm install -g https://github.com/your-org/autosota-codex-release/releases/download/v0.2.1-codex.5/autosota-codex-0.2.1-codex.5.tgz
```

Or install from a local downloaded artifact:

```bash
npm install -g ./autosota-codex-0.2.1-codex.5.tgz
```

## Basic Usage

```bash
autosota init
codex login
autosota doctor
autosota --repo /path/to/your/local/repo --devices 0,1
```

After `autosota init`, edit `config.yaml`:

```yaml
research_model: "gpt-5.5"
research_api_key: "sk-example-change-me"
research_base_url: "http://your-openai-compatible-server:8080/v1"
openrouter_api_key: ""
```

Replace `research_api_key` with your real key. Replace `research_base_url`
with your OpenAI-compatible endpoint and keep the `/v1` suffix.

## Do Not Commit Local Runtime Files

Keep these local-only files out of public repositories:

- `config.yaml`
- `.env*`
- `.autosota/`
- `logs/`
- `optimized_code/`
- `node_modules/`
- `*.tgz`

## Release Files

Each GitHub Release should attach:

- `autosota-codex-0.2.1-codex.5.tgz`
- `SHA256SUMS.txt`

Verify the downloaded package:

```bash
sha256sum -c SHA256SUMS.txt
```

