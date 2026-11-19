
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/pi-monitoring/config-state"
ADOPT_CONFIG=false
WORK_DIR=""

log() {
    printf '[INFO] %s\n' "$*"
}

error() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

trap cleanup EXIT

# Provides install_config(), SHA-256 ownership and backups.
source "$SCRIPT_DIR/lib/config.sh"

parse_args() {
    local arg

    for arg in "$@"; do
        case "$arg" in
            --adopt)
                ADOPT_CONFIG=true
                ;;
            -h|--help)
                cat <<'HELP'
Usage: sudo ./install.sh [--adopt]

  --adopt   Back up and take ownership of existing unmanaged
            configuration files that differ from this repository.

            Does not overwrite manually modified managed files.

  --help    Show this help.
HELP
                exit 0
                ;;
            *)
                error "Unknown argument: $arg"
                ;;
        esac
    done
}

check_root() {
    [[ "$EUID" -eq 0 ]] ||
        error "Please run with sudo"
}

check_environment() {
    log "Checking environment..."

    [[ -f /etc/os-release ]] ||
        error "Unsupported OS"

    # shellcheck source=/dev/null
    source /etc/os-release

    [[ "${ID:-}" == debian ]] ||
        error "Only Debian is currently supported"

    [[ "${VERSION_ID:-}" == 13 ]] ||
        error "Debian 13 is required"

    [[ "$(uname -m)" == aarch64 ]] ||
        error "ARM64 is required"

    command -v systemctl >/dev/null ||
        error "systemd is required"

    [[ -f "$SCRIPT_DIR/config/prometheus.yml" ]] ||
        error "Missing config/prometheus.yml"

    [[ -f "$SCRIPT_DIR/config/process-exporter.yml" ]] ||
        error "Missing config/process-exporter.yml"

    [[ -f "$SCRIPT_DIR/lib/config.sh" ]] ||
        error "Missing lib/config.sh"

    log "Environment check passed"
}

setup_grafana_repository() {
    log "Checking Grafana APT repository..."

    local list=/etc/apt/sources.list.d/grafana.list
    local key=/etc/apt/keyrings/grafana.asc

    local expected
    expected='deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main'

    if [[ -f "$list" && -s "$key" ]]; then
        grep -Fxq "$expected" "$list" ||
            error "Grafana repository differs: $list"

        log "Grafana repository already configured"
        return 0
    fi

    [[ ! -e "$list" && ! -e "$key" ]] ||
        error "Incomplete Grafana repository configuration"

    log "Configuring Grafana APT repository..."

    apt-get update ||
        error "apt-get update failed"

    apt-get install -y ca-certificates wget gnupg ||
        error "Could not install APT prerequisites"

    install -d -m 755 /etc/apt/keyrings ||
        error "Cannot create APT keyring directory"

    local tmp_key
    tmp_key="$(mktemp /tmp/pi-monitoring-grafana-key.XXXXXXXX)" ||
        error "Cannot create temporary key file"

    if ! wget -qO "$tmp_key" \
        https://apt.grafana.com/gpg-full.key ||
        [[ ! -s "$tmp_key" ]]; then

        rm -f "$tmp_key"
        error "Could not download Grafana signing key"
    fi

    install -m 644 "$tmp_key" "$key" ||
        error "Cannot install Grafana signing key"

    rm -f "$tmp_key"

    printf '%s\n' "$expected" > "$list" ||
        error "Cannot create Grafana repository list"

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
    local pkg

    for pkg in "${packages[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null |
            grep -qx 'install ok installed'; then

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

    apt-get update ||
        error "apt-get update failed"

    apt-get install -y "${missing[@]}" ||
        error "Package installation failed"
}

# Generate the desired /etc/default configuration without
# changing the original file.
prepare_service_args() {
    local target="$1"
    local desired_args="$2"
    local output="$3"
    local count

    [[ ! -L "$target" ]] ||
        error "Refusing symlink: $target"

    [[ -f "$target" ]] ||
        error "Missing service defaults: $target"

    count="$(grep -c '^ARGS=' "$target" || true)"

    [[ "$count" == 1 ]] ||
        error "Expected exactly one ARGS entry in $target"

    awk -v args="$desired_args" '
        /^ARGS=/ {
            print "ARGS=\"" args "\""
            next
        }
        { print }
    ' "$target" > "$output" ||
        error "Cannot prepare $target"
}

# Read-only conflict detection.
# All target files are checked before any config is applied.
preflight_config() {
    local source="$1"
    local target="$2"

    local key state_file
    local current_hash expected_hash new_hash

    [[ -f "$source" ]] ||
        error "Missing source: $source"

    [[ ! -L "$target" ]] ||
        error "Refusing symlink: $target"

    key="$(printf '%s' "$target" | sha256sum | cut -d' ' -f1)"
    state_file="$STATE_DIR/$key.sha256"

    new_hash="$(sha256sum "$source" | cut -d' ' -f1)"

    if [[ ! -e "$target" ]]; then
        [[ ! -f "$state_file" ]] ||
            error "Previously managed config is missing: $target"

        log "New configuration: $target"
        return 0
    fi

    [[ -f "$target" ]] ||
        error "Target is not a regular file: $target"

    current_hash="$(sha256sum "$target" | cut -d' ' -f1)"

    if [[ -f "$state_file" ]]; then
        expected_hash="$(cat "$state_file")"

        [[ "$current_hash" == "$expected_hash" ]] ||
            error "Managed config was modified: $target"

        if [[ "$current_hash" == "$new_hash" ]]; then
            log "Configuration unchanged: $target"
        else
            log "Managed configuration update: $target"
        fi

        return 0
    fi

    if [[ "$current_hash" == "$new_hash" ]]; then
        log "Identical unmanaged config: $target"
        return 0
    fi

    [[ "$ADOPT_CONFIG" == true ]] ||
        error "Unmanaged config differs: $target (use --adopt)"

    log "Will back up and adopt: $target"
}

# install_config returns:
# 0 = changed
# 1 = unchanged
apply_config() {
    local source="$1"
    local target="$2"

    if install_config "$source" "$target"; then
        return 0
    fi

    return 1
}

configure_monitoring() {
    log "Preparing monitoring configurations..."

    WORK_DIR="$(mktemp -d)" ||
        error "Cannot create temporary directory"

    local prometheus_config
    local process_config
    local prometheus_defaults
    local process_defaults

    prometheus_config="$SCRIPT_DIR/config/prometheus.yml"
    process_config="$SCRIPT_DIR/config/process-exporter.yml"

    prometheus_defaults="$WORK_DIR/prometheus-defaults"
    process_defaults="$WORK_DIR/process-defaults"

    # Validate configuration before changing system files.
    promtool check config "$prometheus_config" ||
        error "Invalid Prometheus configuration"

    prepare_service_args \
        /etc/default/prometheus \
        '--storage.tsdb.retention.time=14d --storage.tsdb.retention.size=2GB' \
        "$prometheus_defaults"

    prepare_service_args \
        /etc/default/prometheus-process-exporter \
        '-config.path=/etc/prometheus/process-exporter.yml' \
        "$process_defaults"

    # Phase 1: check all conflicts before applying anything.
    log "Checking configuration conflicts..."

    preflight_config \
        "$prometheus_config" \
        /etc/prometheus/prometheus.yml

    preflight_config \
        "$process_config" \
        /etc/prometheus/process-exporter.yml

    preflight_config \
        "$prometheus_defaults" \
        /etc/default/prometheus

    preflight_config \
        "$process_defaults" \
        /etc/default/prometheus-process-exporter

    # Phase 2: apply configuration changes.
    log "Applying monitoring configurations..."

    local prometheus_changed=0
    local process_changed=0

    if apply_config \
        "$prometheus_config" \
        /etc/prometheus/prometheus.yml; then
        prometheus_changed=1
    fi

    if apply_config \
        "$process_config" \
        /etc/prometheus/process-exporter.yml; then
        process_changed=1
    fi

    if apply_config \
        "$prometheus_defaults" \
        /etc/default/prometheus; then
        prometheus_changed=1
    fi

    if apply_config \
        "$process_defaults" \
        /etc/default/prometheus-process-exporter; then
        process_changed=1
    fi

    # Phase 3: start services, restarting changed ones only once.
    log "Starting monitoring services..."

    systemctl enable --now prometheus-node-exporter ||
        error "Failed to start Node Exporter"

    systemctl enable prometheus ||
        error "Failed to enable Prometheus"

    systemctl enable prometheus-process-exporter ||
        error "Failed to enable Process Exporter"

    if (( prometheus_changed )); then
        log "Restarting Prometheus..."
        systemctl restart prometheus ||
            error "Prometheus restart failed"
    else
        systemctl start prometheus ||
            error "Prometheus start failed"
    fi

    if (( process_changed )); then
        log "Restarting Process Exporter..."
        systemctl restart prometheus-process-exporter ||
            error "Process Exporter restart failed"
    else
        systemctl start prometheus-process-exporter ||
            error "Process Exporter start failed"
    fi

    systemctl is-active --quiet prometheus ||
        error "Prometheus is not active"

    systemctl is-active --quiet prometheus-node-exporter ||
        error "Node Exporter is not active"

    systemctl is-active --quiet prometheus-process-exporter ||
        error "Process Exporter is not active"

    log "Monitoring services configured"
}

main() {
    parse_args "$@"

    log "Starting Pi Monitoring Installer"

    check_root
    check_environment

    setup_grafana_repository
    install_packages
    configure_monitoring

    log "Configuration stage completed"
    log "NOTE: Grafana provisioning and health checks are not yet automated."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
