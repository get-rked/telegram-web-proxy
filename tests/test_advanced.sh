#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../tproxy-advanced.sh
source "$ROOT_DIR/tproxy-advanced.sh"

assert_true() {
  if ! "$@"; then
    printf 'Expected true: %s\n' "$*" >&2
    exit 1
  fi
}
assert_false() {
  if "$@"; then
    printf 'Expected false: %s\n' "$*" >&2
    exit 1
  fi
}

assert_true valid_secret '0123456789abcdef0123456789abcdef'
assert_true valid_secret 'dd0123456789abcdef0123456789abcdef'
assert_false valid_secret '0123456789ABCDEF0123456789ABCDEF'
assert_false valid_secret '0123456789abcdef'
assert_true valid_name 'profile-2'
assert_true valid_name 'default'
assert_false valid_name '../bad'
assert_false valid_name '-bad'
assert_true valid_mode https
assert_true valid_mode https-lanes
assert_true valid_mode websocket
assert_true valid_mode websocket-lanes
assert_false valid_mode split

printf 'All advanced manager unit checks passed.\n'
