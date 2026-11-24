#!/bin/sh
set -eu

DATA_DIR=${MTPROXY_DATA_DIR:-/var/lib/mtproxy}
SECRET_FILE=${MTPROXY_SECRET_FILE:-/run/secrets/mtproxy_secret}
SECRET=
if [ -r "$SECRET_FILE" ]; then
    SECRET=$(tr -d '\r\n ' < "$SECRET_FILE")
else
    echo "ERROR: MTProxy secret file is missing or unreadable: $SECRET_FILE" >&2
    exit 1
fi

case "$SECRET" in
    ''|*[!0-9a-fA-F]*)
        echo "ERROR: MTProxy secret must be hexadecimal." >&2
        exit 1
        ;;
esac
if [ "${#SECRET}" -ne 32 ]; then
    echo "ERROR: MTProxy secret must contain exactly 32 hex characters." >&2
    exit 1
fi

mkdir -p "$DATA_DIR"
if [ ! -s "$DATA_DIR/proxy-secret" ]; then
    echo "Downloading official Telegram MTProxy upstream secret..."
    curl --fail --silent --show-error --location --retry 3 \
        https://core.telegram.org/getProxySecret -o "$DATA_DIR/proxy-secret.tmp"
    test -s "$DATA_DIR/proxy-secret.tmp"
    mv "$DATA_DIR/proxy-secret.tmp" "$DATA_DIR/proxy-secret"
fi
if [ ! -s "$DATA_DIR/proxy-multi.conf" ]; then
    echo "Downloading official Telegram MTProxy routing configuration..."
    curl --fail --silent --show-error --location --retry 3 \
        https://core.telegram.org/getProxyConfig -o "$DATA_DIR/proxy-multi.conf.tmp"
    test -s "$DATA_DIR/proxy-multi.conf.tmp"
    mv "$DATA_DIR/proxy-multi.conf.tmp" "$DATA_DIR/proxy-multi.conf"
fi

exec /usr/local/bin/mtproto-proxy \
    -u nobody \
    -p 8888 \
    -H 2398 \
    -S "$SECRET" \
    --aes-pwd "$DATA_DIR/proxy-secret" "$DATA_DIR/proxy-multi.conf" \
    -M "${MTPROXY_WORKERS:-1}"
