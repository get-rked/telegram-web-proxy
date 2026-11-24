#!/bin/sh
set -eu

nft delete table inet mtproxy_guard 2>/dev/null || true
nft -f - <<'NFT'
table inet mtproxy_guard {
    chain input {
        type filter hook input priority -100; policy accept;
        iifname != "lo" tcp dport { 2398, 8888 } drop
    }
}
NFT

exec sleep infinity
