<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-30 | Updated: 2026-04-30 -->

# cfg_tpl

## Purpose
This directory contains configuration templates and systemd unit templates rendered by `install.sh` for Xray-core, Caddy, and Hysteria2 deployments. Templates are the single source for generated server configs, client configs, client parameter summaries, and managed Hysteria2 service units.

## Key Files
| File | Description |
|------|-------------|
| `caddy_config.json` | Caddy template for ACME-managed HTTPS, reverse proxy behavior, and static masquerade site serving. |
| `caddy_existing_cert_config.json` | Caddy template for deployments that reuse an existing certificate and private key. |
| `xray_config.json` | Xray-core server template covering VLESS/REALITY/XHTTP and KCP listener configuration. |
| `xray_client.config.json` | Xray client configuration template populated from generated server parameters. |
| `hysteria2_server.yaml` | Hysteria2 server template for existing-certificate deployments. |
| `hysteria2_server_acme.yaml` | Hysteria2 server template using Hysteria2 ACME certificate management. |
| `hysteria2_client.yaml` | Standard Hysteria2 client YAML template using a single server port. |
| `hysteria2_client_port_hopping.yaml` | Hysteria2 client YAML template for port-hopping deployments. |
| `hysteria2_client_info.txt` | Human-readable Hysteria2 client parameter summary template. |
| `hysteria2.service` | systemd unit template for running the Hysteria2 server with the generated config. |
| `CLAUDE.md` | Existing module notes for configuration-template conventions. |

## Subdirectories
No documented subdirectories.

## For AI Agents

### Working In This Directory
- Keep placeholder names aligned with `install.sh` render calls; every new `${PLACEHOLDER}` must be provided by the installer and covered by tests.
- Keep JSON templates valid JSON after placeholder substitution and YAML templates valid YAML after substitution.
- Do not add Hysteria2 TCP masquerade listeners unless the installer and docs are intentionally updated for that behavior.
- Keep `hysteria2.service` least-privilege; avoid adding capabilities beyond those required by the active service behavior.

### Testing Requirements
- Run `bats tests/hysteria_template.bats` after editing Hysteria2 templates or `hysteria2.service`.
- Run `bats tests/install_hysteria_foundation.bats` after changing template variables consumed by `install.sh`.
- For Xray/Caddy template changes, run the full `bats tests` suite and manually inspect rendered JSON when tests do not cover the new placeholder.

### Common Patterns
- Installer-rendered placeholders use `${UPPER_SNAKE_CASE}` syntax.
- Hysteria2 client info includes both local file paths and shareable URI output, so path fields must stay variable-driven.
- Port-hopping client config uses a range in `server:` and a `hopInterval` under `transport:`.
- Hysteria2 ACME and existing-certificate modes are separate templates to keep certificate ownership rules simple.

## Dependencies

### Internal
- `install.sh` renders these templates into `/etc/hysteria/`, `./app/xray/`, `./app/caddy/`, and related client-output locations.
- `tests/hysteria_template.bats` directly validates template content and placeholder rendering.
- `tests/install_hysteria_foundation.bats` validates installer-level rendering of Hysteria2 templates.

### External
- Xray-core configuration schema for `xray_config.json` and `xray_client.config.json`.
- Caddy JSON admin/config schema for Caddy templates.
- Hysteria2 server/client YAML schema for Hysteria2 templates.
- systemd unit semantics for `hysteria2.service`.

<!-- MANUAL: Any manually added notes below this line are preserved on regeneration -->
