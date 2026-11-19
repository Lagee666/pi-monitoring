#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/pi-monitoring/config-state"

ADOPT_CONFIG=false
DRY_RUN=false
WORK_DIR=""

PROMETHEUS_CHANGED=0
PROCESS_CHANGED=0
GRAFANA_CHANGED=0
GRAFANA_UNIT_CHANGED=0

PLAN_CONFLICTS=0
PLAN_DEFERRED=0

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

# Existing configuration ownership module.
source "$SCRIPT_DIR/lib/config.sh"

parse_args() {
    local arg

    for arg in "$@"; do
        case "$arg" in
            --adopt)
                ADOPT_CONFIG=true
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            -h|--help)
                cat <<'HELP'
Usage: sudo bash ./install.sh [OPTIONS]

Options:
  --dry-run  Preview changes without modifying the system.
  --adopt    Back up and adopt existing unmanaged configs.
             Never overwrite manually modified managed configs.
  --help     Show this help.

Examples:
  sudo bash ./install.sh --dry-run
  sudo bash ./install.sh --dry-run --adopt
  sudo bash ./install.sh
  sudo bash ./install.sh --adopt
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

check_sources() {
    local files=(
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

    for file in "${files[@]}"; do
        [[ -f "$SCRIPT_DIR/$file" ]] ||
            error "Missing repository file: $file"
    done
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

    check_sources

    log "Environment check passed"
}

# ------------------------------------------------------------
# Grafana APT Repository
# ------------------------------------------------------------

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

    install -d -m 755 /etc/apt/keyrings ||
        error "Cannot create APT keyring directory"

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

# ------------------------------------------------------------
# Package Installation
# ------------------------------------------------------------

required_packages=(
    prometheus
    prometheus-node-exporter
    prometheus-process-exporter
    grafana
    python3
    wget
)

package_installed() {
    local pkg="$1"

    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null |
        grep -qx 'install ok installed'
}

install_packages() {
    log "Checking required packages..."

    local missing=()
    local pkg

    for pkg in "${required_packages[@]}"; do
        if package_installed "$pkg"; then
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

# ------------------------------------------------------------
# Service Argument Generation
# ------------------------------------------------------------

render_service_args() {
    local target="$1"
    local desired_args="$2"

    [[ ! -L "$target" ]] ||
        error "Refusing symlink: $target"

    [[ -f "$target" ]] ||
        error "Missing service defaults: $target"

    local count
    count="$(grep -c '^ARGS=' "$target" || true)"

    [[ "$count" == 1 ]] ||
        error "Expected exactly one ARGS entry: $target"

    awk -v args="$desired_args" '
        /^ARGS=/ {
            print "ARGS=\"" args "\""
            next
        }
        { print }
    ' "$target"
}

prepare_service_args() {
    local target="$1"
    local desired_args="$2"
    local output="$3"

    render_service_args "$target" "$desired_args" > "$output" ||
        error "Cannot prepare $target"
}

# ------------------------------------------------------------
# Read-only Configuration Preflight
# ------------------------------------------------------------

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

apply_config() {
    local source="$1"
    local target="$2"

    if install_config "$source" "$target"; then
        return 0
    fi

    return 1
}

# ------------------------------------------------------------
# Dry Run: Read-only Planning
# ------------------------------------------------------------

plan_message() {
    local status="$1"
    local target="$2"

    printf '[PLAN] %-10s %s\n' "$status" "$target"
}

plan_conflict() {
    plan_message "CONFLICT" "$1"
    PLAN_CONFLICTS=$((PLAN_CONFLICTS + 1))
}

plan_config_hash() {
    local desired_hash="$1"
    local target="$2"

    local key state_file
    local current_hash expected_hash

    [[ ! -L "$target" ]] || {
        plan_conflict "$target (symlink)"
        return 0
    }

    key="$(printf '%s' "$target" |
        sha256sum | cut -d' ' -f1)"

    state_file="$STATE_DIR/$key.sha256"

    if [[ ! -e "$target" ]]; then
        if [[ -f "$state_file" ]]; then
            plan_conflict "$target (managed file missing)"
        else
            plan_message "CREATE" "$target"
        fi

        return 0
    fi

    if [[ ! -f "$target" || ! -r "$target" ]]; then
        plan_conflict "$target (not a readable regular file)"
        return 0
    fi

    current_hash="$(sha256sum "$target" | cut -d' ' -f1)"

    if [[ -f "$state_file" ]]; then
        expected_hash="$(cat "$state_file")"

        if [[ "$current_hash" != "$expected_hash" ]]; then
            plan_conflict "$target (managed file modified)"
            return 0
        fi

        if [[ "$current_hash" == "$desired_hash" ]]; then
            plan_message "UNCHANGED" "$target"
        else
            plan_message "UPDATE" "$target"
        fi

        return 0
    fi

    if [[ "$current_hash" == "$desired_hash" ]]; then
        plan_message "UNCHANGED" "$target (will record ownership)"
        return 0
    fi

    if [[ "$ADOPT_CONFIG" == true ]]; then
        plan_message "ADOPT" "$target (backup and replace)"
    else
        plan_conflict "$target (unmanaged; requires --adopt)"
    fi
}

plan_config_file() {
    local source="$1"
    local target="$2"
    local hash

    if [[ ! -f "$source" || ! -r "$source" ]]; then
        plan_conflict "$target (source missing or unreadable)"
        return 0
    fi

    hash="$(sha256sum "$source" | cut -d' ' -f1)"

    plan_config_hash "$hash" "$target"
}

plan_service_args() {
    local target="$1"
    local desired_args="$2"
    local hash

    # A fresh installation may not have Debian defaults yet.
    if [[ ! -e "$target" ]]; then
        plan_message "DEFERRED" "$target (requires package installation)"
        PLAN_DEFERRED=$((PLAN_DEFERRED + 1))
        return 0
    fi

    if [[ ! -f "$target" || ! -r "$target" || -L "$target" ]]; then
        plan_conflict "$target (invalid defaults file)"
        return 0
    fi

    local count
    count="$(grep -c '^ARGS=' "$target" || true)"

    if [[ "$count" != 1 ]]; then
        plan_conflict "$target (expected exactly one ARGS entry)"
        return 0
    fi

    hash="$(
        render_service_args "$target" "$desired_args" |
            sha256sum | cut -d' ' -f1
    )"

    plan_config_hash "$hash" "$target"
}

plan_repository() {
    local list=/etc/apt/sources.list.d/grafana.list
    local key=/etc/apt/keyrings/grafana.asc
    local expected

    expected='deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main'

    if [[ ! -e "$list" && ! -e "$key" ]]; then
        plan_message "CREATE" "Grafana APT repository"
        return 0
    fi

    if [[ -f "$list" && -s "$key" ]] &&
       grep -Fxq "$expected" "$list"; then
        plan_message "UNCHANGED" "Grafana APT repository"
    else
        plan_conflict "Grafana APT repository (incomplete or different)"
    fi
}

plan_packages() {
    local pkg

    for pkg in "${required_packages[@]}"; do
        if package_installed "$pkg"; then
            plan_message "UNCHANGED" "package: $pkg"
        else
            plan_message "INSTALL" "package: $pkg"
        fi
    done
}

dry_run() {
    log "Pi Monitoring Dry Run"
    log "Read-only mode: no changes will be applied"

    check_sources

    echo
    log "Repository and packages"

    plan_repository
    plan_packages

    echo
    log "Prometheus configuration"

    plan_config_file \
        "$SCRIPT_DIR/config/prometheus.yml" \
        /etc/prometheus/prometheus.yml

    plan_config_file \
        "$SCRIPT_DIR/config/process-exporter.yml" \
        /etc/prometheus/process-exporter.yml

    plan_service_args \
        /etc/default/prometheus \
        '--storage.tsdb.retention.time=14d --storage.tsdb.retention.size=2GB'

    plan_service_args \
        /etc/default/prometheus-process-exporter \
        '-config.path=/etc/prometheus/process-exporter.yml'

    echo
    log "Grafana configuration"

    plan_config_file \
        "$SCRIPT_DIR/grafana/grafana.env" \
        /etc/pi-monitoring/grafana.env

    plan_config_file \
        "$SCRIPT_DIR/grafana/systemd/override.conf" \
        /etc/systemd/system/grafana-server.service.d/override.conf

    plan_config_file \
        "$SCRIPT_DIR/grafana/provisioning/datasources/prometheus.yml" \
        /etc/grafana/provisioning/datasources/prometheus.yml

    plan_config_file \
        "$SCRIPT_DIR/grafana/provisioning/dashboards/pi-monitoring.yml" \
        /etc/grafana/provisioning/dashboards/pi-monitoring.yml

    plan_config_file \
        "$SCRIPT_DIR/grafana/dashboards/system-overview.json" \
        /etc/grafana/dashboards/system-overview.json

    plan_config_file \
        "$SCRIPT_DIR/grafana/dashboards/process-overview.json" \
        /etc/grafana/dashboards/process-overview.json

    echo
    log "Dry run completed"
    log "Conflicts: $PLAN_CONFLICTS"
    log "Deferred checks: $PLAN_DEFERRED"
    log "No changes applied"

    if (( PLAN_CONFLICTS > 0 )); then
        return 2
    fi

    return 0
}

# ------------------------------------------------------------
# Actual Deployment
# ------------------------------------------------------------

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
}

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
    log "Checking all configuration conflicts..."

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
        systemctl restart prometheus ||
            error "Prometheus restart failed"
    else
        systemctl start prometheus ||
            error "Prometheus start failed"
    fi

    if (( PROCESS_CHANGED )); then
        systemctl restart prometheus-process-exporter ||
            error "Process Exporter restart failed"
    else
        systemctl start prometheus-process-exporter ||
            error "Process Exporter start failed"
    fi
}

start_grafana() {
    log "Starting Grafana..."

    if (( GRAFANA_UNIT_CHANGED )); then
        systemctl daemon-reload ||
            error "systemd daemon-reload failed"
    fi

    systemctl enable grafana-server ||
        error "Cannot enable Grafana"

    if (( GRAFANA_CHANGED )); then
        systemctl restart grafana-server ||
            error "Grafana restart failed"
    else
        systemctl start grafana-server ||
            error "Grafana start failed"
    fi
}

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
    local healthy=false

    for (( attempt=1; attempt<=60; attempt++ )); do
        response="$(
            wget -qO- --timeout=2 \
                http://127.0.0.1:3100/api/health \
                2>/dev/null
        )" || response=""

        if [[ "$response" == *'"database":"ok"'* ]]; then
            healthy=true
            break
        fi

	if python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
    sys.exit(0 if data.get("database") == "ok" else 1)
except (ValueError, TypeError):
    sys.exit(1)
            ' <<< "$response"; then
            healthy=true
            break
	fi

        sleep 1
    done

    [[ "$healthy" == true ]] ||
        error "Grafana health check failed"

    log "Grafana health check passed"

    wget -qO /dev/null --timeout=5 \
        http://127.0.0.1:9090/-/ready ||
        error "Prometheus readiness check failed"

    wget -qO /dev/null --timeout=5 \
        http://127.0.0.1:9100/metrics ||
        error "Node Exporter metrics unavailable"

    wget -qO /dev/null --timeout=5 \
        http://127.0.0.1:9256/metrics ||
        error "Process Exporter metrics unavailable"

    log "All health checks passed"
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main() {
    parse_args "$@"

    # Dry run must exit before package installation
    # and before any state or config writes.
    if [[ "$DRY_RUN" == true ]]; then
        dry_run
        return $?
    fi

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

