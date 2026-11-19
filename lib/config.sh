#!/usr/bin/env bash

# Requires:
#   log()
#   error()
#   STATE_DIR
#   ADOPT_CONFIG

install_config() {
    local source="$1"
    local target="$2"
    local key state_file
    local current_hash expected_hash new_hash
    local backup temp_target temp_state

    [[ -f "$source" ]] ||
        error "Missing source: $source"

    [[ ! -L "$target" ]] ||
        error "Refusing to manage symlink: $target"

    key="$(printf '%s' "$target" | sha256sum | cut -d' ' -f1)"
    state_file="$STATE_DIR/$key.sha256"

    install -d -m 700 "$STATE_DIR"
    new_hash="$(sha256sum "$source" | cut -d' ' -f1)"

    if [[ -e "$target" ]]; then
        [[ -f "$target" ]] ||
            error "Target is not a regular file: $target"

        current_hash="$(sha256sum "$target" | cut -d' ' -f1)"

        if [[ -f "$state_file" ]]; then
            expected_hash="$(cat "$state_file")"

            [[ "$current_hash" == "$expected_hash" ]] ||
                error "Managed configuration was modified: $target"

        elif [[ "$current_hash" == "$new_hash" ]]; then
            printf '%s\n' "$current_hash" > "$state_file"
            log "Adopted identical configuration: $target"
            return 1

        elif [[ "$ADOPT_CONFIG" != true ]]; then
            error "Unmanaged configuration differs: $target"
        fi

        if [[ "$current_hash" == "$new_hash" ]]; then
            log "Unchanged: $target"
            return 1
        fi

        backup="$(mktemp "${target}.bak.XXXXXXXX")"
        cp -a "$target" "$backup"
        log "Backup created: $backup"

    elif [[ -f "$state_file" ]]; then
        error "Previously managed configuration is missing: $target"
    fi

    install -d -m 755 "$(dirname "$target")"

    temp_target="$(mktemp "${target}.new.XXXXXXXX")"
    install -m 644 "$source" "$temp_target"
    mv -f "$temp_target" "$target"

    temp_state="$(mktemp "$STATE_DIR/.state.XXXXXXXX")"
    printf '%s\n' "$new_hash" > "$temp_state"
    mv -f "$temp_state" "$state_file"

    log "Installed: $target"
    return 0
}
