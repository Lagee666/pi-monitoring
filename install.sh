
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

  --adopt   Back up and adopt existing unmanaged configuration.
            Never overwrite a manually modified managed config.

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
        error "Only Debian is supported"

    [[ "${VERSION_ID:-}" == 13 ]] ||
        error "Debian 13 is required"

    [[ "$(uname -m)" == aarch64 ]] ||
        error "ARM64 is required"

    command -v systemctl >/dev/null ||
        error "systemd is required"

    local required=(
        lib/config.sh
        config/prometheus.yml
        config/process-exporter.yml
        grafana/grafana.env
        grafana/systemd/override.conf
        grafana/provisioning/datasources/prometheus.yml
        grafana/provisioning/dashboards/pi-monitoring.yml
        grafana/dashboards/system-overview.json
        grafana/dashboards/process-overview.json
    )

    local file
    for file in "${required[@]}"; do
        [[ -f "$SCRIPT_DIR/$file" ]] ||
            error "Missing file: $file"
    done

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
        error "Cannot install APT prerequisites"

    install -d -m 755 /etc/apt/keyrings

    local tmp_key
    tmp_key="$(mktemp)" ||
        error "Cannot create temporary key file"

    if ! wget -qO "$tmp_key" \
        https://apt.grafana.com/gpg-full.key ||
        [[ ! -s "$tmp_key" ]]; then
        rm -f "$tmp_key"
        error "Cannot download Grafana signing key"
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
        python3
        wget
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
        error "Expected exactly one ARGS entry: $target"

    awk -v args="$desired_args" '
        /^ARGS=/ {
            print "ARGS=\"" args "\""
            next
        }
        { print }
    ' "$target" > "$output" ||
        error "Cannot prepare $target"
}

# Read-only configuration ownership check.
preflight_config() {
    local source="$1"
    local target="$2"

    local key state_file
    local current_hash expected_hash new_hash

    [[ -f "$source" ]] ||
        error "Missing source: $source"

    [[ ! -L "$target" ]] ||
        error "Refusing symlink: $target"

    key="$(printf '%s' "$target" |
        sha256sum | cut -d' ' -f1)"

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
            log "Unchanged: $target"
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

# Return 0 for changed and 1 for unchanged.
apply_config() {
    local source="$1"
    local target="$2"

    if install_config "$source" "$target"; then
        return 0
    fi

    return 1
}

prepare_configs() {
    log "Preparing configurations..."

    WORK_DIR="$(mktemp -d)" ||
        error "Cannot create temporary directory"

    promtool check config \
        "$SCRIPT_DIR/config/prometheus.yml" ||
        error "Invalid Prometheus configuration"

    python3 -m json.tool \
        "$SCRIPT_DIR/grafana/dashboards/system-overview.json" \
        >/dev/null ||
        error "Invalid System Overview JSON"

    python3 -m json.tool \
        "$SCRIPT_DIR/grafana/dashboards/process-overview.json" \
        >/dev/null ||
        error "Invalid Process Overview JSON"

    prepare_service_args \
        /etc/default/prometheus \
        '--storage.tsdb.retention.time=14d --storage.tsdb.retention.size=2GB' \
        "$WORK_DIR/prometheus-defaults"

    prepare_service_args \
        /etc/default/prometheus-process-exporter \
        '-config.path=/etc/prometheus/process-exporter.yml' \
        "$WORK_DIR/process-defaults"

    log "Configurations prepared"
}

# Central list of all managed configuration files.
build_config_list() {
    CONFIG_SOURCES=(
        "$SCRIPT_DIR/config/prometheus.yml"
        "$SCRIPT_DIR/config/process-exporter.yml"
        "$WORK_DIR/prometheus-defaults"
        "$WORK_DIR/process-defaults"
        "$SCRIPT_DIR/grafana/grafana.env"
        "$SCRIPT_DIR/grafana/systemd/override.conf"
        "$SCRIPT_DIR/grafana/provisioning/datasources/prometheus.yml"
        "$SCRIPT_DIR/grafana/provisioning/dashboards/pi-monitoring.yml"
        "$SCRIPT_DIR/grafana/dashboards/system-overview.json"
        "$SCRIPT_DIR/grafana/dashboards/process-overview.json"
    )

    CONFIG_TARGETS=(
        /etc/prometheus/prometheus.yml
        /etc/prometheus/process-exporter.yml
        /etc/default/prometheus
        /etc/default/prometheus-process-exporter
        /etc/pi-monitoring/grafana.env
        /etc/systemd/system/grafana-server.service.d/override.conf
        /etc/grafana/provisioning/datasources/prometheus.yml
        /etc/grafana/provisioning/dashboards/pi-monitoring.yml
        /etc/grafana/dashboards/system-overview.json
        /etc/grafana/dashboards/process-overview.json
    )
}

check_all_conflicts() {
    log "Checking configuration conflicts..."

    local i

    for i in "${!CONFIG_SOURCES[@]}"; do
        preflight_config \
            "${CONFIG_SOURCES[$i]}" \
            "${CONFIG_TARGETS[$i]}"
    done

    log "Configuration preflight passed"
}

apply_all_configs() {
    log "Applying configurations..."

    PROMETHEUS_CHANGED=0
    PROCESS_CHANGED=0
    GRAFANA_CHANGED=0
    GRAFANA_UNIT_CHANGED=0

    local i

    for i in "${!CONFIG_SOURCES[@]}"; do
        if apply_config \
            "${CONFIG_SOURCES[$i]}" \
            "${CONFIG_TARGETS[$i]}"; then

            case "$i" in
                0|2)
                    PROMETHEUS_CHANGED=1
                    ;;
                1|3)
                    PROCESS_CHANGED=1
                    ;;
                5)
                    GRAFANA_CHANGED=1
                    GRAFANA_UNIT_CHANGED=1
                    ;;
                4|6|7|8|9)
                    GRAFANA_CHANGED=1
                    ;;
            esac
        fi
    done

    log "Configurations applied"
}

start_monitoring_services() {
    log "Starting monitoring services..."

    systemctl enable --now prometheus-node-exporter ||
        error "Cannot start Node Exporter"

    systemctl enable prometheus ||
        error "Cannot enable Prometheus"

    systemctl enable prometheus-process-exporter ||
        error "Cannot enable Process Exporter"

    if (( PROMETHEUS_CHANGED )); then
        log "Restarting Prometheus..."
        systemctl restart prometheus ||
            error "Prometheus restart failed"
    else
        systemctl start prometheus ||
            error "Prometheus start failed"
    fi

    if (( PROCESS_CHANGED )); then
        log "Restarting Process Exporter..."
        systemctl restart prometheus-process-exporter ||
            error "Process Exporter restart failed"
    else
        systemctl start prometheus-process-exporter ||
            error "Process Exporter start failed"
    fi

    log "Monitoring services started"
}

start_grafana() {
    log "Starting Grafana..."

    if (( GRAFANA_UNIT_CHANGED )); then
        log "Reloading systemd..."
        systemctl daemon-reload ||
            error "systemd reload failed"
    fi

    systemctl enable grafana-server ||
        error "Cannot enable Grafana"

    if (( GRAFANA_CHANGED )); then
        log "Restarting Grafana..."
        systemctl restart grafana-server ||
            error "Grafana restart failed"
    else
        systemctl start grafana-server ||
            error "Grafana start failed"
    fi
}

# Returns success only when all services and endpoints respond.
check_health() {
    log "Checking service health..."

    local service

    for service in \
        prometheus \
        prometheus-node-exporter \
        prometheus-process-exporter \
        grafana-server; do

        systemctl is-active --quiet "$service" ||
            error "$service is not active"

        log "$service is active"
    done

    log "Waiting for Grafana API..."

    local response
    local attempt

    for (( attempt=1; attempt<=60; attempt++ )); do
        response="$(
            wget -qO- --timeout=2 \
                http://127.0.0.1:3100/api/health \
                2>/dev/null
        )" || response=""

        if [[ "$response" == *'"database":"ok"'* ]]; then
            log "Grafana health check passed"
            break
        fi

        if (( attempt == 60 )); then
            error "Grafana health check failed"
        fi

        sleep 1
    done

    log "Checking Prometheus API..."

    response="$(
        wget -qO- --timeout=5 \
            http://127.0.0.1:9090/-/ready \
            2>/dev/null
    )" || error "Prometheus readiness check failed"

    log "Prometheus readiness check passed"

    log "Checking exporter endpoints..."

    wget -qO /dev/null --timeout=5 \
        http://127.0.0.1:9100/metrics ||
        error "Node Exporter metrics unavailable"

    wget -qO /dev/null --timeout=5 \
        http://127.0.0.1:9256/metrics ||
        error "Process Exporter metrics unavailable"

    log "Exporter endpoints passed"
    log "All health checks passed"
}

main() {
    parse_args "$@"

    log "Starting Pi Monitoring Installer"

    check_root
    check_environment

    setup_grafana_repository
    install_packages

    prepare_configs
    build_config_list
    check_all_conflicts
    apply_all_configs

    start_monitoring_services
    start_grafana
    check_health

    log "Pi Monitoring installation completed"
    log "Grafana: http://127.0.0.1:3100"
    log "Prometheus: http://127.0.0.1:9090"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
