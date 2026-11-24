#!/bin/sh
set -eu

CONFIG=${TPROXY_CONFIG:-/etc/tproxy-server/config.json}
PROFILES=${TPROXY_PROFILES:-/etc/tproxy-server/profiles.json}
SERVER=/usr/local/bin/tproxy-server
child=
stopping=0

stop_child() {
    if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
    child=
}

shutdown() {
    stopping=1
    stop_child
    exit 0
}
trap shutdown TERM INT

last_hash=
rejected_hash=
while [ "$stopping" -eq 0 ]; do
    if ! "$SERVER" -config "$CONFIG" -profiles-file "$PROFILES" -check; then
        echo "relay-supervisor: configuration validation failed; retrying in 5s" >&2
        sleep 5
        continue
    fi

    current_hash=$(sha256sum "$PROFILES" | awk '{print $1}')
    last_hash=$current_hash
    rejected_hash=

    "$SERVER" -config "$CONFIG" -profiles-file "$PROFILES" &
    child=$!
    restart=0

    while kill -0 "$child" 2>/dev/null; do
        sleep 2
        new_hash=$(sha256sum "$PROFILES" | awk '{print $1}')
        if [ "$new_hash" = "$last_hash" ] || [ "$new_hash" = "$rejected_hash" ]; then
            continue
        fi
        if "$SERVER" -config "$CONFIG" -profiles-file "$PROFILES" -check; then
            echo "relay-supervisor: valid profile update detected; restarting relay"
            stop_child
            restart=1
            break
        fi
        echo "relay-supervisor: rejected invalid profile update; keeping current relay" >&2
        rejected_hash=$new_hash
    done

    if [ "$restart" -eq 1 ]; then
        continue
    fi
    wait "$child" || true
    child=
    [ "$stopping" -eq 1 ] || sleep 2
done
