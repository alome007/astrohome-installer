#!/usr/bin/env node
// AstroHome setup GUI — local bootstrap server.
//
// Serves the wizard page and drives the real installer (install.sh in
// non-interactive engine mode) with the values the wizard collects. Runs
// BEFORE the repo exists, so it depends on the Node standard library only.
//
//   node server.mjs [--local-repo <checkout>] [--base <raw-url>]
//                   [--port <n>] [--no-open]
//
// --local-repo: read install.sh / .env.example from an existing checkout
//   (development and `bash install.sh` from a clone). Without it, both are
//   fetched from --base (the public installer repo's raw URL).
//
// Security: binds 127.0.0.1 only; every route lives under a random token
// prefix so other local pages can't drive the API blind.

import { spawn, execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  openSync,
  readSync,
  closeSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { homedir, platform, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const argValue = (flag) => {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] !== undefined ? args[i + 1] : null;
};
const LOCAL_REPO = argValue("--local-repo");
const BASE_URL =
  argValue("--base") ?? "https://raw.githubusercontent.com/alome007/astrohome-installer/main";
const PORT = Number(argValue("--port") ?? 8423);
const NO_OPEN = args.includes("--no-open");

const HERE = dirname(fileURLToPath(import.meta.url));
const TOKEN = randomBytes(12).toString("hex");
const WORK = join(tmpdir(), `astro-setup-${TOKEN.slice(0, 6)}`);
mkdirSync(WORK, { recursive: true });

const state = {
  phase: "collect",
  log: [],
  exitCode: null,
  config: null,
  child: null,
};
const sseClients = new Set();

function pushLog(line) {
  state.log.push(line);
  if (state.log.length > 5000) state.log.splice(0, 1000);
  const payload = `data: ${JSON.stringify(line)}\n\n`;
  for (const res of sseClients) res.write(payload);
}

async function fetchText(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`GET ${url} → ${res.status}`);
  return res.text();
}

async function loadAsset(name) {
  if (LOCAL_REPO !== null) {
    const candidates =
      name === "install.sh"
        ? [join(LOCAL_REPO, "install.sh")]
        : name === "env.example"
          ? [join(LOCAL_REPO, ".env.example"), join(LOCAL_REPO, "env.example")]
          : [join(LOCAL_REPO, "scripts/install/setup-gui", name), join(HERE, name)];
    for (const c of candidates) if (existsSync(c)) return readFileSync(c, "utf8");
    throw new Error(`asset not found locally: ${name}`);
  }
  const local = join(HERE, name);
  if (existsSync(local)) return readFileSync(local, "utf8");
  return fetchText(`${BASE_URL}/${name}`);
}

function classifyDir(path) {
  if (!existsSync(path)) return "missing";
  if (existsSync(join(path, ".git"))) return "checkout";
  let entries;
  try {
    entries = readdirSync(path);
  } catch {
    return "occupied";
  }
  if (entries.length === 0) return "empty";
  return "occupied";
}

function looksLikeSqlite(path) {
  try {
    const fd = openSync(path, "r");
    const buf = Buffer.alloc(16);
    readSync(fd, buf, 0, 16, 0);
    closeSync(fd);
    return buf.toString("utf8", 0, 15) === "SQLite format 3";
  } catch {
    return false;
  }
}

function describeDb(path) {
  const st = statSync(path);
  return {
    path,
    sizeMb: Math.round((st.size / 1024 / 1024) * 10) / 10,
    modified: st.mtime.toISOString(),
    valid: looksLikeSqlite(path),
  };
}

// A restore source the wizard can offer: a db inside a dir, a bare db, or a
// backups dir with dated snapshots. Mirrors restore-data.sh's dispatch.
function inspectRestoreSource(raw) {
  const path = raw.startsWith("~/") ? join(homedir(), raw.slice(2)) : raw;
  if (!existsSync(path)) return { ok: false, reason: "not found", path };
  const st = statSync(path);
  if (st.isFile()) {
    if (path.endsWith(".db")) {
      const db = describeDb(path);
      return db.valid
        ? { ok: true, kind: "snapshot", path, db }
        : { ok: false, reason: "not a SQLite database", path };
    }
    if (path.endsWith(".tar.gz") || path.endsWith(".tgz")) {
      return { ok: true, kind: "archive", path };
    }
    return { ok: false, reason: "expected a .db snapshot, .tar.gz, or a directory", path };
  }
  for (const candidate of [join(path, "astrohome.db"), join(path, "data", "astrohome.db")]) {
    if (existsSync(candidate)) {
      const db = describeDb(candidate);
      return db.valid
        ? { ok: true, kind: "data-dir", path, db }
        : { ok: false, reason: `${candidate} is not a SQLite database`, path };
    }
  }
  let snaps = [];
  try {
    snaps = readdirSync(path).filter((f) => f.startsWith("astrohome-") && f.endsWith(".db"));
  } catch {
    return { ok: false, reason: "unreadable directory", path };
  }
  if (snaps.length > 0) {
    const newest = snaps
      .map((f) => join(path, f))
      .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0];
    const db = describeDb(newest);
    return { ok: true, kind: "backups-dir", path, db };
  }
  return { ok: false, reason: "no astrohome.db or snapshots found here", path };
}

function detectPriorData() {
  const found = [];
  for (const base of [
    join(homedir(), "astrohome"),
    join(homedir(), "astrohome-core"),
    "/opt/astrohome",
  ]) {
    const probe = inspectRestoreSource(base);
    if (probe.ok) found.push(probe);
  }
  return found;
}

// .env.example is the single source of truth for the env form: tags become
// field behavior (#REQUIRED, #REQUIRED-ONE-OF, #GEN), comments become help
// text, values become defaults. The wizard stays in sync with the file.
function parseEnvTemplate(text) {
  const fields = [];
  let section = "";
  let help = [];
  let tag = "";
  let group = 0;
  for (const line of text.split("\n")) {
    const sectionMatch = line.match(/^# ----\s*(.+?)\s*----/);
    if (sectionMatch !== null) {
      section = sectionMatch[1];
      help = [];
      tag = "";
      continue;
    }
    if (line === "#REQUIRED" || line === "#GEN") {
      tag = line.slice(1);
      continue;
    }
    if (line === "#REQUIRED-ONE-OF") {
      tag = "REQUIRED-ONE-OF";
      group += 1;
      continue;
    }
    if (line.startsWith("#")) {
      help.push(line.replace(/^#\s?/, ""));
      continue;
    }
    if (line.trim() === "") {
      help = [];
      tag = "";
      continue;
    }
    const eq = line.indexOf("=");
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    const value = line.slice(eq + 1).trim();
    const field = {
      key,
      default: value,
      section,
      help: help.join("\n"),
      tag,
      ...(tag === "REQUIRED-ONE-OF" ? { group } : {}),
    };
    if (tag === "GEN") field.generated = randomBytes(32).toString("hex");
    fields.push(field);
    help = [];
    if (tag !== "REQUIRED-ONE-OF") tag = "";
  }
  return fields;
}

function buildEnvFile(template, values) {
  const lines = ["# Generated by the AstroHome setup wizard"];
  let section = "";
  for (const field of template) {
    const value = values[field.key] ?? field.generated ?? field.default ?? "";
    if (value === "") continue;
    if (field.section !== section) {
      section = field.section;
      lines.push("", `# ---- ${section} ----`);
    }
    lines.push(`${field.key}=${value}`);
  }
  lines.push("");
  return lines.join("\n");
}

async function verifyGithub(owner, token) {
  const res = await fetch(`https://api.github.com/repos/${owner}/astrohome-core`, {
    headers: { authorization: `Bearer ${token}`, "user-agent": "astrohome-setup" },
  });
  return { ok: res.status === 200, status: res.status };
}

async function startInstall(config) {
  state.phase = "installing";
  state.config = config;

  const installSh = join(WORK, "install.sh");
  writeFileSync(installSh, await loadAsset("install.sh"), { mode: 0o755 });
  const envFile = join(WORK, "env");
  writeFileSync(envFile, buildEnvFile(state.envTemplate, config.env ?? {}), { mode: 0o600 });

  const env = {
    ...process.env,
    ASTROHOME_NO_GUI: "1",
    ASTROHOME_NONINTERACTIVE: "1",
    ASTROHOME_DIR: config.installDir,
    ASTROHOME_OWNER: config.owner,
    GH_TOKEN: config.token,
    ASTROHOME_ENV_FILE: envFile,
    ...(config.restoreFrom ? { ASTROHOME_RESTORE_FROM: config.restoreFrom } : {}),
    ...(config.restoreFrom ? {} : { ASTROHOME_SKIP_RESTORE: "1" }),
    ...(config.tunnel?.domain ? { ASTROHOME_DOMAIN: config.tunnel.domain } : {}),
    ...(config.tunnel?.token ? { ASTROHOME_TUNNEL_TOKEN: config.tunnel.token } : {}),
    ...(config.tunnel ? {} : { ASTROHOME_SKIP_TUNNEL: "1" }),
    ...(LOCAL_REPO !== null ? { ASTROHOME_REPO: LOCAL_REPO } : {}),
  };

  pushLog("[setup] starting install engine");
  const child = spawn("bash", [installSh], { env, cwd: WORK });
  state.child = child;
  const forward = (chunk) => {
    for (const line of chunk.toString().split("\n")) {
      if (line.trim().length > 0) pushLog(line);
    }
  };
  child.stdout.on("data", forward);
  child.stderr.on("data", forward);
  child.on("close", (code) => {
    state.exitCode = code;
    state.phase = code === 0 ? "done" : "failed";
    pushLog(`[setup] installer exited with code ${code}`);
    for (const res of sseClients) res.end();
  });
}

function json(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString() || "{}");
}

const PAGE = await loadAsset("index.html");
const ENV_TEMPLATE_TEXT = await loadAsset("env.example");
state.envTemplate = parseEnvTemplate(ENV_TEMPLATE_TEXT);

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  const parts = url.pathname.split("/").filter(Boolean);
  if (parts[0] !== TOKEN) {
    res.writeHead(404);
    res.end("not found");
    return;
  }
  const route = `/${parts.slice(1).join("/")}`;

  try {
    if (route === "/" && req.method === "GET") {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(PAGE.replace("__SETUP_TOKEN__", TOKEN));
      return;
    }
    if (route === "/api/state" && req.method === "GET") {
      json(res, 200, {
        phase: state.phase,
        platform: platform(),
        home: homedir(),
        defaultDir:
          classifyDir(join(homedir(), "astrohome")) === "occupied"
            ? join(homedir(), "astrohome-core")
            : join(homedir(), "astrohome"),
        priorData: detectPriorData(),
        envTemplate: state.envTemplate,
        log: state.log,
        exitCode: state.exitCode,
      });
      return;
    }
    if (route === "/api/validate-dir" && req.method === "POST") {
      const { path } = await readBody(req);
      const expanded = path.startsWith("~/") ? join(homedir(), path.slice(2)) : resolve(path);
      const kind = classifyDir(expanded);
      const prior =
        kind === "occupied" &&
        (existsSync(join(expanded, "data")) || existsSync(join(expanded, ".env")));
      json(res, 200, { path: expanded, kind, priorDeployment: prior });
      return;
    }
    if (route === "/api/verify-token" && req.method === "POST") {
      const { owner, token } = await readBody(req);
      json(res, 200, await verifyGithub(owner, token));
      return;
    }
    if (route === "/api/inspect-restore" && req.method === "POST") {
      const { path } = await readBody(req);
      json(res, 200, inspectRestoreSource(path));
      return;
    }
    if (route === "/api/install" && req.method === "POST") {
      if (state.phase === "installing") {
        json(res, 409, { error: "install already running" });
        return;
      }
      const config = await readBody(req);
      await startInstall(config);
      json(res, 200, { started: true });
      return;
    }
    if (route === "/api/progress" && req.method === "GET") {
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
      });
      for (const line of state.log) res.write(`data: ${JSON.stringify(line)}\n\n`);
      if (state.phase === "done" || state.phase === "failed") {
        res.end();
        return;
      }
      sseClients.add(res);
      req.on("close", () => sseClients.delete(res));
      return;
    }
    if (route === "/api/result" && req.method === "GET") {
      json(res, 200, { phase: state.phase, exitCode: state.exitCode });
      return;
    }
    res.writeHead(404);
    res.end("not found");
  } catch (err) {
    json(res, 500, { error: err instanceof Error ? err.message : String(err) });
  }
});

server.listen(PORT, "127.0.0.1", () => {
  const url = `http://127.0.0.1:${PORT}/${TOKEN}/`;
  console.log(`[setup] wizard ready at ${url}`);
  if (!NO_OPEN) {
    const opener = platform() === "darwin" ? "open" : "xdg-open";
    execFile(opener, [url], () => {});
  }
});

// The server's job ends when the wizard finishes (or the user abandons it).
setInterval(() => {
  if ((state.phase === "done" || state.phase === "failed") && sseClients.size === 0) {
    setTimeout(() => process.exit(state.exitCode === 0 ? 0 : 1), 15_000).unref();
  }
}, 5_000).unref();
