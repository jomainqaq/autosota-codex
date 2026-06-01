"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

function bold(s) {
  return `\x1b[1m${s}\x1b[0m`;
}

function dim(s) {
  return `\x1b[2m${s}\x1b[0m`;
}

function green(s) {
  return `\x1b[32m${s}\x1b[0m`;
}

function yellow(s) {
  return `\x1b[33m${s}\x1b[0m`;
}

function red(s) {
  return `\x1b[31m${s}\x1b[0m`;
}

function die(message, code = 1) {
  console.error(red(`[autosota-codex] ${message}`));
  process.exit(code);
}

function workspacePaths(context) {
  if (context && typeof context.workspacePaths === "function") {
    return context.workspacePaths();
  }
  const workspace = process.env.AUTOSOTA_WORKSPACE || process.cwd();
  const data = process.env.AUTOSOTA_DATA_DIR || path.join(workspace, ".autosota");
  return { workspace, data };
}

function parseArgs(args) {
  const out = { flags: new Set(), options: {}, positionals: [] };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "--paper") {
      out.options.paper = args[i + 1] || "";
      i += 1;
    } else if (arg.startsWith("--paper=")) {
      out.options.paper = arg.slice("--paper=".length);
    } else if (arg.startsWith("--")) {
      out.flags.add(arg);
    } else {
      out.positionals.push(arg);
    }
  }
  return out;
}

function stripYamlComment(line) {
  const idx = line.search(/\s#/);
  return idx >= 0 ? line.slice(0, idx) : line;
}

function parseScalar(value) {
  const raw = value.trim();
  if (!raw) return "";
  if ((raw.startsWith('"') && raw.endsWith('"')) || (raw.startsWith("'") && raw.endsWith("'"))) {
    return raw.slice(1, -1);
  }
  if (raw === "true") return true;
  if (raw === "false") return false;
  if (raw === "null" || raw === "None") return null;
  if (/^-?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(raw)) return Number(raw);
  return raw;
}

function parseInlineMap(value) {
  const raw = value.trim();
  if (!raw.startsWith("{") || !raw.endsWith("}")) return null;
  const out = {};
  for (const part of raw.slice(1, -1).split(",")) {
    const idx = part.indexOf(":");
    if (idx < 0) continue;
    const key = part.slice(0, idx).trim().replace(/^['"]|['"]$/g, "");
    out[key] = parseScalar(part.slice(idx + 1));
  }
  return out;
}

function parseSimpleYaml(file) {
  if (!fs.existsSync(file)) return {};
  const out = {};
  let currentMap = "";
  for (const rawLine of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const line = stripYamlComment(rawLine);
    if (!line.trim()) continue;

    const top = line.match(/^([A-Za-z0-9_.-]+):\s*(.*)$/);
    if (top) {
      const key = top[1];
      const value = top[2].trim();
      if (!value) {
        out[key] = {};
        currentMap = key;
      } else {
        out[key] = parseInlineMap(value) || parseScalar(value);
        currentMap = "";
      }
      continue;
    }

    const nested = line.match(/^\s+([A-Za-z0-9_.-]+):\s*(.*)$/);
    if (nested && currentMap && out[currentMap] && typeof out[currentMap] === "object") {
      out[currentMap][nested[1]] = parseInlineMap(nested[2]) || parseScalar(nested[2]);
    }
  }
  return out;
}

function safeStat(file) {
  try {
    return fs.statSync(file);
  } catch {
    return null;
  }
}

function safeLstat(file) {
  try {
    return fs.lstatSync(file);
  } catch {
    return null;
  }
}

function safeRealpath(file) {
  try {
    return fs.realpathSync(file);
  } catch {
    return "";
  }
}

function isDir(file) {
  const stat = safeStat(file);
  return Boolean(stat && stat.isDirectory());
}

function listDirs(dir) {
  try {
    return fs.readdirSync(dir)
      .map((name) => path.join(dir, name))
      .filter((entry) => isDir(entry));
  } catch {
    return [];
  }
}

function runSortKey(runDir) {
  const name = path.basename(runDir);
  const match = name.match(/^run_(\d{8})_(\d{6})$/);
  if (match) return `${match[1]}${match[2]}`;
  const stat = safeStat(runDir);
  return String(Math.floor(stat ? stat.mtimeMs : 0)).padStart(14, "0");
}

function sortRunsNewestFirst(runs) {
  return [...runs].sort((a, b) => runSortKey(b).localeCompare(runSortKey(a)));
}

function runDirsForPaper(paperDir) {
  return sortRunsNewestFirst(listDirs(path.join(paperDir, "runs")).filter((entry) => path.basename(entry).startsWith("run_")));
}

function discoverPapers(data, paperFilter = "", repairLatest = false) {
  const papersRoot = path.join(data, "papers");
  const papers = listDirs(papersRoot)
    .filter((paperDir) => !paperFilter || path.basename(paperDir) === paperFilter)
    .map((paperDir) => {
      if (repairLatest) syncLatestForPaper(paperDir);
      return {
        name: path.basename(paperDir),
        dir: paperDir,
        runs: runDirsForPaper(paperDir),
      };
    })
    .filter((paper) => paper.runs.length > 0);
  return papers.sort((a, b) => a.name.localeCompare(b.name));
}

function newestRunForPaper(paperDir) {
  return runDirsForPaper(paperDir)[0] || "";
}

function syncLatestForPaper(paperDir) {
  const newest = newestRunForPaper(paperDir);
  if (!newest) return false;

  const latest = path.join(paperDir, "runs", "latest");
  const current = safeRealpath(latest);
  if (current === newest) return false;

  const stat = safeLstat(latest);
  if (stat && !stat.isSymbolicLink()) return false;

  try {
    if (stat) fs.unlinkSync(latest);
    fs.symlinkSync(newest, latest, "dir");
    return true;
  } catch {
    return false;
  }
}

function latestRunForPaper(paperDir) {
  const latest = path.join(paperDir, "runs", "latest");
  const resolved = safeRealpath(latest);
  if (resolved && isDir(resolved) && path.basename(resolved).startsWith("run_")) {
    return resolved;
  }
  return newestRunForPaper(paperDir);
}

function readJsonl(file) {
  if (!fs.existsSync(file)) return [];
  const records = [];
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      records.push(JSON.parse(line));
    } catch {
      // Keep inspection usable if a trailing write is incomplete.
    }
  }
  return records;
}

function configForRun(runDir) {
  const paperDir = path.dirname(path.dirname(runDir));
  const candidates = [
    path.join(runDir, "logs", "effective_config.yaml"),
    path.join(paperDir, "config.yaml"),
  ];
  for (const file of candidates) {
    if (fs.existsSync(file)) return { file, data: parseSimpleYaml(file) };
  }
  return { file: "", data: {} };
}

function numeric(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() && Number.isFinite(Number(value))) return Number(value);
  return null;
}

function recordIter(record) {
  const value = record.iter ?? record.iteration ?? record.step;
  return numeric(value);
}

function recordMetric(record, primaryMetric) {
  const direct = numeric(record.primary_metric);
  if (direct !== null) return direct;
  if (primaryMetric && record.metrics && typeof record.metrics === "object") {
    return numeric(record.metrics[primaryMetric]);
  }
  return null;
}

function inferPrimaryMetric(cfg, records) {
  if (cfg.primary_metric) return String(cfg.primary_metric);
  for (const record of records) {
    if (record.metrics && typeof record.metrics === "object") {
      const keys = Object.keys(record.metrics);
      if (keys.length === 1) return keys[0];
      if (keys.includes("external_target_mean_auc")) return "external_target_mean_auc";
    }
  }
  return "primary_metric";
}

function inferLowerIsBetter(cfg, records) {
  const direction = String(cfg.metric_direction || "").trim().toLowerCase();
  if (direction === "lower" || direction === "minimize") return true;
  if (direction === "higher" || direction === "maximize") return false;
  for (const record of records) {
    if (typeof record.lower_is_better === "boolean") return record.lower_is_better;
    if (typeof record.lower_is_better === "string") return record.lower_is_better.toLowerCase() === "true";
  }
  return false;
}

function baselineInfo(cfg, records, primaryMetric) {
  const metrics = cfg.baseline_metrics;
  if (metrics && typeof metrics === "object") {
    const value = numeric(metrics[primaryMetric]);
    if (value !== null) return { value, source: "effective_config.yaml", record: null };
  }

  const baselineRecord = records.find((record) => {
    const idea = String(record.idea_id || "").toLowerCase();
    const iter = recordIter(record);
    return idea === "baseline" || iter === 0;
  });
  if (baselineRecord) {
    const value = recordMetric(baselineRecord, primaryMetric);
    if (value !== null) return { value, source: "scores.jsonl", record: baselineRecord };
  }

  for (const record of records) {
    const value = recordMetric(record, primaryMetric);
    if (value !== null) return { value, source: "scores.jsonl first score (inferred)", record };
  }
  return { value: null, source: "missing", record: null };
}

function bestInfo(records, primaryMetric, lowerIsBetter) {
  const candidates = records
    .map((record) => ({ record, value: recordMetric(record, primaryMetric) }))
    .filter((entry) => entry.value !== null && String(entry.record.status || "success") === "success");
  if (candidates.length === 0) return { record: null, value: null };
  return candidates.reduce((best, entry) => {
    if (!best) return entry;
    return lowerIsBetter ? (entry.value < best.value ? entry : best) : (entry.value > best.value ? entry : best);
  }, null);
}

function formatNumber(value, digits = 6) {
  if (value === null || value === undefined || !Number.isFinite(Number(value))) return "-";
  return Number(value).toFixed(digits).replace(/0+$/, "").replace(/\.$/, "");
}

function improvementPct(value, baseline, lowerIsBetter) {
  if (value === null || baseline === null || baseline === 0) return null;
  const pct = lowerIsBetter ? ((baseline - value) / Math.abs(baseline)) * 100 : ((value - baseline) / Math.abs(baseline)) * 100;
  return pct;
}

function formatPct(value) {
  if (value === null || value === undefined || !Number.isFinite(Number(value))) return "-";
  const sign = value > 0 ? "+" : "";
  return `${sign}${value.toFixed(2)}%`;
}

function runStarted(runDir) {
  const name = path.basename(runDir);
  const match = name.match(/^run_(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})$/);
  if (!match) return "";
  return `${match[1]}-${match[2]}-${match[3]} ${match[4]}:${match[5]}:${match[6]}`;
}

function readProcessLines() {
  if (process.platform === "win32") return [];
  const res = spawnSync("ps", ["-eo", "pid=,ppid=,args="], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (res.status !== 0) return [];
  return String(res.stdout || "").split(/\r?\n/).filter(Boolean);
}

function isRelevantProcess(line) {
  return (
    line.includes("autosota") ||
    line.includes("optimizer/scripts/run.py") ||
    line.includes("/scripts/run.py") ||
    line.includes("codex exec") ||
    line.includes("codex-shim-bin/claude")
  );
}

function computeActiveRuns(workspace, papers) {
  const lines = readProcessLines().filter(isRelevantProcess);
  const active = new Map();
  const workspaceActivePapers = new Set();
  let workspaceActive = false;

  for (const paper of papers) {
    for (const runDir of paper.runs) {
      const line = lines.find((entry) => entry.includes(runDir));
      if (line) active.set(runDir, "process references run dir");
    }
  }

  for (const line of lines) {
    if (!workspace || !line.includes(workspace)) continue;
    if (line.includes("autosota") || line.includes("optimizer/scripts/run.py") || line.includes("/scripts/run.py")) {
      workspaceActive = true;
    }
    for (const paper of papers) {
      if (line.includes(`run.py ${paper.name}`)) {
        workspaceActivePapers.add(paper.name);
      }
    }
  }

  for (const paper of papers) {
    if (!workspaceActivePapers.has(paper.name)) continue;
    const alreadyDirect = paper.runs.some((runDir) => active.has(runDir));
    if (alreadyDirect) continue;
    const newestIncomplete = paper.runs.find((runDir) => !fs.existsSync(path.join(runDir, "results", "final_report.md")));
    if (newestIncomplete) active.set(newestIncomplete, "workspace optimizer process is active");
  }

  if (active.size === 0 && workspaceActive) {
    const newestIncomplete = sortRunsNewestFirst(papers.flatMap((paper) => paper.runs))
      .find((runDir) => !fs.existsSync(path.join(runDir, "results", "final_report.md")));
    if (newestIncomplete) active.set(newestIncomplete, "workspace autosota process is active");
  }

  return active;
}

function analyzeRun(runDir, activeRuns = new Map()) {
  const { file: configFile, data: cfg } = configForRun(runDir);
  const records = readJsonl(path.join(runDir, "results", "scores.jsonl"));
  const primaryMetric = inferPrimaryMetric(cfg, records);
  const lowerIsBetter = inferLowerIsBetter(cfg, records);
  const baseline = baselineInfo(cfg, records, primaryMetric);
  const best = bestInfo(records, primaryMetric, lowerIsBetter);
  const finalReport = path.join(runDir, "results", "final_report.md");
  const curve = path.join(runDir, "results", "optimization_curve.png");
  const scores = path.join(runDir, "results", "scores.jsonl");
  const activeReason = activeRuns.get(runDir) || "";

  let status = "aborted";
  if (activeReason) status = "running";
  else if (fs.existsSync(path.join(runDir, "paused.flag"))) status = "paused";
  else if (fs.existsSync(finalReport)) status = "complete";
  else if (records.length === 0) status = "empty";

  const trialRecords = records.filter((record) => {
    const idea = String(record.idea_id || "").toLowerCase();
    const iter = recordIter(record);
    return idea !== "baseline" && iter !== 0;
  });
  const iters = trialRecords.map(recordIter).filter((value) => value !== null);
  const lastIter = iters.length ? Math.max(...iters) : null;

  return {
    runDir,
    runName: path.basename(runDir),
    paperName: path.basename(path.dirname(path.dirname(runDir))),
    started: runStarted(runDir),
    status,
    activeReason,
    configFile,
    cfg,
    records,
    primaryMetric,
    lowerIsBetter,
    baseline,
    best,
    targetValue: numeric(cfg.target_value),
    targetImprovementPct: numeric(cfg.target_improvement_pct),
    maxIterations: numeric(cfg.max_iterations),
    progressCount: trialRecords.length || records.length,
    lastIter,
    files: { scores, curve, finalReport },
  };
}

function resolvedLatestName(paperDir) {
  const runDir = latestRunForPaper(paperDir);
  return runDir ? path.basename(runDir) : "";
}

function pad(value, width) {
  const s = String(value);
  return s.length >= width ? s : s + " ".repeat(width - s.length);
}

function visibleLength(value) {
  return String(value).replace(/\x1b\[[0-9;]*m/g, "").length;
}

function padVisible(value, width) {
  const s = String(value);
  const len = visibleLength(s);
  return len >= width ? s : s + " ".repeat(width - len);
}

function formatStartedMinute(value) {
  return value ? value.slice(0, 16) : "";
}

function statusCell(status) {
  if (status === "running") return `${yellow("⚡")} ${yellow("running")}`;
  if (status === "complete") return `${green("✓")} ${green("complete")}`;
  if (status === "empty") return `${dim("○")} ${dim("empty")}`;
  if (status === "paused") return `${yellow("Ⅱ")} ${yellow("paused")}`;
  return `${yellow("~")} ${yellow(status || "aborted")}`;
}

function deltaCell(value) {
  const formatted = value === 0 ? "+0.00%" : formatPct(value);
  if (formatted === "-") return "";
  if (value > 0) return green(formatted);
  if (value < 0) return red(formatted);
  return dim(formatted);
}

function bestCell(summary) {
  if (summary.best.value === null) return dim("—");
  const best = Number(summary.best.value).toFixed(4);
  const delta = deltaCell(improvementPct(summary.best.value, summary.baseline.value, summary.lowerIsBetter));
  return delta ? `${best}  ${delta}` : best;
}

function runToJson(summary, latestName) {
  return {
    paper: summary.paperName,
    run: summary.runName,
    dir: summary.runDir,
    latest: summary.runName === latestName,
    status: summary.status,
    active_reason: summary.activeReason || null,
    primary_metric: summary.primaryMetric,
    metric_direction: summary.lowerIsBetter ? "lower" : "higher",
    baseline: summary.baseline,
    best: summary.best.value === null ? null : {
      value: summary.best.value,
      iter: summary.best.record ? recordIter(summary.best.record) : null,
      idea_id: summary.best.record ? summary.best.record.idea_id || null : null,
      delta_pct: improvementPct(summary.best.value, summary.baseline.value, summary.lowerIsBetter),
    },
    progress: {
      completed: summary.progressCount,
      max_iterations: summary.maxIterations,
      last_iter: summary.lastIter,
    },
    files: summary.files,
  };
}

function sessionsCmd(args, context = {}) {
  const parsed = parseArgs(args);
  const { workspace, data } = workspacePaths(context);
  const papers = discoverPapers(data, parsed.options.paper || "", true);
  if (papers.length === 0) {
    console.log(`No autosota runs found under ${path.join(data, "papers")}`);
    return;
  }

  const activeRuns = computeActiveRuns(workspace, papers);
  const rows = [];
  for (const paper of papers) {
    const latestName = resolvedLatestName(paper.dir);
    for (const runDir of paper.runs) {
      const summary = analyzeRun(runDir, activeRuns);
      rows.push({ summary, latestName });
    }
  }

  if (parsed.flags.has("--json")) {
    console.log(JSON.stringify(rows.map(({ summary, latestName }) => runToJson(summary, latestName)), null, 2));
    return;
  }

  console.log(`${bold("autosota sessions")} ${dim(`(${workspace})`)}`);
  console.log("");
  console.log(bold(`  ${pad("Paper", 13)} ${pad("Run", 27)} ${pad("Started", 16)}   ${pad("Status", 15)} ${pad("Iters", 9)} Best (Δ vs baseline)`));
  console.log(dim(`  ${"─".repeat(114)}`));
  for (const { summary, latestName } of rows) {
    const run = `${summary.runName}${summary.runName === latestName ? dim(" (latest)") : ""}`;
    const progressMax = summary.maxIterations === null ? "?" : String(summary.maxIterations);
    const progress = `${summary.progressCount}/${progressMax}`;
    console.log(`  ${pad(summary.paperName, 13)} ${padVisible(run, 27)} ${pad(formatStartedMinute(summary.started), 16)}   ${padVisible(statusCell(summary.status), 15)} ${pad(progress, 9)} ${bestCell(summary)}`);
  }
}

function resolveRunTarget(target, papers, paperOption = "") {
  if (target && path.isAbsolute(target) && isDir(target)) return target;
  if (!target || target === "latest") {
    const candidates = paperOption ? papers.filter((paper) => paper.name === paperOption) : papers;
    const latestRuns = candidates.map((paper) => latestRunForPaper(paper.dir)).filter(Boolean);
    return sortRunsNewestFirst(latestRuns)[0] || "";
  }
  if (target.startsWith("run_")) {
    for (const paper of papers) {
      const found = paper.runs.find((runDir) => path.basename(runDir) === target);
      if (found) return found;
    }
  }
  const paper = papers.find((entry) => entry.name === target);
  if (paper) return latestRunForPaper(paper.dir);
  return "";
}

function printFileIfRequested(summary, flags) {
  const requests = [
    ["--scores", summary.files.scores],
    ["--prompt", path.join(summary.runDir, "logs", "master_prompt.md")],
    ["--report", summary.files.finalReport],
  ];
  for (const [flag, file] of requests) {
    if (!flags.has(flag)) continue;
    if (!fs.existsSync(file)) die(`requested file is missing: ${file}`);
    const content = fs.readFileSync(file, "utf8");
    process.stdout.write(content);
    if (!content.endsWith("\n")) process.stdout.write("\n");
    return true;
  }
  return false;
}

function inspectCmd(args, context = {}) {
  const parsed = parseArgs(args);
  const { workspace, data } = workspacePaths(context);
  const papers = discoverPapers(data, parsed.options.paper || "", true);
  if (papers.length === 0) die(`no autosota runs found under ${path.join(data, "papers")}`);

  const target = parsed.positionals[0] || "latest";
  const runDir = resolveRunTarget(target, papers, parsed.options.paper || "");
  if (!runDir) die(`could not resolve run target: ${target}`);

  const activeRuns = computeActiveRuns(workspace, papers);
  const summary = analyzeRun(runDir, activeRuns);
  const latestName = resolvedLatestName(path.dirname(path.dirname(runDir)));

  if (parsed.flags.has("--json")) {
    console.log(JSON.stringify(runToJson(summary, latestName), null, 2));
    return;
  }
  if (printFileIfRequested(summary, parsed.flags)) return;

  console.log(bold(`autosota inspect: ${summary.paperName}/${summary.runName}${summary.runName === latestName ? " (latest)" : ""}`));
  console.log(`Dir: ${summary.runDir}`);
  if (summary.started) console.log(`Started: ${summary.started}`);
  console.log(`Status: ${summary.status}${summary.activeReason ? ` (${summary.activeReason})` : ""}`);
  console.log(`Primary metric: ${summary.primaryMetric} (${summary.lowerIsBetter ? "lower is better" : "higher is better"})`);
  console.log(`Baseline: ${formatNumber(summary.baseline.value, 12)} (${summary.baseline.source})`);
  if (summary.targetValue !== null) {
    const targetDelta = summary.targetImprovementPct !== null
      ? summary.targetImprovementPct
      : improvementPct(summary.targetValue, summary.baseline.value, summary.lowerIsBetter);
    console.log(`Target: ${formatNumber(summary.targetValue, 12)} (${formatPct(targetDelta)} vs baseline)`);
  }
  if (summary.best.value !== null) {
    const bestIter = summary.best.record ? recordIter(summary.best.record) : null;
    const bestTitle = summary.best.record ? summary.best.record.idea_title || summary.best.record.idea_id || "" : "";
    console.log(`Best: ${formatNumber(summary.best.value, 12)} (${formatPct(improvementPct(summary.best.value, summary.baseline.value, summary.lowerIsBetter))}${bestIter === null ? "" : `, iter ${bestIter}`}${bestTitle ? `, ${bestTitle}` : ""})`);
  }

  console.log("");
  console.log(`${pad("iter", 6)} ${pad("metric", 12)} ${pad("delta", 9)} ${pad("status", 8)} idea`);
  console.log(`${"-".repeat(6)} ${"-".repeat(12)} ${"-".repeat(9)} ${"-".repeat(8)} ${"-".repeat(40)}`);
  for (const record of summary.records) {
    const value = recordMetric(record, summary.primaryMetric);
    const iter = recordIter(record);
    const delta = improvementPct(value, summary.baseline.value, summary.lowerIsBetter);
    const marks = [];
    if (record === summary.best.record) marks.push("best");
    if (record === summary.baseline.record) marks.push(summary.baseline.source.includes("inferred") ? "baseline inferred" : "baseline");
    const idea = [record.idea_id, record.idea_title].filter(Boolean).join(" ");
    const suffix = marks.length ? ` (${marks.join(", ")})` : "";
    console.log(`${pad(iter === null ? "-" : iter, 6)} ${pad(formatNumber(value, 6), 12)} ${pad(formatPct(delta), 9)} ${pad(record.status || "-", 8)} ${idea}${suffix}`);
  }

  console.log("");
  console.log("Files:");
  for (const [label, file] of Object.entries(summary.files)) {
    console.log(`  ${fs.existsSync(file) ? "OK     " : "MISSING"} ${label}: ${file}`);
  }
}

module.exports = { sessionsCmd, inspectCmd };
