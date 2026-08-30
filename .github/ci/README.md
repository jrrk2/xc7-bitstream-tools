# xc7-bitstream-tools CI Scripts

This directory contains CI/build automation scripts for the orchestration repository.

## Scripts

### `common.sh`

Common setup and utility functions shared across CI scripts. Provides logging, error handling, and environment setup.

Source this in other scripts:
```bash
source .github/ci/common.sh
```

Available functions:
- `log_section <message>` — print a header section
- `log_step <message>` — print a step message
- `log_success <message>` — print a success message
- `log_error <message>` — print an error message
- `check_executable <cmd> [name]` — verify a binary is in PATH
- `check_file <path>` — verify a file exists
- `check_dir <path>` — verify a directory exists

### `build_vc707.sh`

End-to-end builder for VC707 Johnson bitstream:
1. Fetches dependencies (prjxray-db)
2. Sets up Python venv
3. Optionally builds nextpnr-himbaechel
4. Synthesizes VC707 Johnson with Yosys
5. Routes with nextpnr
6. Converts FASM → bitstream via Project X-Ray
7. Optionally validates with bit2verilog

**Usage (local):**
```bash
bash .github/ci/build_vc707.sh
```

**Environment variables:**
- `GITHUB_WORKSPACE` — repo root (default: git root)
- `DEPS_PATH` — dependency cache (default: `.deps`)
- `XRAY_DB_PATH` — prjxray-db path (default: `${DEPS_PATH}/prjxray-db`)
- `BUILD_NEXTPNR` — rebuild nextpnr (default: auto-detect)
- `YOSYS` — Yosys binary path (default: `yosys`)
- `VALIDATE` — run bit2verilog validation (default: 0)

**Example:**
```bash
# Build with validation
VALIDATE=1 bash .github/ci/build_vc707.sh

# Force nextpnr rebuild
BUILD_NEXTPNR=1 bash .github/ci/build_vc707.sh
```

## GitHub Actions Workflows

### `build-vc707.yml`

Automated workflow triggered on:
- Pushes to `main` (changes to VC707 examples, scripts, backends, or CI files)
- Pull requests to `main`
- Manual workflow dispatch

Runs on Ubuntu, installs dependencies, and executes `build_vc707.sh`.

**Artifacts:**
- `vc707-bitstream` — built `johnson_vc707.bit` (7-day retention)

## Adding New CI Scripts

1. Create a new script in this directory (e.g., `build_foo.sh`)
2. Source `common.sh` for standard functions
3. Use environment variables for paths (see `build_vc707.sh`)
4. Create a corresponding workflow in `.github/workflows/` if needed

Example:
```bash
#!/bin/bash
set -e
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log_section "Building Foo"
log_step "Step 1"
# ... do work ...
log_success "Foo build complete"
```
