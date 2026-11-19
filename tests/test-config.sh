#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export STATE_DIR="$TEST_DIR/state"
export ADOPT_CONFIG=false

log() {
    :
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

source "$ROOT/lib/config.sh"

passed=0
failed=0

assert_success() {
    local name="$1"
    shift

    if "$@"; then
        echo "[PASS] $name"
        ((passed+=1))
    else
        echo "[FAIL] $name"
        ((failed+=1))
    fi
}

assert_failure() {
    local name="$1"
    shift

    if "$@"; then
        echo "[FAIL] $name"
        ((failed+=1))
    else
        echo "[PASS] $name"
        ((passed+=1))
    fi
}

reset_test() {
    rm -rf "$TEST_DIR/state" "$TEST_DIR/output"
    mkdir -p "$TEST_DIR/output"

    printf 'version=1\n' > "$TEST_DIR/source"

    ADOPT_CONFIG=false
}

target="$TEST_DIR/output/config.yml"
source_file="$TEST_DIR/source"

# 1. First installation
reset_test
assert_success "First installation" \
    install_config "$source_file" "$target"

# 2. Idempotency: unchanged configuration returns 1
assert_failure "Repeated installation is unchanged" \
    install_config "$source_file" "$target"

# 3. Identical unmanaged configuration becomes managed
reset_test
cp "$source_file" "$target"

assert_failure "Adopt identical configuration" \
    install_config "$source_file" "$target"

assert_success "Ownership state created" \
    test "$(find "$STATE_DIR" -name '*.sha256' | wc -l)" -eq 1

# 4. Reject unmanaged configuration differences
reset_test
printf 'custom=true\n' > "$target"

assert_failure "Reject unmanaged configuration" \
    bash -c '
        set -Eeuo pipefail
        source "$1"
        log() { :; }
        error() { exit 1; }
        install_config "$2" "$3"
    ' _ "$ROOT/lib/config.sh" "$source_file" "$target"

# 5. Explicit adoption
reset_test
printf 'custom=true\n' > "$target"
ADOPT_CONFIG=true

assert_success "Explicit adoption" \
    install_config "$source_file" "$target"

assert_success "Backup exists" \
    test "$(find "$TEST_DIR/output" -name 'config.yml.bak.*' | wc -l)" -eq 1

# 6. Reject modification of managed configuration
printf 'modified=true\n' > "$target"

assert_failure "Reject manually modified managed configuration" \
    bash -c '
        set -Eeuo pipefail
        source "$1"
        log() { :; }
        error() { exit 1; }
        install_config "$2" "$3"
    ' _ "$ROOT/lib/config.sh" "$source_file" "$target"

# 7. Upgrade managed configuration
reset_test
assert_success "Install initial managed configuration" \
    install_config "$source_file" "$target"

printf 'version=2\n' > "$source_file"

assert_success "Upgrade managed configuration" \
    install_config "$source_file" "$target"

assert_success "Updated content" \
    grep -qx 'version=2' "$target"

echo
echo "Passed: $passed"
echo "Failed: $failed"

(( failed == 0 ))
