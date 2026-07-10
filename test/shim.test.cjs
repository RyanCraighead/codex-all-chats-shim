const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const test = require("node:test");
const { WebSocket } = require("ws");

const rootDir = path.resolve(__dirname, "..");

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function waitForHealth(url, child) {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if (child.exitCode != null) throw new Error(`Shim exited with code ${child.exitCode}.`);
    try {
      const response = await fetch(url);
      if (response.ok) return response.json();
    } catch {
      // Service has not started yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("Timed out waiting for shim health endpoint.");
}

function openWebSocket(url) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    socket.once("open", () => resolve(socket));
    socket.once("error", reject);
  });
}

function request(socket, id, method, params) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${method}.`)), 10_000);
    const onMessage = (raw) => {
      const message = JSON.parse(raw.toString());
      if (message.id !== id) return;
      clearTimeout(timer);
      socket.off("message", onMessage);
      if (message.error) reject(new Error(message.error.message));
      else resolve(message.result);
    };
    socket.on("message", onMessage);
    socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
  });
}

test("expands the startup catalog and proxies other requests", async (t) => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "codex-catalog-shim-test-"));
  const port = await freePort();
  const token = "a".repeat(64);
  const configPath = path.join(tempDir, "config.json");
  const logPath = path.join(tempDir, "shim.log");
  fs.writeFileSync(configPath, JSON.stringify({
    upstreamCliSha256: "",
    host: "127.0.0.1",
    port,
    maxThreads: 100
  }));

  const child = spawn(process.execPath, [path.join(rootDir, "src", "catalog-shim.cjs")], {
    cwd: rootDir,
    env: {
      ...process.env,
      CODEX_CATALOG_SHIM_CONFIG: configPath,
      CODEX_CATALOG_SHIM_CODEX_HOME: tempDir,
      CODEX_CATALOG_SHIM_SQLITE_HOME: tempDir,
      CODEX_CATALOG_SHIM_UPSTREAM_CLI: process.execPath,
      CODEX_CATALOG_SHIM_UPSTREAM_PREFIX_ARGS: JSON.stringify([
        path.join(rootDir, "test", "fake-app-server.cjs")
      ]),
      CODEX_CATALOG_SHIM_SKIP_HASH_CHECK: "1",
      CODEX_CATALOG_SHIM_HOST: "127.0.0.1",
      CODEX_CATALOG_SHIM_PORT: String(port),
      CODEX_CATALOG_SHIM_MAX_THREADS: "100",
      CODEX_CATALOG_SHIM_TOKEN: token,
      CODEX_CATALOG_SHIM_LOG: logPath,
      CODEX_CATALOG_SHIM_QUIET: "1"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  t.after(async () => {
    if (child.exitCode == null) child.kill();
    await new Promise((resolve) => {
      if (child.exitCode != null) resolve();
      else child.once("exit", resolve);
    });
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const health = await waitForHealth(`http://127.0.0.1:${port}/health`, child);
  assert.equal(health.wsPath, `/codex-app-server/${token}`);

  await assert.rejects(openWebSocket(`ws://127.0.0.1:${port}`), /404/);
  const socket = await openWebSocket(`ws://127.0.0.1:${port}${health.wsPath}`);
  t.after(() => socket.close());

  await request(socket, 1, "initialize", {
    clientInfo: { name: "shim-test", title: "Shim Test", version: "0.0.0" },
    capabilities: null
  });
  const catalog = await request(socket, 2, "thread/list", {
    limit: 100,
    cursor: null,
    sortKey: "updated_at",
    modelProviders: null,
    archived: false,
    sourceKinds: [],
    useStateDbOnly: true
  });
  assert.deepEqual(catalog.data.map((thread) => thread.id), ["thread-1", "thread-2", "thread-3"]);
  assert.equal(catalog.nextCursor, null);

  const read = await request(socket, 3, "thread/read", {
    threadId: "thread-3",
    includeTurns: false
  });
  assert.equal(read.thread.id, "thread-3");

  const updatedHealth = await (await fetch(`http://127.0.0.1:${port}/health`)).json();
  assert.equal(updatedHealth.expansions, 1);
  assert.equal(updatedHealth.lastCatalogCount, 3);
  assert.equal(updatedHealth.lastCatalogPages, 2);
});
