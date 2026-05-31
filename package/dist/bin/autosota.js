#!/usr/bin/env node
"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const PACKAGE_ROOT = path.join(ROOT, "..");
const LEGACY_BIN = path.join(__dirname, "autosota-legacy.js");
const RUN_SH = path.join(ROOT, "run.sh");
const SHIM_DIR = path.join(ROOT, "codex-shim-bin");
const PKG = JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"), "utf8"));
const DEFAULT_MODEL = "gpt-5.5";

function green(s) {
  return `\x1b[32m${s}\x1b[0m`;
}

function red(s) {
  return `\x1b[31m${s}\x1b[0m`;
}

function yellow(s) {
  return `\x1b[33m${s}\x1b[0m`;
}

function bold(s) {
  return `\x1b[1m${s}\x1b[0m`;
}

function bundledBinDir() {
  const candidates = [];
  try {
    const pkgPath = require.resolve("@openai/codex/package.json", {
      paths: [PACKAGE_ROOT, ROOT, __dirname],
    });
    let dir = path.dirname(pkgPath);
    for (let i = 0; i < 8 && dir && dir !== path.dirname(dir); i += 1) {
      if (path.basename(dir) === "node_modules") {
        candidates.push(path.join(dir, ".bin"));
        break;
      }
      dir = path.dirname(dir);
    }
  } catch {
    // Dependency may not be installed yet while inspecting an unpacked tarball.
  }
  candidates.push(path.join(PACKAGE_ROOT, "node_modules", ".bin"));

  const executable = process.platform === "win32" ? "codex.cmd" : "codex";
  for (const dir of candidates) {
    try {
      if (fs.existsSync(path.join(dir, executable))) return dir;
    } catch {
      // Ignore inaccessible candidate dirs.
    }
  }
  return "";
}

function prependPath(...dirs) {
  const sep = path.delimiter;
  const current = process.env.PATH || "";
  const parts = current.split(sep).filter(Boolean);
  for (const dir of dirs.filter(Boolean).reverse()) {
    if (!parts.includes(dir)) parts.unshift(dir);
  }
  process.env.PATH = parts.join(sep);
}

prependPath(SHIM_DIR, bundledBinDir());

function hasCmd(cmd) {
  const res = spawnSync(
    process.platform === "win32" ? "where.exe" : "command",
    process.platform === "win32" ? [cmd] : ["-v", cmd],
    {
      stdio: ["ignore", "ignore", "ignore"],
      shell: process.platform !== "win32",
    },
  );
  return res.status === 0;
}

function cmdVersion(cmd, args = ["--version"]) {
  try {
    const res = spawnSync(cmd, args, {
      stdio: ["ignore", "pipe", "pipe"],
      encoding: "utf8",
      shell: process.platform === "win32",
    });
    const out = `${res.stdout || ""}\n${res.stderr || ""}`.trim().split(/\r?\n/)[0] || "";
    return res.status === 0 ? out || "ok" : "";
  } catch {
    return "";
  }
}

function workspacePaths() {
  const workspace = process.env.AUTOSOTA_WORKSPACE || process.cwd();
  const data = process.env.AUTOSOTA_DATA_DIR || path.join(workspace, ".autosota");
  return { workspace, data };
}

function parseSimpleYaml(file) {
  if (!fs.existsSync(file)) return {};
  const out = {};
  for (const raw of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const line = raw.replace(/\s+#.*$/, "");
    const m = line.match(/^([A-Za-z0-9_]+):\s*(.*)$/);
    if (!m) continue;
    let value = m[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    out[m[1]] = value;
  }
  return out;
}

function usage() {
  process.stdout.write(`${bold("autosota-codex")} - paper-to-SOTA loop with Codex orchestration (v${PKG.version})

Usage:
  autosota [options] [paper_name]        Run the full optimization loop
  autosota init [--force]                Scaffold ./config.yaml + ./paper/ in the current dir
  autosota login                         Run bundled Codex login
  autosota doctor                        Check required tools (python3, codex, git, ...)
  autosota sessions [--paper <n>]        List optimization runs
  autosota inspect <run|paper|latest>    Show run details
  autosota ask <question...>             Ask Codex about the latest run
  autosota steer <message...>            Inject instruction into the next iteration
  autosota pause [<run>] [--off]         Toggle pause-after-each-iter
  autosota continue [<run>]              Release a paused run
  autosota -v, --version                 Print version
  autosota -h, --help                    Show this help

Common options forwarded to run.sh:
  --repo <path_or_url>       Local clone path or repo URL hint
  --devices <gpu_ids>        GPUs (default: 0,1)
  --api-key <key>            Codex API key (sets CODEX_API_KEY)
  --skip-onboard             Use existing <data>/papers/<name>/config.yaml
  --skip-research            Skip literature research phase
  --dry-run                  Build prompts without invoking Codex
  --max-iter N               Override max_iterations
  --max-total-minutes M      Wall-clock cap for the Codex process
  -i, --interactive          Pause after every iteration

Codex defaults:
  codex_model: ${DEFAULT_MODEL}
  codex_sandbox: danger-full-access
  codex_approval: never

See \`bash ${RUN_SH} --help\` for the complete legacy option list.
`);
}

function doctor() {
  const { workspace, data } = workspacePaths();
  const cfgPath = path.join(workspace, "config.yaml");
  const cfg = parseSimpleYaml(cfgPath);
  const targetPath = path.join(workspace, "paper", "target.md");
  const venvPath = path.join(data, "venv", "bin", "python");
  let ok = true;

  console.log(bold(`autosota-codex doctor (v${PKG.version})`));
  console.log("");

  function check(pass, label, detail, required = true) {
    const mark = pass ? green("OK") : required ? red("NO") : yellow("--");
    console.log(`  ${mark} ${label}${detail ? `: ${detail}` : ""}`);
    if (!pass && required) ok = false;
  }

  check(true, "Node.js", process.version.replace(/^v/, ""));
  const bashVersion = hasCmd("bash") ? cmdVersion("bash", ["--version"]) : "";
  check(Boolean(bashVersion), "bash", bashVersion || "NOT RUNNABLE (required; install WSL bash, Git Bash, or run on Linux/macOS)");
  check(hasCmd("python3") || hasCmd("python"), "python", cmdVersion(hasCmd("python3") ? "python3" : "python"));
  check(hasCmd("git"), "git", hasCmd("git") ? cmdVersion("git", ["--version"]) : "NOT FOUND");

  const codexVersion = hasCmd("codex") ? cmdVersion("codex", ["--version"]) : "";
  check(Boolean(codexVersion), "codex", codexVersion || "NOT RUNNABLE - bundled @openai/codex was not found");

  const model = process.env.CODEX_MODEL || cfg.codex_model || cfg.claude_model || DEFAULT_MODEL;
  check(Boolean(model), "Codex model", model);

  const apiKey = process.env.CODEX_API_KEY || cfg.codex_api_key || cfg.openai_api_key || "";
  const codexHome = process.env.CODEX_HOME || path.join(process.env.USERPROFILE || process.env.HOME || "", ".codex");
  const authFile = path.join(codexHome, "auth.json");
  let hasAuthFile = false;
  try {
    hasAuthFile = fs.statSync(authFile).size > 0;
  } catch {
    hasAuthFile = false;
  }
  check(Boolean(apiKey || hasAuthFile), "Codex auth", apiKey ? "CODEX_API_KEY configured" : hasAuthFile ? `found ${authFile}` : "NOT FOUND - run `codex login` or set codex_api_key/CODEX_API_KEY");

  const researchKey = process.env.RESEARCH_API_KEY || cfg.research_api_key || cfg.openrouter_api_key || "";
  check(Boolean(researchKey || cfg.skip_research === "true"), "Research API key", researchKey ? "configured" : "not configured; use --skip-research or set research_api_key/openrouter_api_key", false);
  check(fs.existsSync(targetPath), "Target", fs.existsSync(targetPath) ? targetPath : `MISSING - run \`autosota init\` then edit ${targetPath}`);
  check(fs.existsSync(venvPath), "Python venv", fs.existsSync(venvPath) ? venvPath : `not yet created - will be auto-built on first run at ${venvPath}`, false);

  console.log("");
  console.log(`  Workspace : ${workspace}`);
  console.log(`  Data dir  : ${data}`);
  console.log(`  Package   : ${ROOT}`);
  console.log(`  Shim dir  : ${SHIM_DIR}`);
  const bundled = bundledBinDir();
  console.log(`  Codex bin : ${bundled || "not found"}`);
  process.exit(ok ? 0 : 1);
}

function envForLegacy(extraArgs) {
  const env = { ...process.env };
  env.AUTOSOTA_ROOT = ROOT;
  env.AUTOSOTA_CODEX_SHIM_DIR = SHIM_DIR;
  env.PATH = process.env.PATH || env.PATH || "";
  env.CODEX_DEFAULT_MODEL = DEFAULT_MODEL;

  const apiKeyIndex = extraArgs.findIndex((arg) => arg === "--api-key");
  if (apiKeyIndex >= 0 && extraArgs[apiKeyIndex + 1] && !env.CODEX_API_KEY) {
    env.CODEX_API_KEY = extraArgs[apiKeyIndex + 1];
  }
  if (!env.AUTOSOTA_WORKSPACE) env.AUTOSOTA_WORKSPACE = process.cwd();
  if (!env.AUTOSOTA_DATA_DIR) env.AUTOSOTA_DATA_DIR = path.join(env.AUTOSOTA_WORKSPACE, ".autosota");
  return env;
}

function runLegacy(args) {
  if (!fs.existsSync(LEGACY_BIN)) {
    console.error(red(`[autosota-codex] missing legacy entry: ${LEGACY_BIN}`));
    process.exit(1);
  }
  const res = spawnSync(process.execPath, [LEGACY_BIN, ...args], {
    stdio: "inherit",
    cwd: process.cwd(),
    env: envForLegacy(args),
  });
  process.exit(res.status === null ? 1 : res.status);
}

function copyTemplateFile(src, dest, force) {
  if (fs.existsSync(dest) && !force) return false;
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(src, dest);
  return true;
}

function copyTemplateTree(srcDir, destDir, force) {
  let wrote = false;
  fs.mkdirSync(destDir, { recursive: true });
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const src = path.join(srcDir, entry.name);
    const dest = path.join(destDir, entry.name);
    if (entry.isDirectory()) {
      wrote = copyTemplateTree(src, dest, force) || wrote;
    } else if (entry.isFile()) {
      wrote = copyTemplateFile(src, dest, force) || wrote;
    }
  }
  return wrote;
}

function initCmd(args) {
  const unknown = args.filter((arg) => arg !== "--force");
  if (unknown.length) {
    console.error(red(`[autosota-codex] unknown init option: ${unknown[0]}`));
    process.exit(2);
  }

  const force = args.includes("--force");
  const workspace = process.cwd();
  const cfgPath = path.join(workspace, "config.yaml");
  const paperPath = path.join(workspace, "paper");

  console.log(bold(`autosota init - scaffolding in ${workspace}`));
  console.log("");
  const cfgWrote = copyTemplateFile(path.join(ROOT, "config.yaml.example"), cfgPath, force);
  const paperWrote = copyTemplateTree(path.join(ROOT, "paper_template"), paperPath, force);
  console.log(`  ${cfgWrote ? green("wrote") : yellow("kept")}  ${cfgPath}`);
  console.log(`  ${paperWrote ? green("wrote") : yellow("kept")}  ${paperPath}`);
  console.log("");
  console.log("Next steps:");
  console.log(`  1. Edit ${cfgPath} - set research_api_key and research_base_url (include /v1)`);
  console.log("     Leave openrouter_api_key empty unless using legacy fallback.");
  console.log(`  2. Edit ${path.join(paperPath, "target.md")} - describe metrics & goal`);
  console.log(`  3. (optional) Replace ${path.join(paperPath, "paper.pdf")} with the real paper`);
  console.log(`  4. ${bold("autosota doctor")}   # verify`);
  console.log(`  5. ${bold("autosota --repo /path/to/your-clone")}`);
}

function loginCmd(args) {
  const res = spawnSync("codex", ["login", ...args], {
    stdio: "inherit",
    cwd: process.cwd(),
    env: process.env,
    shell: process.platform === "win32",
  });
  process.exit(res.status === null ? 1 : res.status);
}

function main() {
  const args = process.argv.slice(2);
  const cmd = args[0];
  if (!cmd || cmd === "-h" || cmd === "--help" || cmd === "help") {
    usage();
    return;
  }
  if (cmd === "-v" || cmd === "--version") {
    console.log(PKG.version);
    return;
  }
  if (cmd === "doctor") {
    doctor();
    return;
  }
  if (cmd === "login") {
    loginCmd(args.slice(1));
    return;
  }
  if (cmd === "init") {
    initCmd(args.slice(1));
    return;
  }
  runLegacy(args);
}

main();
