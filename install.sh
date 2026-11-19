#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/pi-monitoring/config-state"
ADOPT_CONFIG=false

log() {
    printf '[INFO] %s\n' "$*"
}

error() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

source "$SCRIPT_DIR/lib/config.sh"

parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --adopt) ADOPT_CONFIG=true ;;
            -h|--help)
                cat <<'HELP'
Usage: sudo ./install.sh [--adopt]

  --adopt   Back up and take ownership of existing, unmanaged configuration.
            Never overwrite a managed file that has been edited manually.
  --help    Show this help.
HELP
                exit 0
                ;;
            *) error "Unknown argument: $arg" ;;
        esac
    done
}

check_root() {
    [[ "$EUID" -eq 0 ]] || error "Please run with sudo"
}

check_environment() {
    log "Checking environment..."
    [[ -f /etc/os-release ]] || error "Unsupported OS"
    # shellcheck source=/dev/null
    source /etc/os-release

    [[ "${ID:-}" == debian ]] || error "Only Debian is currently supported"
    [[ "${VERSION_ID:-}" == 13 ]] || error "Debian 13 is required"
    [[ "$(uname -m)" == aarch64 ]] || error "ARM64 is required"
    command -v systemctl >/dev/null || error "systemd is required"
    log "Environment check passed"
}

setup_grafana_repository() {
    log "Checking Grafana APT repository..."
    local list=/etc/apt/sources.list.d/grafana.list
    local key=/etc/apt/keyrings/grafana.asc
    local expected='deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main'

    if [[ -f "$list" && -s "$key" ]]; then
        grep -Fxq "$expected" "$list" || error "Grafana repository differs: $list"
        log "Grafana repository already configured"
        return 0
    fi

    # Do not overwrite an incomplete pre-existing repository configuration.
    [[ ! -e "$list" && ! -e "$key" ]] ||
        error "Incomplete Grafana repository configuration; inspect $list and $key"

    log "Configuring Grafana APT repository..."
    apt-get update || error "apt-get update failed"
    apt-get install -y ca-certificates wget gnupg || error "Could not install APT prerequisites"
    install -d -m 755 /etc/apt/keyrings || error "Could not create APT keyring directory"

    local tmp_key
    tmp_key="$(mktemp /tmp/pi-monitoring-grafana-key.XXXXXXXX)" || error "Cannot create temporary key file"
    if ! wget -qO "$tmp_key" https://apt.grafana.com/gpg-full.key || [[ ! -s "$tmp_key" ]]; then
        rm -f "$tmp_key"
        error "Could not download Grafana signing key"
    fi
    install -m 644 "$tmp_key" "$key" || error "Cannot install Grafana signing key"
    rm -f "$tmp_key"
    printf '%s\n' "$expected" > "$list" || error "Cannot create Grafana repository list"
    log "Grafana repository configured"
}

install_packages() {
    log "Checking required packages..."
    local packages=(prometheus prometheus-node-exporter prometheus-process-exporter grafana)
    local missing=()
    local pkg

    for pkg in "${packages[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -qx 'install ok installed'; then
            log "$pkg already installed"
        else
            missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        log "All required packages are installed"
        return 0
    fi

    log "Installing: ${missing[*]}"
    apt-get update || error "apt-get update failed"
    apt-get install -y "${missing[@]}" || error "Package installation failed"
}

configure_exporters() {
    log "Configuring Prometheus and Process Exporter..."
    promtool check config "$SCRIPT_DIR/config/prometheus.yml" || error "Invalid Prometheus configuration"

    local prometheus_changed=0 process_changed=0
    if install_config "$SCRIPT_DIR/config/prometheus.yml" /etc/prometheus/prometheus.yml; then
        prometheus_changed=1
    fi
    if install_config "$SCRIPT_DIR/config/process-exporter.yml" /etc/prometheus/process-exporter.yml; then
        process_changed=1
    fi

    if (( prometheus_changed )); then
        systemctl restart prometheus || error "Prometheus restart failed"
    fi
    if (( process_changed )); then
        systemctl restart prometheus-process-exporter || error "Process Exporter restart failed"
    fi
}


configure_service_args() {
    local service="$1"
    local target="$2"
    local desired_args="$3"

    [[ -f "$target" ]] ||
        error "Missing service defaults: $target"

    [[ ! -L "$target" ]] ||
        error "Refusing symlink: $target"

    local count
    count="$(grep -c '^ARGS=' "$target" || true)"

    [[ "$count" == 1 ]] ||
        error "Expected exactly one ARGS entry in $target"

    local staged
    staged="$(mktemp)" || error "Cannot create temporary file"

    # Preserve existing comments and other settings.
    awk -v args="$desired_args" '
        /^ARGS=/ {
            print "ARGS=\"" args "\""
            next
        }
        { print }
    ' "$target" > "$staged" || {
        rm -f "$staged"
        error "Cannot prepare configuration: $target"
    }

    local changed=0

    if install_config "$staged" "$target"; then
        changed=1
    fi

    rm -f "$staged"

    if (( changed )); then
        log "Restarting $service..."
        systemctl restart "$service" ||
            error "Failed to restart $service"

        systemctl is-active --quiet "$service" ||
            error "$service is not active"
    else
        log "Arguments unchanged: $service"
    fi
}

configure_service_defaults() {
    log "Configuring service startup arguments..."

    configure_service_args \
        prometheus \
        /etc/default/prometheus \
        '--storage.tsdb.retention.time=14d --storage.tsdb.retention.size=2GB'

    configure_service_args \
        prometheus-process-exporter \
        /etc/default/prometheus-process-exporter \
        '-config.path=/etc/prometheus/process-exporter.yml'
}
main() {
    parse_args "$@"
    log "Starting Pi Monitoring Installer"

    check_root
    check_environment
    setup_grafana_repository
    install_packages

    configure_exporters
    configure_service_defaults

    log "Configuration stage completed"
    log "NOTE: Grafana provisioning and health checks are not yet automated."
}

main "$@"

