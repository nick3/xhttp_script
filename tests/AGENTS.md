<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-30 | Updated: 2026-04-30 -->

# tests

## Purpose
This directory contains the Bats test suite for the Bash deployment scripts. Tests focus on isolated validation of downloader behavior, installer argument parsing, Hysteria2 template rendering, port-hopping rules, install-state output, and preflight checks without performing real system installation.

## Key Files
| File | Description |
|------|-------------|
| `run.sh` | Local test runner wrapper for executing the suite from the repository root. |
| `helpers.bash` | Shared Bats helpers for sourcing installer functions, rendering templates, faking `dra`, and running downloads in temporary workspaces. |
| `download_hysteria.bats` | Tests Hysteria2 binary download, checksum verification, failure handling, and profile-specific component downloads. |
| `install_args.bats` | Tests installer CLI argument parsing and validation for install profiles and Hysteria2 options. |
| `hysteria_template.bats` | Tests Hysteria2 server/client templates, client info template output, and the Hysteria2 systemd unit. |
| `install_hysteria_foundation.bats` | Tests installer-level Hysteria2 rendering, URI encoding, port-hopping script/unit generation, template escaping, install state, and secret redaction. |
| `install_preflight.bats` | Tests installation preflight checks and failure paths before system-level changes run. |

## Subdirectories
No documented subdirectories.

## For AI Agents

### Working In This Directory
- Keep tests hermetic: use `$BATS_TEST_TMPDIR` and fake binaries/helpers instead of touching real `/etc`, systemd, network, or production services.
- Source `install.sh` through `source_install_script` when testing functions directly, and run `download.sh` through `run_download` when isolated downloader behavior is needed.
- Extend existing test files by behavior area instead of creating new broad catch-all files.
- When adding fake command behavior, make the fake output minimal and assert the specific safety property being tested.

### Testing Requirements
- Run `bats tests` or `tests/run.sh` before claiming script, template, or helper changes are complete.
- Run targeted tests first when iterating, then the full suite before final verification.
- For downloader changes, verify both success and fail-closed behavior so old binaries are preserved on failed updates.
- For template changes, assert rendered content rather than only file existence.

### Common Patterns
- `setup_download_test` copies `download.sh` into a temporary workspace and injects fake `dra` behavior.
- `render_template` performs simple placeholder substitution for direct template tests.
- `parse_args` is called inside tests before invoking installer functions that depend on global parsed variables.
- Redaction tests register secrets before checking logged or generated output.

## Dependencies

### Internal
- `install.sh` provides parsing, rendering, port-hopping, install-state, URI, and redaction functions used by the tests.
- `download.sh` is copied into temporary directories for component download tests.
- `cfg_tpl/` templates are read directly by template tests and indirectly through installer rendering tests.

### External
- Bats test framework.
- Standard Unix tools used by the scripts and fakes, including `bash`, `tar`, `zip`, `chmod`, and checksum tools.

<!-- MANUAL: Any manually added notes below this line are preserved on regeneration -->
