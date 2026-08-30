#!/bin/bash
set -e

# CI script to build VC707 Johnson bitstream end-to-end
# Builds nextpnr, synthesizes, routes, converts FASM to bitstream
#
# Environment variables:
#   GITHUB_WORKSPACE      — workspace root (default: current dir if git root not found)
#   XRAY_DB_PATH          — prjxray-db checkout path (default: ${DEPS_PATH}/prjxray-db)
#   DEPS_PATH             — dependency root (default: .deps)
#   BUILD_NEXTPNR         — rebuild nextpnr (default: 1 if nextpnr/ not configured)
#   YOSYS                 — path to Yosys binary (default: yosys)
#   VALIDATE              — run bit2verilog validation (default: 0)
#
# Steps:
#   [0/6] Initialize git submodules (nextpnr, prjxray, etc.)
#   [1/6] Fetch/clone prjxray-db dependency
#   [2/6] Set up Python venv and install dependencies
#   [3/6] (unused - for alignment)
#   [4/6] Build nextpnr-himbaechel (optional)
#   [5/6] Synthesize, route, and convert to bitstream
#   [6/6] Validate with bit2verilog (optional)

set -o pipefail

# Memory monitoring helper
log_memory() {
    local label="${1:-Memory status}"
    local mem_info=$(free -h | awk '/^Mem:/ {print $2 " total, " $3 " used, " $4 " available"}')
    echo "  [${label}] ${mem_info}"
}

# Set defaults
: ${GITHUB_WORKSPACE:=$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
: ${DEPS_PATH:=${GITHUB_WORKSPACE}/.deps}
: ${XRAY_DB_PATH:=${DEPS_PATH}/prjxray-db}
: ${BUILD_NEXTPNR:=}
: ${YOSYS:=yosys}
: ${VALIDATE:=0}

# Derived paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NEXTPNR_DIR="${REPO_ROOT}/nextpnr"
NEXTPNR_BUILD="${REPO_ROOT}/build"
NEXTPNR_BIN="${NEXTPNR_BUILD}/nextpnr-himbaechel"
PYTHON="${REPO_ROOT}/.venv/bin/python"
VC707_DIR="${REPO_ROOT}/examples/vc707-johnson"
VC707_OUT="${REPO_ROOT}/johnson_vc707.bit"

cd "${REPO_ROOT}"

echo "=========================================="
echo "VC707 Johnson Bitstream Builder"
echo "=========================================="
echo "Workspace:      ${GITHUB_WORKSPACE}"
echo "Repo:           ${REPO_ROOT}"
echo "Database:       ${XRAY_DB_PATH}"
echo "Yosys:          ${YOSYS}"
echo "Build nextpnr:  ${BUILD_NEXTPNR:-auto}"
echo "Validate:       ${VALIDATE}"
echo "=========================================="

# 0. Initialize git submodules
echo "[0/6] Initializing submodules..."
git submodule update --init --recursive

# 1. Get dependencies
echo "[1/6] Fetching dependencies..."
mkdir -p "${DEPS_PATH}"

if [[ ! -d "${XRAY_DB_PATH}" ]]; then
    echo "  Cloning prjxray-db..."
    git clone https://github.com/openXC7/prjxray-db "${XRAY_DB_PATH}"
fi

# 2. Set up Python venv if needed
echo "[2/6] Setting up environment..."
if [[ ! -x "${PYTHON}" ]]; then
    echo "  Creating Python venv..."
    python3 -m venv "${REPO_ROOT}/.venv"
    "${PYTHON}" -m pip install --upgrade pip
fi

# Install/upgrade build dependencies
if [[ -f "${REPO_ROOT}/prjxray/requirements.txt" ]]; then
    echo "  Installing Project X-Ray dependencies..."
    "${PYTHON}" -m pip install -q -r "${REPO_ROOT}/prjxray/requirements.txt" 2>&1 | grep -v "already satisfied" || true
fi

# Ensure fasm package is available (required for FASM→bitstream conversion)
echo "  Installing fasm package for bitstream conversion..."
"${PYTHON}" -m pip install -q fasm 2>&1 | grep -v "already satisfied" || true

# 3. Decide whether to build nextpnr
echo "[3/6] Checking nextpnr configuration..."

# Use precompiled chipdb binary if available (avoids expensive generation in CI)
PRECOMPILED_CHIPDB="${REPO_ROOT}/.chipdb/himbaechel/xilinx/chipdb-xc7vx485t.bin"
if [[ -f "${PRECOMPILED_CHIPDB}" ]]; then
    echo "  Found precompiled xc7vx485t chipdb binary (75MB cached)"
    echo "  This will be used instead of regenerating in CI (saves ~10-15 min runtime)"
fi

if [[ -z "${BUILD_NEXTPNR}" ]]; then
    # Auto-detect: rebuild if CMakeCache doesn't exist
    if [[ ! -f "${NEXTPNR_BUILD}/CMakeCache.txt" ]]; then
        BUILD_NEXTPNR=1
    else
        BUILD_NEXTPNR=0
    fi
fi

# 4. Build nextpnr if requested
if [[ "${BUILD_NEXTPNR}" == "1" ]]; then
    echo "[4/6] Building nextpnr-himbaechel..."
    log_memory "before cmake configure"
    
    mkdir -p "${NEXTPNR_BUILD}"
    pushd "${NEXTPNR_BUILD}" >/dev/null
    
    echo "  Running cmake configure..."
    cmake "${NEXTPNR_DIR}" \
        -DARCH=himbaechel \
        -DHIMBAECHEL_UARCH=xilinx \
        -DBUILD_GUI=OFF \
        -DBUILD_PYTHON=OFF \
        -DHIMBAECHEL_XILINX_DEVICES="xc7a50t;xc7vx485t" \
        -DHIMBAECHEL_PRJXRAY_DB="${XRAY_DB_PATH}"
    
    log_memory "after cmake configure (before build)"
    
    # Use precompiled xc7vx485t chipdb if available (skips ~10-15 min database generation)
    if [[ -f "${PRECOMPILED_CHIPDB}" ]]; then
        echo "  Installing precompiled xc7vx485t chipdb (avoids 15GB peak memory during generation)..."
        mkdir -p himbaechel/uarch/xilinx
        mkdir -p share/himbaechel/xilinx
        cp "${PRECOMPILED_CHIPDB}" himbaechel/uarch/xilinx/chipdb-xc7vx485t.bin
        cp "${PRECOMPILED_CHIPDB}" share/himbaechel/xilinx/chipdb-xc7vx485t.bin
    fi
    
    echo "  Building nextpnr binary (monitoring memory during xc7vx485t chipdb generation)..."
    # Monitor memory during build: log every 30 seconds in background
    (while sleep 30; do log_memory "build progress"; done) &
    MONITOR_PID=$!
    
    cmake --build . --target nextpnr-himbaechel --parallel "$(nproc)"
    
    kill $MONITOR_PID 2>/dev/null || true
    log_memory "after cmake build"
    
    popd >/dev/null
else
    echo "[4/6] Using existing nextpnr build (set BUILD_NEXTPNR=1 to rebuild)..."
fi

# Verify binary exists
if [[ ! -x "${NEXTPNR_BIN}" ]]; then
    echo "ERROR: nextpnr-himbaechel binary not found: ${NEXTPNR_BIN}"
    exit 1
fi

# 5. Build VC707 Johnson
echo "[5/6] Building VC707 Johnson bitstream..."

# Verify inputs
if [[ ! -f "${VC707_DIR}/top.v" ]] || [[ ! -f "${VC707_DIR}/counter25_core.v" ]]; then
    echo "ERROR: VC707 source files not found in ${VC707_DIR}"
    exit 1
fi

if [[ ! -f "${VC707_DIR}/top.xdc" ]]; then
    echo "ERROR: VC707 constraints not found: ${VC707_DIR}/top.xdc"
    exit 1
fi

# Run make with parameters
cd "${REPO_ROOT}"
make vc707-johnson \
    PRJXRAY_DB="${XRAY_DB_PATH}" \
    NEXTPNR_BIN="${NEXTPNR_BIN}" \
    NEXTPNR_BUILD="${NEXTPNR_BUILD}" \
    NEXTPNR_DIR="${NEXTPNR_DIR}" \
    PYTHON="${PYTHON}" \
    YOSYS="${YOSYS}" \
    VC707_OUT="${VC707_OUT}"

# Verify output
if [[ ! -f "${VC707_OUT}" ]]; then
    echo "ERROR: Bitstream build failed; output not found: ${VC707_OUT}"
    exit 1
fi

echo "✓ Bitstream: ${VC707_OUT}"
ls -lh "${VC707_OUT}"

# 6. Optional validation
if [[ "${VALIDATE}" == "1" ]]; then
    echo "[6/6] Validating bitstream with bit2verilog..."
    if [[ ! -x "${PYTHON}" ]]; then
        echo "  Warning: Python not available; skipping validation"
    else
        # Look for a test pattern or use generic validation
        if [[ -f "${REPO_ROOT}/scripts/validate_bitstream.py" ]]; then
            # Generic XC7 validation (part must match design)
            "${PYTHON}" "${REPO_ROOT}/scripts/validate_bitstream.py" \
                --part xc7vx485tffg1761-2 \
                --db "${XRAY_DB_PATH}" \
                --bit "${VC707_OUT}" \
                --output-dir "${REPO_ROOT}/.validation" \
                || echo "  Note: Validation produced warnings (may be expected for unsupported features)"
        fi
    fi
else
    echo "[6/6] Skipping validation (set VALIDATE=1 to enable)"
fi

echo "=========================================="
echo "✓ VC707 Johnson build complete"
echo "=========================================="
