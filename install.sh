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

# Return 0 when content was installed/updated; return 1 when content is unchanged.
# A conflict terminates the script. Must be called within an `if` condition.
install_config() {
    local source="$1"
    local target="$2"
    local key state_file current_hash expected_hash new_hash
    local backup temp_target temp_state

    [[ -f "$source" ]] || error "Missing source: $source"
    [[ ! -L "$target" ]] || error "Refusing to manage symlink: $target"

    key="$(printf '%s' "$target" | sha256sum | cut -d' ' -f1)"
    state_file="$STATE_DIR/$key.sha256"
    install -d -m 700 "$STATE_DIR" || error "Cannot create state directory"
    new_hash="$(sha256sum "$source" | cut -d' ' -f1)"

    if [[ -e "$target" ]]; then
        [[ -f "$target" ]] || error "Target is not a regular file: $target"
        current_hash="$(sha256sum "$target" | cut -d' ' -f1)"

        if [[ -f "$state_file" ]]; then
            expected_hash="$(cat "$state_file")"
            [[ "$current_hash" == "$expected_hash" ]] ||
                error "Managed configuration was edited: $target (refusing to overwrite)"
        elif [[ "$current_hash" == "$new_hash" ]]; then
            # An identical pre-existing config is safe to claim without touching it.
            printf '%s\n' "$current_hash" > "$state_file" || error "Cannot record config ownership"
            log "Adopted identical configuration: $target"
            return 1
        elif [[ "$ADOPT_CONFIG" != true ]]; then
            error "Unmanaged configuration differs: $target (rerun with --adopt to back it up and take ownership)"
        fi

        if [[ "$current_hash" == "$new_hash" ]]; then
            log "Unchanged: $target"
            return 1
        fi

        # mktemp creates a unique backup name; cp -a preserves the original metadata.
        backup="$(mktemp "${target}.bak.XXXXXXXX")" || error "Cannot allocate backup for $target"
        cp -a "$target" "$backup" || error "Cannot back up $target"
        log "Backup created: $backup"
    elif [[ -f "$state_file" ]]; then
        error "Previously managed configuration is missing: $target"
    fi

    # Write in the same directory and rename to avoid partially written config files.
    install -d -m 755 "$(dirname "$target")" || error "Cannot create directory for $target"
    temp_target="$(mktemp "${target}.new.XXXXXXXX")" || error "Cannot allocate temporary config"
    install -m 644 "$source" "$temp_target" || error "Cannot stage $target"
    mv -f "$temp_target" "$target" || error "Cannot install $target"

    temp_state="$(mktemp "$STATE_DIR/.state.XXXXXXXX")" || error "Cannot allocate state file"
    printf '%s\n' "$new_hash" > "$temp_state" || error "Cannot write state file"
    mv -f "$temp_state" "$state_file" || error "Cannot record config ownership"

    log "Installed: $target"
    return 0
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

main() {
    parse_args "$@"
    log "Starting Pi Monitoring Installer"
    check_root
    check_environment
    setup_grafana_repository
    install_packages
    configure_exporters
    log "Configuration stage completed"
    log "NOTE: Startup arguments, Grafana provisioning and health checks are not yet automated."
}

main "$@"

