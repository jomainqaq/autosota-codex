# autosota-codex release

This repository distributes a modified, prebuilt `autosota-codex` npm package.
It is not a complete source-code release: the package is provided as an
installable `.tgz` artifact through GitHub Releases.

## Attribution

This package is a modified distribution adapted from AutoSOTA:
https://github.com/tsinghua-fib-lab/AutoSOTA

AutoSOTA is licensed under the MIT License. Original copyright notices and
license terms belong to the upstream authors. This repository only distributes a
modified prebuilt `autosota-codex` package.

## Install

Download and install the release package:

```bash
npm install -g https://github.com/jomainqaq/autosota-codex/releases/download/v0.2.1-codex.11/autosota-codex-0.2.1-codex.11.tgz
```

Or install from a local downloaded artifact:

```bash
npm install -g ./autosota-codex-0.2.1-codex.11.tgz
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

## Release Files

Each GitHub Release should attach:

- `autosota-codex-0.2.1-codex.11.tgz`
- `SHA256SUMS.txt`

Verify the downloaded package:

```bash
sha256sum -c SHA256SUMS.txt
```
