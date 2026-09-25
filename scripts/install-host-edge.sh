#!/usr/bin/env bash
set -Eeuo pipefail

umask 022

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
NGINX_RULES_DIR=/etc/nginx/finntrail-rules
STATE_DIR=/var/lib/finntrail-edge
LOG_DIR=/var/log/finntrail-edge
OLD_NFT_TABLE=${EDGE_NFT_TABLE:-finntrail_edge}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "run this installer as root"
fi

for dependency in flock grep install python3 systemctl ufw; do
    command -v "$dependency" >/dev/null 2>&1 || \
        die "required command is missing: $dependency"
done

NGINX_BIN=${EDGE_NGINX_BIN:-$(command -v nginx || true)}
[[ -n $NGINX_BIN && -x $NGINX_BIN ]] || die "nginx executable was not found"

if ! LC_ALL=C ufw status | grep -Fxq 'Status: active'; then
    die "UFW is not active; enable it and verify SSH, HTTP and HTTPS rules first"
fi

install -d -o root -g root -m 0750 "$STATE_DIR" "$LOG_DIR"
install -d -o root -g root -m 0755 "$NGINX_RULES_DIR"

for registry in redirects.tsv blocked-ips.tsv; do
    if [[ ! -e $STATE_DIR/$registry ]]; then
        install -o root -g root -m 0640 /dev/null "$STATE_DIR/$registry"
    fi
done

if [[ ! -e $LOG_DIR/actions.log ]]; then
    install -o root -g root -m 0640 /dev/null "$LOG_DIR/actions.log"
fi

install -o root -g root -m 0755 \
    "$ROOT_DIR/scripts/edge-redirect.sh" \
    /usr/local/sbin/edge-redirect
install -o root -g root -m 0755 \
    "$ROOT_DIR/scripts/edge-ip.sh" \
    /usr/local/sbin/edge-ip

install -o root -g root -m 0644 \
    "$ROOT_DIR/deploy/host-edge/nginx/00-finntrail-edge-maps.conf" \
    /etc/nginx/conf.d/00-finntrail-edge-maps.conf
install -o root -g root -m 0644 \
    "$ROOT_DIR/deploy/host-edge/nginx/redirect-server.conf" \
    "$NGINX_RULES_DIR/redirect-server.conf"

install -o root -g root -m 0644 \
    "$ROOT_DIR/deploy/host-edge/systemd/finntrail-edge-ip-expire.service" \
    /etc/systemd/system/finntrail-edge-ip-expire.service
install -o root -g root -m 0644 \
    "$ROOT_DIR/deploy/host-edge/systemd/finntrail-edge-ip-expire.timer" \
    /etc/systemd/system/finntrail-edge-ip-expire.timer

if systemctl list-unit-files finntrail-edge-nftables.service \
    --no-legend 2>/dev/null | grep -q '^finntrail-edge-nftables.service'; then
    systemctl disable --now finntrail-edge-nftables.service >/dev/null 2>&1 || true
fi
rm -f /etc/systemd/system/finntrail-edge-nftables.service

systemctl daemon-reload

# Restore the registry in UFW before deleting the old native nftables table.
/usr/local/sbin/edge-ip restore

if command -v nft >/dev/null 2>&1 && \
    nft list table inet "$OLD_NFT_TABLE" >/dev/null 2>&1; then
    nft delete table inet "$OLD_NFT_TABLE"
fi

systemctl enable --now finntrail-edge-ip-expire.timer >/dev/null

/usr/local/sbin/edge-redirect apply

nginx_configuration=$($NGINX_BIN -T 2>&1)
grep -Fq '/etc/nginx/conf.d/00-finntrail-edge-maps.conf' \
    <<< "$nginx_configuration" || \
    die "Nginx does not load /etc/nginx/conf.d/00-finntrail-edge-maps.conf"

echo
echo "Installed commands:"
echo "  /usr/local/sbin/edge-redirect"
echo "  /usr/local/sbin/edge-ip"
echo

if grep -Fq "$NGINX_RULES_DIR/redirect-server.conf" \
    <<< "$nginx_configuration"; then
    echo "Redirect fragment is active in Nginx."
else
    cat <<EOF
Add this line inside both production server blocks for finntrail.ru:

    include $NGINX_RULES_DIR/redirect-server.conf;

Then run:

    nginx -t
    systemctl reload nginx
EOF
fi
