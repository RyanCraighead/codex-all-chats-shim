#!/usr/bin/env node

const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");
const { WebSocket, WebSocketServer } = require("ws");

const rootDir = path.resolve(__dirname, "..");

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function resolveOptions() {
  const configPath = path.resolve(
    process.env.CODEX_CATALOG_SHIM_CONFIG ||
      path.join(rootDir, "config.local.json")
  );
  const config = readJson(configPath);
  const codexHome = path.resolve(
    process.env.CODEX_CATALOG_SHIM_CODEX_HOME ||
      process.env.CODEX_HOME ||
      path.join(os.homedir(), ".codex")
  );
  const sqliteHome = path.resolve(
    process.env.CODEX_CATALOG_SHIM_SQLITE_HOME ||
      process.env.CODEX_SQLITE_HOME ||
      codexHome
  );
  const logPath = path.resolve(
    process.env.CODEX_CATALOG_SHIM_LOG ||
      path.join(rootDir, "logs", "catalog-shim.log")
  );
  const upstreamCli = process.env.CODEX_CATALOG_SHIM_UPSTREAM_CLI;
  if (!upstreamCli) {
    throw new Error("CODEX_CATALOG_SHIM_UPSTREAM_CLI is required.");
  }
  const token = process.env.CODEX_CATALOG_SHIM_TOKEN;
  if (!token || !/^[a-f0-9]{32,128}$/i.test(token)) {
    throw new Error("CODEX_CATALOG_SHIM_TOKEN must be a 32-128 character hexadecimal token.");
  }
  let upstreamPrefixArgs = [];
  try {
    upstreamPrefixArgs = JSON.parse(process.env.CODEX_CATALOG_SHIM_UPSTREAM_PREFIX_ARGS || "[]");
  } catch (error) {
    throw new Error(`Invalid CODEX_CATALOG_SHIM_UPSTREAM_PREFIX_ARGS JSON: ${error.message}`);
  }
  if (!Array.isArray(upstreamPrefixArgs) || upstreamPrefixArgs.some((item) => typeof item !== "string")) {
    throw new Error("CODEX_CATALOG_SHIM_UPSTREAM_PREFIX_ARGS must be a JSON array of strings.");
  }
  return {
    configPath,
    codexHome,
    sqliteHome,
    logPath,
    upstreamCli: path.resolve(upstreamCli),
    expectedCliSha256: String(
      process.env.CODEX_CATALOG_SHIM_EXPECTED_CLI_SHA256 || config.upstreamCliSha256 || ""
    ).toUpperCase(),
    skipCliHashCheck: process.env.CODEX_CATALOG_SHIM_SKIP_HASH_CHECK === "1",
    upstreamPrefixArgs,
    host: process.env.CODEX_CATALOG_SHIM_HOST || config.host || "127.0.0.1",
    port: Number(process.env.CODEX_CATALOG_SHIM_PORT || config.port || 47850),
    wsPath: `/codex-app-server/${token}`,
    maxThreads: Number(process.env.CODEX_CATALOG_SHIM_MAX_THREADS || config.maxThreads || 10000),
    quiet: process.env.CODEX_CATALOG_SHIM_QUIET === "1",
  };
}

function sha256(filePath) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(filePath));
  return hash.digest("hex").toUpperCase();
}

function createLogger(options) {
  fs.mkdirSync(path.dirname(options.logPath), { recursive: true });
  return (message, fields = null) => {
    const suffix = fields == null ? "" : ` ${JSON.stringify(fields)}`;
    const line = `${new Date().toISOString()} ${message}${suffix}`;
    fs.appendFileSync(options.logPath, `${line}\n`);
    if (!options.quiet) {
      process.stdout.write(`${line}\n`);
    }
  };
}

function isCatalogExpansionRequest(message) {
  if (message == null || message.method !== "thread/list" || message.id == null) {
    return false;
  }
  const params = message.params || {};
  return (
    params.archived === false &&
    params.useStateDbOnly === true &&
    (params.cursor == null || params.cursor === "") &&
    params.cwd == null &&
    params.parentThreadId == null &&
    params.searchTerm == null
  );
}

class UpstreamSession {
  constructor({ client, options, log, sessionId, state }) {
    this.client = client;
    this.options = options;
    this.log = log;
    this.sessionId = sessionId;
    this.state = state;
    this.stdoutBuffer = "";
    this.stderrBuffer = "";
    this.internalRequestId = -1_000_000_000;
    this.pendingInternal = new Map();
    this.catalogPromise = null;
    this.closed = false;
    this.child = null;
  }

  start() {
    const args = [
      ...this.options.upstreamPrefixArgs,
      "-c",
      "features.code_mode_host=true",
      "app-server",
      "--analytics-default-enabled",
    ];
    this.child = spawn(this.options.upstreamCli, args, {
      cwd: rootDir,
      env: {
        ...process.env,
        CODEX_HOME: this.options.codexHome,
        CODEX_SQLITE_HOME: this.options.sqliteHome,
      },
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    this.child.stdout.on("data", (chunk) => this.onUpstreamStdout(chunk));
    this.child.stderr.on("data", (chunk) => this.onUpstreamStderr(chunk));
    this.child.on("error", (error) => this.fail(`Upstream process error: ${error.message}`));
    this.child.on("exit", (code, signal) => {
      if (!this.closed) {
        this.fail(`Upstream app-server exited (code=${code}, signal=${signal || "none"}).`);
      }
    });
    this.log("upstream_started", {
      sessionId: this.sessionId,
      pid: this.child.pid,
      codexHome: this.options.codexHome,
    });
  }

  onClientMessage(raw) {
    const text = raw.toString();
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      this.forwardToUpstream(text);
      return;
    }
    if (!isCatalogExpansionRequest(message)) {
      this.forwardToUpstream(text);
      return;
    }
    this.expandCatalog(message).catch((error) => {
      this.log("catalog_expansion_failed", {
        sessionId: this.sessionId,
        error: error.message,
      });
      this.sendToClient({
        jsonrpc: message.jsonrpc || "2.0",
        id: message.id,
        error: {
          code: -32098,
          message: `Codex catalog shim failed: ${error.message}`,
        },
      });
    });
  }

  forwardToUpstream(text) {
    if (this.child?.stdin?.writable) {
      this.child.stdin.write(`${text.replace(/[\r\n]+$/, "")}\n`);
    }
  }

  onUpstreamStdout(chunk) {
    this.stdoutBuffer += chunk.toString();
    let newlineIndex;
    while ((newlineIndex = this.stdoutBuffer.indexOf("\n")) >= 0) {
      const raw = this.stdoutBuffer.slice(0, newlineIndex).replace(/\r$/, "");
      this.stdoutBuffer = this.stdoutBuffer.slice(newlineIndex + 1);
      if (!raw.trim()) {
        continue;
      }
      let message;
      try {
        message = JSON.parse(raw);
      } catch {
        this.log("upstream_non_json_stdout", {
          sessionId: this.sessionId,
          value: raw.slice(0, 500),
        });
        continue;
      }
      const pending = message.id == null ? null : this.pendingInternal.get(String(message.id));
      if (pending) {
        this.pendingInternal.delete(String(message.id));
        clearTimeout(pending.timer);
        if (message.error) {
          pending.reject(new Error(message.error.message || JSON.stringify(message.error)));
        } else {
          pending.resolve(message.result);
        }
        continue;
      }
      this.sendToClient(message);
    }
  }

  onUpstreamStderr(chunk) {
    this.stderrBuffer += chunk.toString();
    const lines = this.stderrBuffer.split(/\r?\n/);
    this.stderrBuffer = lines.pop() || "";
    for (const line of lines) {
      if (line.trim()) {
        this.log("upstream_stderr", { sessionId: this.sessionId, value: line.slice(0, 1500) });
      }
    }
  }

  sendToClient(message) {
    if (this.client.readyState === WebSocket.OPEN) {
      this.client.send(JSON.stringify(message));
    }
  }

  sendInternalRequest(method, params, timeoutMs = 30_000) {
    const id = this.internalRequestId;
    this.internalRequestId -= 1;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingInternal.delete(String(id));
        reject(new Error(`Timed out waiting for ${method}.`));
      }, timeoutMs);
      this.pendingInternal.set(String(id), { resolve, reject, timer });
      this.forwardToUpstream(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  async expandCatalog(originalRequest) {
    if (!this.catalogPromise) {
      this.catalogPromise = this.collectCatalog(originalRequest.params || {}).finally(() => {
        this.catalogPromise = null;
      });
    }
    const result = await this.catalogPromise;
    this.sendToClient({
      jsonrpc: originalRequest.jsonrpc || "2.0",
      id: originalRequest.id,
      result,
    });
  }

  async collectCatalog(originalParams) {
    const startedAt = Date.now();
    const rows = [];
    const seenIds = new Set();
    const seenCursors = new Set();
    let cursor = null;
    let pages = 0;
    let firstResult = null;

    while (true) {
      const params = {
        ...originalParams,
        limit: 100,
        cursor,
        modelProviders: [],
        useStateDbOnly: true,
      };
      const result = await this.sendInternalRequest("thread/list", params);
      firstResult ||= result;
      pages += 1;
      for (const thread of result?.data || []) {
        if (thread?.id == null || seenIds.has(thread.id)) {
          continue;
        }
        seenIds.add(thread.id);
        rows.push(thread);
      }
      const nextCursor = result?.nextCursor || null;
      if (!nextCursor) {
        break;
      }
      if (seenCursors.has(nextCursor)) {
        throw new Error(`App-server repeated catalog cursor ${nextCursor}.`);
      }
      if (rows.length >= this.options.maxThreads) {
        throw new Error(
          `Catalog exceeds configured maximum of ${this.options.maxThreads} active tasks.`
        );
      }
      seenCursors.add(nextCursor);
      cursor = nextCursor;
    }

    const durationMs = Date.now() - startedAt;
    this.state.expansions += 1;
    this.state.lastCatalogCount = rows.length;
    this.state.lastCatalogPages = pages;
    this.state.lastCatalogDurationMs = durationMs;
    this.state.lastCatalogAt = new Date().toISOString();
    this.log("catalog_expanded", {
      sessionId: this.sessionId,
      rows: rows.length,
      pages,
      durationMs,
      originalLimit: originalParams.limit ?? null,
      originalModelProviders: originalParams.modelProviders ?? null,
    });
    return {
      ...(firstResult || {}),
      data: rows,
      nextCursor: null,
    };
  }

  fail(message) {
    this.log("session_failed", { sessionId: this.sessionId, message });
    if (this.client.readyState === WebSocket.OPEN) {
      this.client.close(1011, message.slice(0, 120));
    }
    this.close();
  }

  close() {
    if (this.closed) {
      return;
    }
    this.closed = true;
    for (const pending of this.pendingInternal.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error("Catalog shim session closed."));
    }
    this.pendingInternal.clear();
    if (this.child && !this.child.killed) {
      this.child.kill();
    }
    this.state.connections = Math.max(0, this.state.connections - 1);
    this.log("session_closed", { sessionId: this.sessionId });
  }
}

function main() {
  const options = resolveOptions();
  const log = createLogger(options);
  if (!fs.existsSync(options.upstreamCli)) {
    throw new Error(`Upstream Codex CLI does not exist: ${options.upstreamCli}`);
  }
  const actualCliSha256 = sha256(options.upstreamCli);
  if (!options.skipCliHashCheck && options.expectedCliSha256 && actualCliSha256 !== options.expectedCliSha256) {
    throw new Error(
      `Upstream Codex CLI hash mismatch. Expected ${options.expectedCliSha256}, got ${actualCliSha256}.`
    );
  }
  const state = {
    startedAt: new Date().toISOString(),
    connections: 0,
    expansions: 0,
    lastCatalogCount: null,
    lastCatalogPages: null,
    lastCatalogDurationMs: null,
    lastCatalogAt: null,
  };
  const sessions = new Set();
  let nextSessionId = 1;

  const server = http.createServer((request, response) => {
    if (request.url !== "/health") {
      response.writeHead(404, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "not_found" }));
      return;
    }
    response.writeHead(200, {
      "content-type": "application/json",
      "cache-control": "no-store",
    });
    response.end(
      JSON.stringify({
        ok: true,
        pid: process.pid,
        host: options.host,
        port: options.port,
        wsPath: options.wsPath,
        codexHome: options.codexHome,
        sqliteHome: options.sqliteHome,
        upstreamCli: options.upstreamCli,
        upstreamCliSha256: actualCliSha256,
        maxThreads: options.maxThreads,
        ...state,
      })
    );
  });
  const webSocketServer = new WebSocketServer({ noServer: true, perMessageDeflate: false });
  server.on("upgrade", (request, socket, head) => {
    const requestPath = new URL(request.url || "/", `http://${options.host}:${options.port}`).pathname;
    if (requestPath !== options.wsPath) {
      socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    webSocketServer.handleUpgrade(request, socket, head, (client) => {
      webSocketServer.emit("connection", client, request);
    });
  });
  webSocketServer.on("connection", (client) => {
    const sessionId = nextSessionId;
    nextSessionId += 1;
    state.connections += 1;
    const session = new UpstreamSession({ client, options, log, sessionId, state });
    sessions.add(session);
    try {
      session.start();
    } catch (error) {
      log("upstream_start_failed", { sessionId, error: error.message });
      session.close();
      sessions.delete(session);
      client.close(1011, "Unable to start Codex app-server.");
      return;
    }
    client.on("message", (raw) => session.onClientMessage(raw));
    client.on("close", () => {
      session.close();
      sessions.delete(session);
    });
    client.on("error", (error) => {
      log("client_error", { sessionId, error: error.message });
    });
  });

  const shutdown = () => {
    log("shim_stopping", { sessions: sessions.size });
    for (const session of sessions) {
      session.close();
    }
    webSocketServer.close();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 3000).unref();
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
  process.on("uncaughtException", (error) => {
    log("uncaught_exception", { error: error.stack || error.message });
    shutdown();
  });
  process.on("unhandledRejection", (error) => {
    log("unhandled_rejection", { error: error?.stack || String(error) });
  });

  server.listen(options.port, options.host, () => {
    log("shim_listening", {
      pid: process.pid,
      url: `ws://${options.host}:${options.port}${options.wsPath}`,
      health: `http://${options.host}:${options.port}/health`,
      codexHome: options.codexHome,
      upstreamCliSha256: actualCliSha256,
    });
  });
}

main();
