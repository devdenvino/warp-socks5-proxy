#!/usr/bin/env bash
set -euo pipefail
WARP_INTERFACE="CloudflareWARP"
log() { echo "[warp-setup] $*"; }
log "Waiting for warp-svc..."
for i in $(seq 1 30); do warp-cli --accept-tos status &>/dev/null && break || sleep 2; done
log "Ensuring registration..."
if ! warp-cli --accept-tos status | grep -qi "Connected"; then
    # Use connector if token exists, else standard
    if [ -n "${WARP_CONNECTOR_TOKEN:-}" ]; then
        warp-cli --accept-tos connector new "$WARP_CONNECTOR_TOKEN" || true
    else
        warp-cli --accept-tos registration new || true
    fi
fi
log "Adding local exclusions..."
# WARP_EXCLUDE_RANGES: comma-separated list of CIDRs to exclude from the WARP tunnel
# e.g. WARP_EXCLUDE_RANGES="192.168.85.0/23,192.168.86.0/24,10.0.0.0/8"
if [ -n "${WARP_EXCLUDE_RANGES:-}" ]; then
    IFS=',' read -ra _ranges <<< "$WARP_EXCLUDE_RANGES"
    for _cidr in "${_ranges[@]}"; do
        _cidr="$(echo "$_cidr" | tr -d ' ')"
        [ -z "$_cidr" ] && continue
        log "  Excluding $_cidr"
        warp-cli --accept-tos tunnel ip add-range "$_cidr" || true
    done
else
    log "  WARP_EXCLUDE_RANGES not set, skipping local exclusions"
fi
log "Connecting to WARP..."
warp-cli --accept-tos connect
log "Waiting for Connected state..."
for i in $(seq 1 30); do
    if warp-cli --accept-tos status | grep -qi "Connected"; then log "Connected!"; break; fi
    sleep 2
done
log "Updating danted.conf..."
log "Setting up NAT masquerading..."
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -t nat -A POSTROUTING -o "$WARP_INTERFACE" -j MASQUERADE
log "Restarting Dante..."
supervisorctl restart danted || /usr/sbin/danted -f /etc/danted.conf &
log "✅ Setup complete."
