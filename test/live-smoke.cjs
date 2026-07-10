const { WebSocket } = require("ws");

const url = process.argv[2];
if (!url) {
  console.error("Usage: node test/live-smoke.cjs <tokenized-ws-url>");
  process.exit(2);
}

let nextId = 1;
const pending = new Map();

function request(socket, method, params, timeoutMs = 60_000) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Timed out waiting for ${method}.`));
    }, timeoutMs);
    pending.set(id, { resolve, reject, timer });
    socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
  });
}

async function main() {
  const socket = new WebSocket(url);
  socket.on("message", (raw) => {
    const message = JSON.parse(raw.toString());
    const item = pending.get(message.id);
    if (!item) return;
    pending.delete(message.id);
    clearTimeout(item.timer);
    if (message.error) item.reject(new Error(message.error.message));
    else item.resolve(message.result);
  });
  await new Promise((resolve, reject) => {
    socket.once("open", resolve);
    socket.once("error", reject);
  });
  await request(socket, "initialize", {
    clientInfo: { name: "catalog-shim-smoke-test", title: "Catalog Shim Smoke Test", version: "0.1.0" },
    capabilities: null
  });
  const catalog = await request(socket, "thread/list", {
    limit: 100,
    cursor: null,
    sortKey: "updated_at",
    modelProviders: null,
    archived: false,
    sourceKinds: [],
    useStateDbOnly: true
  });
  const rows = catalog.data || [];
  if (rows.length > 0) {
    const read = await request(socket, "thread/read", {
      threadId: rows[0].id,
      includeTurns: false
    });
    if (read.thread?.id !== rows[0].id) throw new Error("thread/read pass-through returned the wrong task.");
  }
  const result = {
    count: rows.length,
    nextCursor: catalog.nextCursor || null,
    workspaces: new Set(rows.map((thread) => thread.cwd).filter(Boolean)).size,
    providers: Array.from(new Set(rows.map((thread) => thread.modelProvider).filter(Boolean))).sort()
  };
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  socket.close();
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
