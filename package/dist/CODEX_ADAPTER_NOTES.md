# Codex Adapter Notes

## Source Recovery Attempt

- `dist/bin/autosota-legacy.js` contains recoverable function names, but the
  body is still string-table and control-flow obfuscated. autosota-codex keeps
  it as a legacy delegate and adds a clean wrapper at `dist/bin/autosota.js`.
- `dist/optimizer/scripts/run.py` and `dist/optimizer/scripts/onboard.py` are
  PyArmor-protected payloads. Stable source recovery was not available from the
  package contents, so the adapter preserves them and intercepts their legacy
  `claude` subprocess calls.

## Runtime Bridge

`dist/codex-shim-bin/claude` is intentionally private to this package. The
wrapper prepends that directory to `PATH` before delegating to the encrypted
orchestrator, so global user shell state is not modified.

Default model: `gpt-5.5`.
