#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const { WebSocket } = require("ws");

const rootDir = path.resolve(__dirname, "..");
const testName = "real-offline-codex-pagination";
const fixtureThreadCount = 125;
const pageSize = 100;
const threadSource = "synthetic-pagination-test";
const allowedRpcMethods = new Set([
  "initialize",
  "thread/start",
  "thread/name/set",
  "thread/list",
  "thread/read",
]);

function usage() {
  return [
    "Usage: node test/real-pagination-smoke.cjs [options]",
    "",
    "Options:",
    "  --candidate-manifest <path>   Candidate manifest (default: compatibility/candidate.json)",
    "  --candidate-cache-root <path> Candidate cache root (default: %ProgramData%\\CodexShimCI\\candidates)",
    "  --output <path>               Structured JSON report path",
    "  --keep-fixture                Retain the isolated temporary fixture",
    "  --timeout-ms <milliseconds>   Per-operation timeout (default: 60000)",
    "  --self-test                   Run built-in helper checks without starting Codex",
    "  --help                        Show this help",
  ].join("\n");
}

function parseArgs(argv) {
  const programData = process.env.ProgramData || "C:\\ProgramData";
  const options = {
    candidateManifest: path.join(rootDir, "compatibility", "candidate.json"),
    candidateCacheRoot:
      process.env.CODEX_CI_CACHE_ROOT || path.join(programData, "CodexShimCI", "candidates"),
    output: path.join(rootDir, "artifacts", "real-pagination-smoke.json"),
    keepFixture: false,
    timeoutMs: 60_000,
    selfTest: false,
    help: false,
  };
  const valueOptions = new Map([
    ["--candidate-manifest", "candidateManifest"],
    ["--manifest", "candidateManifest"],
    ["--candidate-cache-root", "candidateCacheRoot"],
    ["--cache-root", "candidateCacheRoot"],
    ["--output", "output"],
    ["--timeout-ms", "timeoutMs"],
  ]);

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--keep-fixture") {
      options.keepFixture = true;
      continue;
    }
    if (argument === "--self-test") {
      options.selfTest = true;
      continue;
    }
    if (argument === "--help" || argument === "-h") {
      options.help = true;
      continue;
    }
    const optionName = valueOptions.get(argument);
    if (!optionName) {
      throw new Error(`Unknown argument: ${argument}`);
    }
    index += 1;
    if (index >= argv.length || argv[index].startsWith("--")) {
      throw new Error(`${argument} requires a value.`);
    }
    options[optionName] = argv[index];
  }

  options.candidateManifest = path.resolve(options.candidateManifest);
  options.candidateCacheRoot = path.resolve(options.candidateCacheRoot);
  options.output = path.resolve(options.output);
  options.timeoutMs = Number(options.timeoutMs);
  if (!Number.isInteger(options.timeoutMs) || options.timeoutMs < 1_000) {
    throw new Error("--timeout-ms must be an integer of at least 1000.");
  }
  return options;
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function validateManifest(manifest) {
  if (!isPlainObject(manifest)) {
    throw new Error("Candidate manifest must be a JSON object.");
  }
  if (manifest.schemaVersion !== 1) {
    throw new Error(`Unsupported candidate manifest schemaVersion: ${manifest.schemaVersion}.`);
  }
  const cliSha256 = String(manifest.cliSha256 || "").toUpperCase();
  if (!/^[A-F0-9]{64}$/.test(cliSha256)) {
    throw new Error("Candidate manifest cliSha256 must contain 64 hexadecimal characters.");
  }
  const packageName = String(manifest.packageName || "");
  const packageVersion = String(manifest.packageVersion || "");
  if (!packageName || !packageVersion) {
    throw new Error("Candidate manifest packageName and packageVersion are required.");
  }
  return {
    packageName,
    packageVersion,
    packageFullName: String(manifest.packageFullName || ""),
    cliSha256,
    schemaVersion: manifest.schemaVersion,
  };
}

function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash("sha256");
    const stream = fs.createReadStream(filePath);
    stream.on("error", reject);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("end", () => resolve(hash.digest("hex").toUpperCase()));
  });
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function withTimeout(promise, timeoutMs, message) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), timeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function uuidV7(timestampMs = Date.now()) {
  if (!Number.isSafeInteger(timestampMs) || timestampMs < 0 || timestampMs > 0xffffffffffff) {
    throw new Error(`Invalid UUIDv7 timestamp: ${timestampMs}.`);
  }
  const bytes = crypto.randomBytes(16);
  let timestamp = BigInt(timestampMs);
  for (let index = 5; index >= 0; index -= 1) {
    bytes[index] = Number(timestamp & 0xffn);
    timestamp >>= 8n;
  }
  bytes[6] = 0x70 | (bytes[6] & 0x0f);
  bytes[8] = 0x80 | (bytes[8] & 0x3f);
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function isUuidV7(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value
  );
}

function deepClone(value) {
  return JSON.parse(JSON.stringify(value));
}

function replacePropertyDeep(value, propertyName, replacement) {
  let replacements = 0;
  if (Array.isArray(value)) {
    for (const item of value) {
      replacements += replacePropertyDeep(item, propertyName, replacement);
    }
    return replacements;
  }
  if (!isPlainObject(value)) {
    return replacements;
  }
  for (const [key, item] of Object.entries(value)) {
    if (key === propertyName) {
      value[key] = replacement;
      replacements += 1;
    } else {
      replacements += replacePropertyDeep(item, propertyName, replacement);
    }
  }
  return replacements;
}

function shouldRemoveFromChildEnv(name) {
  const upper = name.toUpperCase();
  if (/^(HTTP|HTTPS|ALL|NO)_PROXY$/.test(upper)) {
    return true;
  }
  if (
    /(API[_-]?KEY|ACCESS[_-]?KEY|SECRET[_-]?ACCESS[_-]?KEY|AUTH[_-]?TOKEN|BEARER[_-]?TOKEN|SESSION[_-]?TOKEN|CREDENTIALS?)/.test(
      upper
    )
  ) {
    return true;
  }
  if (/(^|[_-])(TOKEN|PASSWORD|SECRET)$/.test(upper)) {
    return true;
  }
  return /^(OPENAI|ANTHROPIC|AZURE_OPENAI|GEMINI|GOOGLE_GENERATIVE_AI|DEEPSEEK|OPENROUTER|MISTRAL|GROQ|COHERE|XAI|TOGETHER|FIREWORKS|PERPLEXITY|AWS_BEDROCK|BEDROCK)(_|$)/.test(
    upper
  ) || /^CODEX_(API|MODEL_PROVIDER|PROVIDER|BASE_URL|CHATGPT)/.test(upper);
}

function isolatedChildEnv(codexHome, extra = {}) {
  const env = {};
  let removedCount = 0;
  for (const [name, value] of Object.entries(process.env)) {
    const upperName = name.toUpperCase();
    if (upperName === "CODEX_HOME" || upperName === "CODEX_SQLITE_HOME") {
      continue;
    }
    if (shouldRemoveFromChildEnv(name)) {
      removedCount += 1;
      continue;
    }
    if (upperName.startsWith("CODEX_CATALOG_SHIM_")) {
      continue;
    }
    env[name] = value;
  }
  env.CODEX_HOME = codexHome;
  env.CODEX_SQLITE_HOME = codexHome;
  Object.assign(env, extra);
  return { env, removedCount };
}

function isPathInside(parentPath, childPath) {
  const relative = path.relative(path.resolve(parentPath), path.resolve(childPath));
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function sanitizeMessage(message, pathsToReplace) {
  let sanitized = String(message || "Unknown failure").replace(/[\r\n]+/g, " ").trim();
  for (const [rawPath, label] of pathsToReplace) {
    if (!rawPath) continue;
    sanitized = sanitized.split(rawPath).join(label);
    sanitized = sanitized.split(rawPath.replace(/\\/g, "/")).join(label);
  }
  sanitized = sanitized
    .replace(/\b[A-Za-z]:\\Users\\[^\\\s]+/gi, "<home>")
    .replace(/\/(?:home|Users)\/[^/\s]+/g, "<home>")
    .replace(/\b(?:Bearer\s+)?(?:sk-|sess-|key-)[A-Za-z0-9._-]{12,}\b/gi, "<redacted>");
  return sanitized.slice(0, 2_000);
}

function writeReport(reportPath, report) {
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
}

class CandidateAppServer {
  constructor({ cliPath, codexHome, cwd, label, timeoutMs, audit }) {
    this.cliPath = cliPath;
    this.codexHome = codexHome;
    this.cwd = cwd;
    this.label = label;
    this.timeoutMs = timeoutMs;
    this.audit = audit;
    this.nextId = 1;
    this.pending = new Map();
    this.stdoutBuffer = "";
    this.stderrTail = "";
    this.stopping = false;
    this.exitResult = null;
    this.child = null;
    this.removedEnvCount = 0;
  }

  async start() {
    const isolated = isolatedChildEnv(this.codexHome);
    this.removedEnvCount = isolated.removedCount;
    this.child = spawn(
      this.cliPath,
      ["-c", "features.code_mode_host=true", "app-server", "--analytics-default-enabled"],
      {
        cwd: this.cwd,
        env: isolated.env,
        stdio: ["pipe", "pipe", "pipe"],
        windowsHide: true,
      }
    );
    this.child.stdout.on("data", (chunk) => this.onStdout(chunk));
    this.child.stderr.on("data", (chunk) => {
      this.stderrTail = `${this.stderrTail}${chunk.toString()}`.slice(-32_768);
    });
    this.child.on("exit", (code, signal) => {
      this.exitResult = { code, signal: signal || null };
      const error = new Error(
        `${this.label} app-server exited (code=${code}, signal=${signal || "none"}).`
      );
      for (const pending of this.pending.values()) {
        clearTimeout(pending.timer);
        pending.reject(error);
      }
      this.pending.clear();
    });
    await withTimeout(
      new Promise((resolve, reject) => {
        this.child.once("spawn", resolve);
        this.child.once("error", reject);
      }),
      this.timeoutMs,
      `Timed out starting ${this.label} app-server.`
    );
  }

  onStdout(chunk) {
    this.stdoutBuffer += chunk.toString();
    let newlineIndex;
    while ((newlineIndex = this.stdoutBuffer.indexOf("\n")) >= 0) {
      const raw = this.stdoutBuffer.slice(0, newlineIndex).replace(/\r$/, "");
      this.stdoutBuffer = this.stdoutBuffer.slice(newlineIndex + 1);
      if (!raw.trim()) continue;
      let message;
      try {
        message = JSON.parse(raw);
      } catch (error) {
        const parseError = new Error(
          `${this.label} app-server wrote non-JSON stdout: ${raw.slice(0, 500)}`
        );
        for (const pending of this.pending.values()) {
          clearTimeout(pending.timer);
          pending.reject(parseError);
        }
        this.pending.clear();
        continue;
      }
      const pending = message.id == null ? null : this.pending.get(String(message.id));
      if (!pending) {
        if (message.id != null && message.method) {
          this.sendRaw({
            jsonrpc: "2.0",
            id: message.id,
            error: { code: -32601, message: "Offline compatibility client refuses server requests." },
          });
        }
        continue;
      }
      this.pending.delete(String(message.id));
      clearTimeout(pending.timer);
      if (message.error) {
        pending.reject(
          new Error(
            `${pending.method} failed (${message.error.code ?? "unknown"}): ${
              message.error.message || JSON.stringify(message.error)
            }`
          )
        );
      } else {
        pending.resolve(message.result);
      }
    }
  }

  sendRaw(message) {
    if (!this.child || !this.child.stdin.writable) {
      throw new Error(`${this.label} app-server stdin is not writable.`);
    }
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(method, params) {
    if (!allowedRpcMethods.has(method)) {
      throw new Error(`RPC method ${method} is not allowed in the offline compatibility test.`);
    }
    if (this.exitResult) {
      throw new Error(`${this.label} app-server already exited.`);
    }
    this.audit.push({ transport: "stdio", phase: this.label, method });
    const id = this.nextId;
    this.nextId += 1;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        reject(new Error(`Timed out waiting for ${method} from ${this.label} app-server.`));
      }, this.timeoutMs);
      this.pending.set(String(id), { resolve, reject, timer, method });
      this.sendRaw({ jsonrpc: "2.0", id, method, params });
    });
  }

  notify(method, params) {
    if (method !== "initialized") {
      throw new Error(`Notification ${method} is not allowed in the offline compatibility test.`);
    }
    this.audit.push({ transport: "stdio", phase: this.label, method });
    this.sendRaw({ jsonrpc: "2.0", method, params });
  }

  async stop() {
    if (!this.child || this.exitResult) return;
    this.stopping = true;
    if (this.child.stdin.writable) {
      this.child.stdin.end();
    }
    const exited = await Promise.race([
      new Promise((resolve) => this.child.once("exit", () => resolve(true))),
      sleep(5_000).then(() => false),
    ]);
    if (!exited && !this.exitResult) {
      await stopChild(this.child);
    }
  }
}

async function initializeClient(client) {
  await client.request("initialize", {
    clientInfo: {
      name: "catalog-shim-pagination-smoke",
      title: "Catalog Shim Pagination Smoke",
      version: "1.0.0",
    },
    capabilities: null,
  });
  client.notify("initialized", {});
}

function findFilesRecursive(directory, predicate) {
  if (!fs.existsSync(directory)) return [];
  const files = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...findFilesRecursive(entryPath, predicate));
    } else if (entry.isFile() && predicate(entryPath)) {
      files.push(entryPath);
    }
  }
  return files;
}

function readSessionMetaLine(rolloutPath) {
  const content = fs.readFileSync(rolloutPath, "utf8");
  for (const rawLine of content.split(/\r?\n/)) {
    if (!rawLine.trim()) continue;
    const line = JSON.parse(rawLine);
    if (line.type === "session_meta") {
      if (!isPlainObject(line.payload)) {
        throw new Error("Template session_meta payload is not an object.");
      }
      return line;
    }
  }
  throw new Error("Template rollout does not contain a session_meta line.");
}

function locateTemplateRollout(builderHome, threadId, advertisedPath) {
  const candidates = [];
  if (typeof advertisedPath === "string" && advertisedPath) {
    candidates.push(path.resolve(advertisedPath));
  }
  candidates.push(
    ...findFilesRecursive(
      path.join(builderHome, "sessions"),
      (filePath) => path.extname(filePath).toLowerCase() === ".jsonl"
    )
  );
  for (const candidate of [...new Set(candidates)]) {
    if (!isPathInside(builderHome, candidate) || !fs.existsSync(candidate)) continue;
    try {
      const line = readSessionMetaLine(candidate);
      if (line.payload.id === threadId) return { path: candidate, line };
    } catch {
      // Ignore unrelated or not-yet-complete rollouts while locating the exact template.
    }
  }
  throw new Error("Unable to locate the candidate-generated template rollout in the builder home.");
}

async function buildTemplate({ cliPath, builderHome, workspace, timeoutMs, audit }) {
  const appServer = new CandidateAppServer({
    cliPath,
    codexHome: builderHome,
    cwd: workspace,
    label: "builder",
    timeoutMs,
    audit,
  });
  let startResult;
  await appServer.start();
  try {
    await initializeClient(appServer);
    startResult = await appServer.request("thread/start", {
      cwd: workspace,
      ephemeral: false,
      sessionStartSource: "startup",
      threadSource,
    });
    const threadId = startResult?.thread?.id;
    if (typeof threadId !== "string" || !threadId) {
      throw new Error("thread/start did not return a thread id.");
    }
    await appServer.request("thread/name/set", {
      threadId,
      name: "Synthetic pagination template",
    });
  } finally {
    await appServer.stop();
  }

  const threadId = startResult.thread.id;
  const template = locateTemplateRollout(builderHome, threadId, startResult.thread.path);
  assert.equal(template.line.payload.id, threadId, "Template rollout id must match thread/start.");
  assert.equal(
    template.line.payload.thread_source,
    threadSource,
    "Candidate must persist the requested threadSource in session_meta."
  );
  return {
    line: template.line,
    removedEnvCount: appServer.removedEnvCount,
  };
}

function createFixtures(templateLine, targetHome, workspace) {
  const ids = [];
  const windowIds = [];
  const timestamps = [];
  const nowSecond = Math.floor(Date.now() / 1_000) * 1_000;
  const firstTimestampMs = nowSecond - fixtureThreadCount * 2_000 - 10_000;
  let templateHadWindowId = false;

  for (let index = 0; index < fixtureThreadCount; index += 1) {
    const timestampMs = firstTimestampMs + index * 2_000;
    const eventTimestampMs = timestampMs + 1;
    const timestamp = new Date(timestampMs).toISOString();
    const eventTimestamp = new Date(eventTimestampMs).toISOString();
    const threadId = uuidV7(timestampMs);
    const windowId = uuidV7(timestampMs);
    const line = deepClone(templateLine);
    line.timestamp = timestamp;
    line.payload.id = threadId;
    if (Object.prototype.hasOwnProperty.call(line.payload, "session_id")) {
      line.payload.session_id = threadId;
    }
    line.payload.timestamp = timestamp;
    line.payload.cwd = workspace;
    line.payload.thread_source = threadSource;
    const replacements = replacePropertyDeep(line.payload, "window_id", windowId);
    if (replacements === 0) {
      line.payload.context_window = { window_id: windowId };
    } else {
      templateHadWindowId = true;
    }

    const eventLine = {
      timestamp: eventTimestamp,
      type: "event_msg",
      payload: {
        type: "user_message",
        message: `Synthetic pagination fixture ${String(index + 1).padStart(3, "0")}`,
        images: [],
        local_images: [],
        text_elements: [],
      },
    };
    if (Number.isInteger(line.ordinal)) {
      eventLine.ordinal = line.ordinal + 1;
    }

    const date = new Date(timestampMs);
    const year = String(date.getUTCFullYear()).padStart(4, "0");
    const month = String(date.getUTCMonth() + 1).padStart(2, "0");
    const day = String(date.getUTCDate()).padStart(2, "0");
    const rolloutDirectory = path.join(targetHome, "sessions", year, month, day);
    fs.mkdirSync(rolloutDirectory, { recursive: true });
    const filenameTimestamp = timestamp.slice(0, 19).replace(/:/g, "-");
    const rolloutPath = path.join(
      rolloutDirectory,
      `rollout-${filenameTimestamp}-${threadId}.jsonl`
    );
    fs.writeFileSync(
      rolloutPath,
      `${JSON.stringify(line)}\n${JSON.stringify(eventLine)}\n`,
      "utf8"
    );
    fs.utimesSync(rolloutPath, date, new Date(eventTimestampMs));

    ids.push(threadId);
    windowIds.push(windowId);
    timestamps.push(timestamp, eventTimestamp);
  }

  assert.equal(new Set(ids).size, fixtureThreadCount, "Fixture thread ids must be unique.");
  assert.equal(new Set(windowIds).size, fixtureThreadCount, "Fixture window ids must be unique.");
  assert.equal(
    new Set([...ids, ...windowIds]).size,
    fixtureThreadCount * 2,
    "Fixture thread and window ids must be globally unique."
  );
  assert.equal(
    new Set(timestamps).size,
    fixtureThreadCount * 2,
    "Fixture RFC3339 timestamps must be unique."
  );
  assert.ok(ids.every(isUuidV7), "Every fixture thread id must be UUIDv7.");
  assert.ok(windowIds.every(isUuidV7), "Every fixture window id must be UUIDv7.");
  return { ids, templateHadWindowId };
}

function catalogParams(cursor = null) {
  return {
    limit: pageSize,
    cursor,
    sortKey: "updated_at",
    modelProviders: [],
    archived: false,
    sourceKinds: [],
    useStateDbOnly: true,
  };
}

async function collectCatalog(client, maximumPages = 10) {
  const pages = [];
  const seenCursors = new Set();
  let cursor = null;
  for (let index = 0; index < maximumPages; index += 1) {
    const result = await client.request("thread/list", catalogParams(cursor));
    pages.push(result);
    const nextCursor = result?.nextCursor ?? null;
    if (nextCursor === null) return pages;
    if (typeof nextCursor !== "string" || !nextCursor) {
      throw new Error("thread/list returned an invalid nextCursor.");
    }
    if (seenCursors.has(nextCursor)) {
      throw new Error("thread/list repeated a pagination cursor.");
    }
    seenCursors.add(nextCursor);
    cursor = nextCursor;
  }
  throw new Error(`thread/list exceeded ${maximumPages} pages.`);
}

function assertExactFixtureIds(rows, expectedIds, label) {
  const actualIds = rows.map((row) => row?.id);
  assert.ok(actualIds.every((id) => typeof id === "string"), `${label} returned a row without an id.`);
  assert.equal(new Set(actualIds).size, fixtureThreadCount, `${label} ids must be unique.`);
  assert.deepEqual(
    [...new Set(actualIds)].sort(),
    [...expectedIds].sort(),
    `${label} must return exactly the synthetic fixture ids.`
  );
}

async function waitForTargetIndex(client, expectedIds, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastCount = 0;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const pages = await collectCatalog(client);
      const rows = pages.flatMap((page) => page?.data || []);
      lastCount = rows.length;
      if (rows.length === fixtureThreadCount) {
        assertExactFixtureIds(rows, expectedIds, "Indexed target catalog");
        return;
      }
      if (rows.length > fixtureThreadCount) {
        throw new Error(`Target state database indexed ${rows.length} rows; expected ${fixtureThreadCount}.`);
      }
    } catch (error) {
      lastError = error;
    }
    await sleep(200);
  }
  const suffix = lastError ? ` Last error: ${lastError.message}` : "";
  throw new Error(
    `Timed out waiting for the target state database to index ${fixtureThreadCount} rollouts (last count ${lastCount}).${suffix}`
  );
}

async function verifyDirectTarget({ cliPath, targetHome, workspace, expectedIds, timeoutMs, audit }) {
  const appServer = new CandidateAppServer({
    cliPath,
    codexHome: targetHome,
    cwd: workspace,
    label: "target",
    timeoutMs,
    audit,
  });
  await appServer.start();
  try {
    await initializeClient(appServer);
    await waitForTargetIndex(appServer, expectedIds, Math.max(timeoutMs, 90_000));

    const firstPage = await appServer.request("thread/list", catalogParams(null));
    assert.equal(firstPage?.data?.length, 100, "Direct first page must contain 100 rows.");
    assert.equal(typeof firstPage.nextCursor, "string", "Direct first page must have a cursor.");
    assert.ok(firstPage.nextCursor, "Direct first-page cursor must not be empty.");
    const secondPage = await appServer.request(
      "thread/list",
      catalogParams(firstPage.nextCursor)
    );
    assert.equal(secondPage?.data?.length, 25, "Direct second page must contain 25 rows.");
    assert.equal(secondPage.nextCursor, null, "Direct final cursor must be null.");
    const rows = [...firstPage.data, ...secondPage.data];
    assertExactFixtureIds(rows, expectedIds, "Direct target catalog");

    const read = await appServer.request("thread/read", {
      threadId: rows[0].id,
      includeTurns: true,
    });
    assert.equal(read?.thread?.id, rows[0].id, "thread/read returned the wrong thread.");
    assert.ok(Array.isArray(read.thread.turns), "thread/read(includeTurns:true) must return turns.");

    return {
      indexedCount: rows.length,
      pageSizes: [firstPage.data.length, secondPage.data.length],
      finalCursor: secondPage.nextCursor,
      uniqueIds: new Set(rows.map((row) => row.id)).size,
      read: {
        includeTurns: true,
        idMatched: true,
        turnCount: read.thread.turns.length,
      },
      removedEnvCount: appServer.removedEnvCount,
    };
  } finally {
    await appServer.stop();
  }
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close((error) => {
        if (error) reject(error);
        else resolve(address.port);
      });
    });
  });
}

function fetchJson(url, timeoutMs) {
  return withTimeout(
    new Promise((resolve, reject) => {
      const request = http.get(url, (response) => {
        let body = "";
        response.setEncoding("utf8");
        response.on("data", (chunk) => {
          body += chunk;
        });
        response.on("end", () => {
          if (response.statusCode < 200 || response.statusCode >= 300) {
            reject(new Error(`HTTP ${response.statusCode} from ${url}.`));
            return;
          }
          try {
            resolve(JSON.parse(body));
          } catch (error) {
            reject(new Error(`Invalid JSON from ${url}: ${error.message}`));
          }
        });
      });
      request.once("error", reject);
    }),
    timeoutMs,
    `Timed out fetching ${url}.`
  );
}

async function waitForHealth(url, child, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    if (child.exitCode != null) {
      throw new Error(`Catalog shim exited with code ${child.exitCode} before becoming healthy.`);
    }
    try {
      return await fetchJson(url, Math.min(2_000, timeoutMs));
    } catch (error) {
      lastError = error;
      await sleep(100);
    }
  }
  throw new Error(`Timed out waiting for catalog shim health. ${lastError?.message || ""}`.trim());
}

class WebSocketRpcClient {
  constructor(socket, timeoutMs, audit) {
    this.socket = socket;
    this.timeoutMs = timeoutMs;
    this.audit = audit;
    this.nextId = 1;
    this.pending = new Map();
    socket.on("message", (raw) => this.onMessage(raw));
    socket.on("close", () => {
      for (const pending of this.pending.values()) {
        clearTimeout(pending.timer);
        pending.reject(new Error("Catalog shim WebSocket closed."));
      }
      this.pending.clear();
    });
  }

  onMessage(raw) {
    const message = JSON.parse(raw.toString());
    const pending = message.id == null ? null : this.pending.get(String(message.id));
    if (!pending) return;
    this.pending.delete(String(message.id));
    clearTimeout(pending.timer);
    if (message.error) {
      pending.reject(
        new Error(`${pending.method} failed: ${message.error.message || JSON.stringify(message.error)}`)
      );
    } else {
      pending.resolve(message.result);
    }
  }

  request(method, params) {
    if (!allowedRpcMethods.has(method)) {
      throw new Error(`RPC method ${method} is not allowed in the offline compatibility test.`);
    }
    this.audit.push({ transport: "websocket", phase: "shim", method });
    const id = this.nextId;
    this.nextId += 1;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        reject(new Error(`Timed out waiting for ${method} from the catalog shim.`));
      }, this.timeoutMs);
      this.pending.set(String(id), { resolve, reject, timer, method });
      this.socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  notify(method, params) {
    if (method !== "initialized") {
      throw new Error(`Notification ${method} is not allowed in the offline compatibility test.`);
    }
    this.audit.push({ transport: "websocket", phase: "shim", method });
    this.socket.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
  }
}

function openWebSocket(url, timeoutMs) {
  return withTimeout(
    new Promise((resolve, reject) => {
      const socket = new WebSocket(url);
      socket.once("open", () => resolve(socket));
      socket.once("error", reject);
    }),
    timeoutMs,
    "Timed out connecting to the catalog shim WebSocket."
  );
}

async function stopChild(child) {
  if (!child || child.exitCode != null) return;

  if (process.platform === "win32" && Number.isInteger(child.pid)) {
    spawnSync("taskkill.exe", ["/PID", String(child.pid), "/T", "/F"], {
      windowsHide: true,
      stdio: "ignore",
    });
  } else {
    child.kill("SIGKILL");
  }

  await Promise.race([
    new Promise((resolve) => child.once("exit", resolve)),
    sleep(10_000),
  ]);
}

async function removeFixtureTree(directory) {
  const deadline = Date.now() + 30_000;
  let lastError;

  while (Date.now() < deadline) {
    try {
      fs.rmSync(directory, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 250,
      });
      return;
    } catch (error) {
      lastError = error;
      if (!["EBUSY", "ENOTEMPTY", "EPERM"].includes(error?.code)) throw error;
      await sleep(500);
    }
  }

  throw lastError || new Error(`Timed out removing fixture directory: ${directory}`);
}

async function verifyShim({
  cliPath,
  cliSha256,
  targetHome,
  fixtureRoot,
  expectedIds,
  timeoutMs,
  audit,
}) {
  const port = await freePort();
  const token = crypto.randomBytes(32).toString("hex");
  const configPath = path.join(fixtureRoot, "shim-config.json");
  const logPath = path.join(fixtureRoot, "shim.log");
  fs.writeFileSync(
    configPath,
    `${JSON.stringify({ host: "127.0.0.1", port, maxThreads: 1_000, upstreamCliSha256: cliSha256 })}\n`,
    "utf8"
  );
  const isolated = isolatedChildEnv(targetHome, {
    CODEX_CATALOG_SHIM_CONFIG: configPath,
    CODEX_CATALOG_SHIM_CODEX_HOME: targetHome,
    CODEX_CATALOG_SHIM_SQLITE_HOME: targetHome,
    CODEX_CATALOG_SHIM_UPSTREAM_CLI: cliPath,
    CODEX_CATALOG_SHIM_EXPECTED_CLI_SHA256: cliSha256,
    CODEX_CATALOG_SHIM_HOST: "127.0.0.1",
    CODEX_CATALOG_SHIM_PORT: String(port),
    CODEX_CATALOG_SHIM_MAX_THREADS: "1000",
    CODEX_CATALOG_SHIM_TOKEN: token,
    CODEX_CATALOG_SHIM_LOG: logPath,
    CODEX_CATALOG_SHIM_QUIET: "1",
  });
  const child = spawn(process.execPath, [path.join(rootDir, "src", "catalog-shim.cjs")], {
    cwd: rootDir,
    env: isolated.env,
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
  child.stderr.resume();
  const healthUrl = `http://127.0.0.1:${port}/health`;
  let socket;
  try {
    const initialHealth = await waitForHealth(healthUrl, child, timeoutMs);
    if (initialHealth.wsPath !== `/codex-app-server/${token}`) {
      throw new Error("Catalog shim health returned an unexpected WebSocket path.");
    }
    socket = await openWebSocket(`ws://127.0.0.1:${port}${initialHealth.wsPath}`, timeoutMs);
    const client = new WebSocketRpcClient(socket, timeoutMs, audit);
    await initializeClient(client);
    const catalog = await client.request("thread/list", {
      limit: pageSize,
      cursor: null,
      sortKey: "updated_at",
      modelProviders: null,
      archived: false,
      sourceKinds: [],
      useStateDbOnly: true,
    });
    assert.equal(catalog?.data?.length, fixtureThreadCount, "Shim must return all 125 rows.");
    assert.equal(catalog.nextCursor, null, "Shim startup response nextCursor must be null.");
    assertExactFixtureIds(catalog.data, expectedIds, "Shim startup catalog");

    const health = await fetchJson(healthUrl, timeoutMs);
    assert.equal(health.lastCatalogPages, 2, "Shim health must report two upstream pages.");
    assert.equal(health.lastCatalogCount, fixtureThreadCount, "Shim health count must be 125.");
    return {
      interceptedCount: catalog.data.length,
      uniqueIds: new Set(catalog.data.map((row) => row.id)).size,
      nextCursor: catalog.nextCursor,
      health: {
        lastCatalogPages: health.lastCatalogPages,
        lastCatalogCount: health.lastCatalogCount,
      },
      removedEnvCount: isolated.removedCount,
    };
  } finally {
    if (socket && socket.readyState !== WebSocket.CLOSED) {
      await new Promise((resolve) => {
        const timer = setTimeout(resolve, 2_000);
        socket.once("close", () => {
          clearTimeout(timer);
          resolve();
        });
        socket.close();
      });
    }
    await stopChild(child);
  }
}

function summarizeAudit(audit) {
  const methodCounts = {};
  for (const entry of audit) {
    methodCounts[entry.method] = (methodCounts[entry.method] || 0) + 1;
  }
  return {
    allowedMethodsOnly: audit.every((entry) => allowedRpcMethods.has(entry.method) || entry.method === "initialized"),
    turnStartCalls: methodCounts["turn/start"] || 0,
    methodCounts,
  };
}

function runSelfTest() {
  const timestamp = 1_700_000_000_123;
  const id = uuidV7(timestamp);
  assert.ok(isUuidV7(id));
  assert.equal(parseInt(id.slice(0, 8) + id.slice(9, 13), 16), timestamp);
  const object = { context_window: { window_id: "old" } };
  assert.equal(replacePropertyDeep(object, "window_id", "new"), 1);
  assert.equal(object.context_window.window_id, "new");
  assert.equal(shouldRemoveFromChildEnv("OPENAI_API_KEY"), true);
  assert.equal(shouldRemoveFromChildEnv("ANTHROPIC_BASE_URL"), true);
  assert.equal(shouldRemoveFromChildEnv("PATH"), false);
  process.stdout.write(`${JSON.stringify({ test: `${testName}-helpers`, passed: true })}\n`);
}

async function run(options) {
  const startedAt = Date.now();
  const audit = [];
  let fixtureRoot = null;
  let candidateCli = null;
  let manifestSummary = null;
  let directResult = null;
  let shimResult = null;
  let report = {
    schemaVersion: 1,
    test: testName,
    passed: false,
    packageName: null,
    packageVersion: null,
    cliSha256: null,
    validatedAtUtc: new Date().toISOString(),
    fixtureThreadCount,
    checks: {
      directAppServer: {
        passed: false,
        returnedThreadCount: 0,
        pageCount: 0,
        uniqueThreadCount: 0,
        threadReadPassed: false,
        nextCursorIsNull: false,
      },
      shim: {
        passed: false,
        returnedThreadCount: 0,
        pageCount: 0,
        uniqueThreadCount: 0,
        nextCursorIsNull: false,
      },
    },
  };
  let primaryError = null;
  let cleanupError = null;

  try {
    if (!fs.existsSync(options.candidateManifest)) {
      throw new Error(`Candidate manifest was not found: ${options.candidateManifest}`);
    }
    manifestSummary = validateManifest(readJson(options.candidateManifest));
    candidateCli = path.join(
      options.candidateCacheRoot,
      manifestSummary.cliSha256.toLowerCase(),
      "codex.exe"
    );
    if (!fs.existsSync(candidateCli) || !fs.statSync(candidateCli).isFile()) {
      throw new Error(`Cached candidate CLI was not found: ${candidateCli}`);
    }
    const actualCliSha256 = await sha256File(candidateCli);
    if (actualCliSha256 !== manifestSummary.cliSha256) {
      throw new Error(
        `Cached candidate CLI SHA-256 mismatch: expected ${manifestSummary.cliSha256}, got ${actualCliSha256}.`
      );
    }

    fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "codex-pagination-smoke-"));
    const builderHome = path.join(fixtureRoot, "builder");
    const targetHome = path.join(fixtureRoot, "target");
    const workspace = path.join(fixtureRoot, "workspace");
    fs.mkdirSync(builderHome);
    fs.mkdirSync(targetHome);
    fs.mkdirSync(workspace);
    assert.equal(new Set([builderHome, targetHome, workspace]).size, 3);

    const template = await buildTemplate({
      cliPath: candidateCli,
      builderHome,
      workspace,
      timeoutMs: options.timeoutMs,
      audit,
    });
    const fixtures = createFixtures(template.line, targetHome, workspace);
    directResult = await verifyDirectTarget({
      cliPath: candidateCli,
      targetHome,
      workspace,
      expectedIds: fixtures.ids,
      timeoutMs: options.timeoutMs,
      audit,
    });
    shimResult = await verifyShim({
      cliPath: candidateCli,
      cliSha256: manifestSummary.cliSha256,
      targetHome,
      fixtureRoot,
      expectedIds: fixtures.ids,
      timeoutMs: options.timeoutMs,
      audit,
    });
    const rpcAudit = summarizeAudit(audit);
    assert.equal(rpcAudit.turnStartCalls, 0, "The offline smoke test must never call turn/start.");
    assert.equal(rpcAudit.allowedMethodsOnly, true, "The smoke test sent a non-allowlisted RPC method.");

    report = {
      schemaVersion: 1,
      test: testName,
      passed: true,
      packageName: manifestSummary.packageName,
      packageVersion: manifestSummary.packageVersion,
      cliSha256: manifestSummary.cliSha256,
      validatedAtUtc: new Date().toISOString(),
      fixtureThreadCount,
      durationMs: Date.now() - startedAt,
      checks: {
        directAppServer: {
          passed: true,
          returnedThreadCount: directResult.indexedCount,
          pageCount: directResult.pageSizes.length,
          uniqueThreadCount: directResult.uniqueIds,
          threadReadPassed: directResult.read.idMatched,
          pageSizes: directResult.pageSizes,
          nextCursorIsNull: directResult.finalCursor === null,
        },
        shim: {
          passed: true,
          returnedThreadCount: shimResult.interceptedCount,
          pageCount: shimResult.health.lastCatalogPages,
          uniqueThreadCount: shimResult.uniqueIds,
          nextCursorIsNull: shimResult.nextCursor === null,
          healthCatalogCount: shimResult.health.lastCatalogCount,
        },
      },
      fixture: {
        threadSource,
        uuidVersion: 7,
        uniqueRfc3339Timestamps: fixtureThreadCount * 2,
        templateWindowIdReplaced: fixtures.templateHadWindowId,
        retained: options.keepFixture,
      },
      isolation: {
        separateBuilderTargetWorkspaceDirectories: true,
        codexHomeEqualsSqliteHome: true,
        providerAndCredentialEnvironmentCleared: true,
        removedEnvironmentVariableCount: Math.max(
          template.removedEnvCount,
          directResult.removedEnvCount,
          shimResult.removedEnvCount
        ),
        rpc: rpcAudit,
      },
      cleanup: {
        requested: !options.keepFixture,
        completed: false,
      },
    };
  } catch (error) {
    primaryError = error;
  } finally {
    if (fixtureRoot && !options.keepFixture) {
      try {
        await removeFixtureTree(fixtureRoot);
      } catch (error) {
        cleanupError = error;
      }
    }
  }

  const replacements = [
    [fixtureRoot, "<fixture-root>"],
    [candidateCli, "<candidate-cli>"],
    [options.candidateManifest, "<candidate-manifest>"],
    [options.candidateCacheRoot, "<candidate-cache-root>"],
    [options.output, "<report>"],
    [rootDir, "<repository>"],
    [os.homedir(), "<home>"],
  ];
  if (primaryError || cleanupError) {
    const error = primaryError || cleanupError;
    report = {
      schemaVersion: 1,
      test: testName,
      passed: false,
      packageName: manifestSummary?.packageName || null,
      packageVersion: manifestSummary?.packageVersion || null,
      cliSha256: manifestSummary?.cliSha256 || null,
      validatedAtUtc: new Date().toISOString(),
      fixtureThreadCount,
      durationMs: Date.now() - startedAt,
      checks: {
        directAppServer: {
          passed: Boolean(directResult),
          returnedThreadCount: directResult?.indexedCount || 0,
          pageCount: directResult?.pageSizes?.length || 0,
          uniqueThreadCount: directResult?.uniqueIds || 0,
          threadReadPassed: Boolean(directResult?.read?.idMatched),
          nextCursorIsNull: directResult?.finalCursor === null,
        },
        shim: {
          passed: Boolean(shimResult),
          returnedThreadCount: shimResult?.interceptedCount || 0,
          pageCount: shimResult?.health?.lastCatalogPages || 0,
          uniqueThreadCount: shimResult?.uniqueIds || 0,
          nextCursorIsNull: shimResult?.nextCursor === null,
        },
      },
      isolation: {
        rpc: summarizeAudit(audit),
      },
      cleanup: {
        requested: !options.keepFixture,
        completed: !cleanupError && (!fixtureRoot || !options.keepFixture),
        retained: Boolean(fixtureRoot && options.keepFixture),
      },
      error: {
        name: error?.name || "Error",
        message: sanitizeMessage(error?.message, replacements),
      },
    };
  } else {
    report.cleanup.completed = !options.keepFixture;
  }

  writeReport(options.output, report);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (fixtureRoot && options.keepFixture) {
    process.stderr.write(`Fixture retained at ${fixtureRoot}\n`);
  }
  if (primaryError || cleanupError) {
    const error = primaryError || cleanupError;
    throw new Error(sanitizeMessage(error?.message, replacements));
  }
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error.message}\n${usage()}\n`);
    process.exitCode = 2;
    return;
  }
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  if (options.selfTest) {
    runSelfTest();
    return;
  }
  await run(options);
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
