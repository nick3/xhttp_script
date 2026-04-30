# TODOs

## Caddy ACME certificate sync for all profile

**What:** Add a second-phase flow that lets `all` profile reuse certificates obtained by Caddy ACME for Hysteria2.

**Why:** `all` profile currently requires existing certs to avoid hidden certificate ownership and renewal problems. Reusing Caddy ACME would improve first-run experience once sync semantics are safe.

**Pros:** Users can install `all` without manually preparing cert/key files; Caddy remains the only ACME owner.

**Cons:** Needs a safe certificate copy/symlink strategy, renewal detection, permissions, failure alerts, and Hysteria2 reload/restart behavior.

**Context:** The current design deliberately keeps `all` as existing-cert-only. A future implementation should define the Caddy certificate source path, the `/etc/hysteria` target path, renewal sync trigger, file permissions, and how health reports expose sync failures.

**Depends on / blocked by:** Stable text health report, `install_state.env`, and a verified Caddy certificate storage/sync strategy.

## Machine-readable install_report.json

**What:** Add `install_report.json` alongside the human-readable health report.

**Why:** Text reports are good for humans, but JSON enables issue templates, CI checks, and automated diagnosis.

**Pros:** Community users can attach structured diagnostics; future tooling can parse binary/config/systemd/listener/cert/client-info status reliably.

**Cons:** Requires a stable schema, versioning policy, and compatibility commitment once published.

**Context:** The current plan keeps text health output as the first stable surface. Add JSON after the PASS/WARN/FAIL check names and profile-specific report shape settle.

**Depends on / blocked by:** Stable health check names and profile-driven report aggregation.

## Hysteria2 operational support in `main.sh` and `service.sh`

**What:** Extend the main menu and `service.sh` so Hysteria2 is included in restart, stop, status, debug/fallback, and profile-aware service lifecycle commands.

**Why:** Installation now supports `hysteria2` and `all`, but post-install operations still mostly assume Xray/Caddy. Users who install Hysteria2 should not need to remember separate systemd commands for routine management.

**Pros:** Operators get one consistent menu and fallback/status entry point for every installed service; `all` profile can manage Caddy, Xray, and Hysteria2 together.

**Cons:** Requires profile detection from `install_state.env`, Hysteria2 PID/log handling if fallback mode is added, and service-state tests for single-protocol and `all` installs.

**Context:** First version should at least make `main.sh` and `service.sh status` Hysteria2-aware through systemd. Full fallback support can come later if systemd is unavailable.

**Depends on / blocked by:** Hysteria2 systemd path, unified install state, and service status tests.

## Hysteria2 client info viewing in the main menu

**What:** Add a main-menu path to display `/etc/hysteria/client_config_info.txt` and generated Hysteria2 client YAML, including port hopping details when enabled.

**Why:** The current client-info menu path is Xray-oriented. Hysteria2 users need a discoverable way to retrieve URI, SNI, auth, local SOCKS5 port, and port hopping range after installation.

**Pros:** Reduces support friction and keeps Hysteria2 setup usable without manually browsing `/etc/hysteria`.

**Cons:** Needs profile-aware display logic and redaction rules so auth passwords are not printed accidentally in unsafe contexts.

**Context:** For `all`, the menu should offer both Xray/Caddy client info and Hysteria2 client info instead of assuming a single protocol family.

**Depends on / blocked by:** Unified install state and stable Hysteria2 client info template.

## Hysteria2 update flow

**What:** Extend update logic so users can update Hysteria2 binaries alongside Xray and Caddy, with checksum verification through the existing `download.sh hysteria2` path.

**Why:** Menu option 7 still reads as Xray/Caddy-focused. Hysteria2 installs need a supported update path with the same safety properties as initial download.

**Pros:** Keeps Hysteria2 deployments maintainable and reuses the fail-closed downloader behavior.

**Cons:** Requires service stop/start ordering, rollback behavior if the new binary fails health checks, and tests with fake downloader failures.

**Context:** `all` profile update should handle Xray, Caddy, and Hysteria2 without partially updating silently.

**Depends on / blocked by:** Profile-aware health checks and a rollback/restore policy for Hysteria2.

## Hysteria2 uninstall and port hopping cleanup

**What:** Extend uninstall logic to remove Hysteria2 systemd units, `/etc/hysteria` configs, `/usr/local/bin/hysteria`, and `hysteria2-port-hopping.service` plus generated REDIRECT rules when port hopping was enabled.

**Why:** Port hopping writes firewall state outside the Hysteria2 config file. Uninstall must clean that state or future services may inherit stale UDP redirects.

**Pros:** Prevents hidden firewall leftovers and makes reinstall/profile switching safer.

**Cons:** Needs careful prompts before deleting config files and must avoid removing unrelated user-managed firewall rules.

**Context:** Cleanup should only remove rules generated by this installer, preferably via the generated rule script and install state metadata.

**Depends on / blocked by:** Persisted port hopping state in `install_state.env` and verified remove/status behavior for the generated rule script.
