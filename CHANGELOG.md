# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/) · Versioning: [SemVer](https://semver.org/)

## [1.0.0] - 2026-09-29
### Added
- One-line installer `install.sh` for Ubuntu 24.04 x86_64 (interactive and `--yes` modes).
- Multi-instance Psiphon (`psiphon@<CC>.service` template unit), one egress country per instance.
- Local bind IP `127.20.0.1` on dummy interface `psi0` (persistent via `psiphon-net.service`), with fallback to `127.0.0.1`.
- Per-instance SOCKS5 (`10800+i`) and HTTP (`10900+i`) proxies.
- Xray-core router: one SOCKS inbound per country (`20000+i`) routed by `inboundTag` to the matching Psiphon instance.
- `psictl` management CLI: status, list, start/stop/restart, test, wait, logs, add-region, remove-region, import-config, reconfigure, health, update, uninstall.
- systemd hardening, logrotate, health-check timer (auto-restart broken instances).
- ISO 3166-1 alpha-2 validation, idempotent re-install (keeps ports/regions/config).
- `uninstall.sh` for full cleanup.
- GitHub Actions ShellCheck workflow.

### Known / needs verification
- Psiphon network parameters are placeholders (`TODO_VERIFY_*`) and must be supplied by the user.
