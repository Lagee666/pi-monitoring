#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    echo "[INFO] $*"
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

check_environment() {
    log "Checking environment..."

    [[ -f /etc/os-release ]] || error "Unsupported OS"

    # shellcheck source=/dev/null
    source /etc/os-release

    [[ "${ID}" == "debian" ]] ||
        error "Only Debian is currently supported"

    [[ "${VERSION_ID}" == "13" ]] ||
        error "Debian 13 is required"

    [[ "$(uname -m)" == "aarch64" ]] ||
        error "ARM64 is required"

    command -v systemctl >/dev/null ||
        error "systemd is required"

    log "Environment check passed"
}

main() {
    log "Starting Pi Monitoring Installer"

    check_environment

    log "Installer preflight completed"
}

main "$@"
