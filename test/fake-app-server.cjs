let buffer = "";

function send(id, result = null, error = null) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result, error })}\n`);
}

process.stdin.on("data", (chunk) => {
  buffer += chunk.toString();
  let index;
  while ((index = buffer.indexOf("\n")) >= 0) {
    const raw = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (!raw) continue;
    const message = JSON.parse(raw);
    if (message.method === "initialize") {
      send(message.id, { userAgent: "fake-codex-app-server" });
    } else if (message.method === "thread/list") {
      const cursor = message.params?.cursor || null;
      if (cursor == null) {
        send(message.id, {
          data: [
            { id: "thread-1", cwd: "C:\\Projects\\one", modelProvider: "openai" },
            { id: "thread-2", cwd: "C:\\Projects\\two", modelProvider: "deepseek" }
          ],
          nextCursor: "page-2"
        });
      } else {
        send(message.id, {
          data: [{ id: "thread-3", cwd: "C:\\Projects\\one", modelProvider: "openai" }],
          nextCursor: null
        });
      }
    } else if (message.method === "thread/read") {
      send(message.id, { thread: { id: message.params.threadId, turns: [] } });
    } else {
      send(message.id, { echoedMethod: message.method, echoedParams: message.params || null });
    }
  }
});
