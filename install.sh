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

install_packages() {
    log "Checking required packages..."

    local packages=(
        prometheus
        prometheus-node-exporter
        prometheus-process-exporter
        grafana
    )

    local missing=()

    for pkg in "${packages[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
            | grep -qx "install ok installed"; then
            log "$pkg already installed"
        else
            missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        log "All required packages are installed"
        return
    fi

    log "Installing: ${missing[*]}"

    apt-get update
    apt-get install -y "${missing[@]}"
}

main() {
    log "Starting Pi Monitoring Installer"

    check_environment
    install_packages

    log "Package installation completed"
}

main "$@"
