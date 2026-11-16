#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../tgweb-install.sh
source "$ROOT_DIR/tgweb-install.sh"

assert_valid() {
  local validator="$1" value="$2"
  if ! "$validator" "$value" >/dev/null 2>&1; then
    printf 'Expected %s to accept: %s\n' "$validator" "$value" >&2
    exit 1
  fi
}

assert_invalid() {
  local validator="$1" value="$2"
  if "$validator" "$value" >/dev/null 2>&1; then
    printf 'Expected %s to reject: %s\n' "$validator" "$value" >&2
    exit 1
  fi
}

assert_valid validate_secret '0123456789abcdef0123456789abcdef'
assert_valid validate_secret 'dd0123456789abcdef0123456789abcdef'
assert_invalid validate_secret '0123456789ABCDEF0123456789ABCDEF'
assert_invalid validate_secret '0123456789abcdef'

assert_valid validate_port '1024'
assert_valid validate_port '65535'
assert_invalid validate_port '443'
assert_invalid validate_port '65536'
assert_invalid validate_port 'not-a-port'

assert_valid validate_base_path 'proxy'
assert_valid validate_base_path 'telegram/web-proxy_2'
assert_invalid validate_base_path '../etc/passwd'
assert_invalid validate_base_path '/leading-slash'

assert_valid validate_hostname 'proxy.example.com'
assert_invalid validate_hostname 'https://proxy.example.com'
assert_invalid validate_hostname 'localhost'

# The shared update flow already supports secret rotation; verify both keeping
# the current value and generating a replacement with the existing prefix.
SECRET_ARG='0123456789abcdef0123456789abcdef'
SECRET_PREFIX_MODE='plain'
printf '\n' | prompt_update_secret
[[ "$SECRET_ARG" == '0123456789abcdef0123456789abcdef' ]]

SECRET_PREFIX_MODE='dd'
printf 'n\n\n' | prompt_update_secret
assert_valid validate_secret "$SECRET_ARG"
[[ "$SECRET_ARG" == dd* ]]

SECRET_ARG='0123456789abcdef0123456789abcdef'
printf 'n\n11111111111111111111111111111111\n11111111111111111111111111111111\n' | prompt_update_secret
[[ "$SECRET_ARG" == '11111111111111111111111111111111' ]]

redacted="$(printf '%s\n' 'secret=0123456789abcdef token:abcdef authorization: Bearer supersecret https://proxy.example.com/private/path?hash=abcdef' | redact_sensitive_log)"
for sensitive in '0123456789abcdef' 'abcdef' 'supersecret' '/private/path'; do
  if [[ "$redacted" == *"$sensitive"* ]]; then
    printf 'Sensitive value was not redacted: %s\nOutput: %s\n' "$sensitive" "$redacted" >&2
    exit 1
  fi
done
[[ "$redacted" == *'[REDACTED]'* ]]
[[ "$redacted" == *'[REDACTED_PATH]'* ]]

printf 'All installer unit checks passed.\n'
