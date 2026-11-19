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

setup_grafana_repository() {
    log "Checking Grafana APT repository..."

    if [[ -f /etc/apt/sources.list.d/grafana.list ]] &&
       [[ -f /etc/apt/keyrings/grafana.asc ]]; then
        log "Grafana repository already configured"
        return
    fi

    log "Configuring Grafana APT repository..."

    apt-get update
    apt-get install -y ca-certificates wget gnupg

    install -d -m 755 /etc/apt/keyrings

    wget -qO /tmp/grafana.asc \
        https://apt.grafana.com/gpg-full.key

    install -m 644 /tmp/grafana.asc \
        /etc/apt/keyrings/grafana.asc

    cat > /etc/apt/sources.list.d/grafana.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main
EOF

    log "Grafana repository configured"
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
    setup_grafana_repository
    install_packages

    log "Package installation completed"
}

main "$@"
