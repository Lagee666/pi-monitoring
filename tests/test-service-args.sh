#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

source "$ROOT/install.sh"

STATE_DIR="$TEST_DIR/state"
ADOPT_CONFIG=false

target="$TEST_DIR/prometheus-defaults"
staged="$TEST_DIR/staged"
desired='--storage.tsdb.retention.time=14d --storage.tsdb.retention.size=2GB'

passed=0
failed=0

pass() {
    printf '[PASS] %s\n' "$1"
    ((passed+=1))
}

fail() {
    printf '[FAIL] %s\n' "$1"
    ((failed+=1))
}

assert_success() {
    local name="$1"
    shift

    if "$@"; then
        pass "$name"
    else
        fail "$name"
    fi
}

assert_failure() {
    local name="$1"
    shift

    if "$@"; then
        fail "$name"
    else
        pass "$name"
    fi
}

cat > "$target" <<'CONFIG'
# Existing Debian comments
ARGS="--old-flag"
CONFIG

assert_success "Prepare service arguments" \
    prepare_service_args "$target" "$desired" "$staged"

assert_success "Preserve existing comments" \
    grep -qx '# Existing Debian comments' "$staged"

assert_success "Replace ARGS" \
    grep -Fqx "ARGS=\"$desired\"" "$staged"

# Run conflict cases in a subshell so error() cannot stop the whole test.
assert_failure "Reject unmanaged conflict" \
    bash -c '
        set -Eeuo pipefail
        source "$1"
        STATE_DIR="$2"
        ADOPT_CONFIG=false
        preflight_config "$3" "$4"
    ' _ "$ROOT/install.sh" "$STATE_DIR" "$staged" "$target"

ADOPT_CONFIG=true

assert_success "Allow explicit adoption" \
    preflight_config "$staged" "$target"

assert_success "Apply configuration" \
    install_config "$staged" "$target"

ADOPT_CONFIG=false

assert_success "Repeated preflight" \
    preflight_config "$staged" "$target"

printf 'ARGS="--manually-modified"\n' > "$target"

assert_failure "Reject modified managed config" \
    bash -c '
        set -Eeuo pipefail
        source "$1"
        STATE_DIR="$2"
        ADOPT_CONFIG=false
        preflight_config "$3" "$4"
    ' _ "$ROOT/install.sh" "$STATE_DIR" "$staged" "$target"

echo
echo "Passed: $passed"
echo "Failed: $failed"

(( failed == 0 ))
