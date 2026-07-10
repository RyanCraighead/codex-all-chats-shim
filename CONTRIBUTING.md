# Contributing

Contributions should preserve four invariants:

1. Never patch or redistribute the signed Codex application.
2. Fail closed when the installed package version or CLI hash changes.
3. Keep the WebSocket endpoint loopback-only and unguessable.
4. Proxy non-catalog app-server traffic without changing semantics.

Run before submitting changes:

```powershell
npm ci
npm test
npm run check
```

Do not include local Codex databases, rollouts, authentication files, chat text, API keys, or copied binaries in issues, fixtures, commits, or pull requests.
