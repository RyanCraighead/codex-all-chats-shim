# Security Policy

## Trust Model

The shim exposes a privileged Codex app-server endpoint only on the local loopback interface. A random 256-bit path is generated for each process start, and only the launched Codex process receives that URL.

The HTTP health endpoint intentionally does not enable CORS. It contains operational metadata but no chat bodies, tokens, API keys, or authentication material.

The shim spawns a local copy of the exact `codex.exe` detected during setup. The SHA-256 is verified on every launch. Package-version or hash mismatches fail closed.

## Sensitive Data

Do not commit:

- `config.local.json`;
- files from `%USERPROFILE%\.codex`;
- copied Codex binaries;
- logs containing local paths;
- provider API keys or authentication files.

These paths are excluded by the repository `.gitignore` where applicable.

## Reporting

Please report vulnerabilities privately to the repository owner rather than opening a public issue containing exploit details or private local data.
