#!/bin/sh
set -eu

DATA_DIR=${MTPROXY_DATA_DIR:-/var/lib/mtproxy}
SECRET_FILE=${MTPROXY_SECRET_FILE:-/run/secrets/mtproxy_secret}
REFRESH_INTERVAL=${MTPROXY_REFRESH_INTERVAL:-86400}
SECRET=
child=

if [ -r "$SECRET_FILE" ]; then
    SECRET=$(tr -d '\r\n ' < "$SECRET_FILE")
else
    echo "ERROR: MTProxy secret file is missing or unreadable." >&2
    exit 1
fi
case "$SECRET" in
    ''|*[!0-9a-fA-F]*) echo "ERROR: MTProxy secret must be hexadecimal." >&2; exit 1 ;;
esac
if [ "${#SECRET}" -ne 32 ]; then
    echo "ERROR: MTProxy secret must contain exactly 32 hex characters." >&2
    exit 1
fi
case "$REFRESH_INTERVAL" in
    ''|*[!0-9]*) echo "ERROR: MTPROXY_REFRESH_INTERVAL must be seconds." >&2; exit 1 ;;
esac
if [ "$REFRESH_INTERVAL" -lt 60 ]; then
    echo "ERROR: MTPROXY_REFRESH_INTERVAL must be at least 60 seconds." >&2
    exit 1
fi

mkdir -p "$DATA_DIR"
if [ ! -s "$DATA_DIR/proxy-secret" ]; then
    curl --fail --silent --show-error --location --retry 3 \
        https://core.telegram.org/getProxySecret -o "$DATA_DIR/proxy-secret.tmp"
    test -s "$DATA_DIR/proxy-secret.tmp"
    chmod 0600 "$DATA_DIR/proxy-secret.tmp"
    mv "$DATA_DIR/proxy-secret.tmp" "$DATA_DIR/proxy-secret"
fi
if [ ! -s "$DATA_DIR/proxy-multi.conf" ]; then
    curl --fail --silent --show-error --location --retry 3 \
        https://core.telegram.org/getProxyConfig -o "$DATA_DIR/proxy-multi.conf.tmp"
    test -s "$DATA_DIR/proxy-multi.conf.tmp"
    chmod 0600 "$DATA_DIR/proxy-multi.conf.tmp"
    mv "$DATA_DIR/proxy-multi.conf.tmp" "$DATA_DIR/proxy-multi.conf"
fi

start_proxy() {
    /usr/local/bin/mtproto-proxy \
        -p 8888 \
        -H 2398 \
        -S "$SECRET" \
        --aes-pwd "$DATA_DIR/proxy-secret" "$DATA_DIR/proxy-multi.conf" \
        -M "${MTPROXY_WORKERS:-1}" &
    child=$!
    sleep 3
    if ! kill -0 "$child" 2>/dev/null; then
        wait "$child" || true
        child=
        return 1
    fi
    return 0
}

stop_proxy() {
    if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
    child=
}

shutdown() {
    stop_proxy
    exit 0
}
trap shutdown TERM INT

if ! start_proxy; then
    echo "ERROR: MTProxy failed to start." >&2
    exit 1
fi

next_refresh=$(($(date +%s) + REFRESH_INTERVAL))
while kill -0 "$child" 2>/dev/null; do
    sleep 30
    now=$(date +%s)
    if [ "$now" -lt "$next_refresh" ]; then
        continue
    fi

    if ! curl --fail --silent --show-error --location --retry 3 \
        https://core.telegram.org/getProxyConfig -o "$DATA_DIR/proxy-multi.conf.new"; then
        rm -f "$DATA_DIR/proxy-multi.conf.new"
        echo "mtproxy: routing config refresh failed; keeping current configuration" >&2
        next_refresh=$(($now + REFRESH_INTERVAL))
        continue
    fi

    size=$(wc -c < "$DATA_DIR/proxy-multi.conf.new")
    if [ ! -s "$DATA_DIR/proxy-multi.conf.new" ] || [ "$size" -gt 4194304 ]; then
        rm -f "$DATA_DIR/proxy-multi.conf.new"
        echo "mtproxy: downloaded routing config is empty or too large; keeping current configuration" >&2
        next_refresh=$(($now + REFRESH_INTERVAL))
        continue
    fi

    if cmp -s "$DATA_DIR/proxy-multi.conf" "$DATA_DIR/proxy-multi.conf.new"; then
        rm -f "$DATA_DIR/proxy-multi.conf.new"
        echo "mtproxy: routing config is already current"
        next_refresh=$(($now + REFRESH_INTERVAL))
        continue
    fi

    cp -p "$DATA_DIR/proxy-multi.conf" "$DATA_DIR/proxy-multi.conf.previous"
    chmod 0600 "$DATA_DIR/proxy-multi.conf.previous"
    chmod 0600 "$DATA_DIR/proxy-multi.conf.new"
    mv "$DATA_DIR/proxy-multi.conf.new" "$DATA_DIR/proxy-multi.conf"
    stop_proxy
    if start_proxy; then
        rm -f "$DATA_DIR/proxy-multi.conf.previous"
        echo "mtproxy: routing config updated successfully"
    else
        echo "mtproxy: updated config failed to start; restoring previous config" >&2
        mv "$DATA_DIR/proxy-multi.conf.previous" "$DATA_DIR/proxy-multi.conf"
        if ! start_proxy; then
            echo "ERROR: MTProxy could not recover with previous routing config." >&2
            exit 1
        fi
    fi
    next_refresh=$(($(date +%s) + REFRESH_INTERVAL))
done

wait "$child" || true
echo "ERROR: MTProxy process exited unexpectedly." >&2
exit 1
