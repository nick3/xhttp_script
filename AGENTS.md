<!-- Generated: 2026-04-30 | Updated: 2026-04-30 -->

# xhttp_script

## Purpose
This repository contains Bash scripts for deploying and managing Xray-core, Caddy, and Hysteria2 on Debian/Ubuntu systems. The main workflow is an interactive installer and service manager with profile-aware support for `xraycaddy`, `hysteria2`, and `all` deployments.

## Key Files
| File | Description |
|------|-------------|
| `main.sh` | Interactive menu entrypoint for installation, configuration changes, service actions, client info display, startup enablement, and uninstall. |
| `install.sh` | Installer implementation for argument parsing, preflight checks, template rendering, generated secrets, systemd units, health checks, and install state. |
| `service.sh` | Legacy foreground/fallback service manager for Xray and Caddy using local binaries, PID files, and log files. |
| `download.sh` | Component downloader for Caddy, Xray-core, and Hysteria2 using `dra`, archive extraction, and Hysteria2 hash verification. |
| `update.sh` | Update and backup manager for Xray/Caddy binaries and rollback workflows. |
| `install_remote.sh` | Remote bootstrap script used by the README one-line install commands. |
| `VERSION` | Release version marker for the script bundle. |
| `README.md` | User-facing installation, profile, operation, testing, and troubleshooting documentation. |
| `CERT_MANAGEMENT.md` | Certificate-management guidance for supported deployment modes. |
| `TODOS.md` | Project task notes and follow-up items. |
| `REVIEW_ANALYSIS.md` | Review-analysis notes for recent PR feedback. |
| `FIXES_SUMMARY.md` | Summary of recent fixes and validation notes. |
| `CLAUDE.md` | Existing Claude Code project instructions and architecture notes. |
| `main.sh.CLAUDE.md` | Module notes for the interactive menu script. |
| `install.sh.CLAUDE.md` | Module notes for the installer script. |
| `service.sh.CLAUDE.md` | Module notes for the service manager script. |
| `download.sh.CLAUDE.md` | Module notes for the downloader script. |
| `dra` | Bundled GitHub release asset downloader used by `download.sh`. |

## Subdirectories
| Directory | Purpose |
|-----------|---------|
| `cfg_tpl/` | Configuration and systemd templates rendered by `install.sh` (see `cfg_tpl/AGENTS.md`). |
| `tests/` | Bats test suite for downloader behavior, installer argument parsing, template rendering, and preflight checks (see `tests/AGENTS.md`). |

## For AI Agents

### Working In This Directory
- Treat `main.sh` as the user-facing orchestration layer and `install.sh` as the deployment implementation; avoid duplicating installer logic in the menu layer.
- Keep profile behavior explicit for `xraycaddy`, `hysteria2`, and `all`; changes that touch ports, certificates, systemd units, or client output usually need updates in scripts, templates, tests, and README together.
- Preserve Bash portability for Debian/Ubuntu system environments; avoid features that require newer Bash versions unless existing tests and requirements are updated.
- Do not commit generated runtime output such as `app/`, `backups/`, `.omc/`, `.gstack/`, `.expect/`, logs, or downloaded release artifacts unless the user explicitly asks.

### Testing Requirements
- Run `tests/run.sh` or `bats tests` after changes to `install.sh`, `download.sh`, templates, or test helpers.
- Add or update Bats coverage when changing argument parsing, template variables, certificate modes, Hysteria2 URI generation, checksum parsing, port constraints, or systemd unit behavior.
- For README-only changes, verify that profile names, default ports, file paths, and menu option descriptions still match the scripts.

### Common Patterns
- Template placeholders use `${NAME}` syntax and are rendered by installer helper functions rather than ad hoc per-file substitutions.
- Install state is centralized under `/etc/xray-caddy/install_state.env` for profile-aware service management.
- Hysteria2 defaults away from UDP/443; UDP/443 is reserved for XHTTP, and `all` profile port hopping must also avoid Xray KCP UDP/2052.
- Sensitive values such as KCP seed and Hysteria2 auth passwords should be registered for redaction before logging or test output assertions.

## Dependencies

### Internal
- `main.sh` calls `install.sh`, `service.sh`, `update.sh`, and reads install state for systemd-aware service management.
- `install.sh` consumes templates from `cfg_tpl/` and writes service/client configuration outputs.
- `download.sh` prepares component binaries consumed by `install.sh` and `service.sh`.
- `tests/` sources project scripts and copies `download.sh` into temporary workspaces for isolated assertions.

### External
- Debian/Ubuntu Linux on x86_64 with root privileges for real installation.
- systemd for managed services and `journalctl`-based diagnostics.
- Shell tools: `bash`, `curl`, `tar`, `unzip`, `sed`, `awk`, `grep`, `mkdir`, `chmod`, and checksum utilities.
- `dra` for GitHub release asset downloads.
- Bats for local automated tests.

<!-- MANUAL: Any manually added notes below this line are preserved on regeneration -->
