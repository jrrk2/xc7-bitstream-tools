#!/bin/bash
set -e

# Common setup functions for xc7-bitstream-tools CI
# Source this file in other CI scripts

export REPO_ROOT="${GITHUB_WORKSPACE:=$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export DEPS_PATH="${DEPS_PATH:=${REPO_ROOT}/.deps}"
export XRAY_DB_PATH="${XRAY_DB_PATH:=${DEPS_PATH}/prjxray-db}"

function log_section() {
    echo ""
    echo "=========================================="
    echo "$@"
    echo "=========================================="
}

function log_step() {
    echo "→ $@"
}

function log_success() {
    echo "✓ $@"
}

function log_error() {
    echo "ERROR: $@" >&2
}

function check_executable() {
    local cmd="$1"
    local name="${2:-${cmd}}"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        log_error "${name} not found in PATH"
        return 1
    fi
    return 0
}

function check_file() {
    local file="$1"
    if [[ ! -f "${file}" ]]; then
        log_error "File not found: ${file}"
        return 1
    fi
    return 0
}

function check_dir() {
    local dir="$1"
    if [[ ! -d "${dir}" ]]; then
        log_error "Directory not found: ${dir}"
        return 1
    fi
    return 0
}
