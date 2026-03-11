#!/usr/bin/env bash
set -euo pipefail
WARP_INTERFACE="CloudflareWARP"
log() { echo "[warp-setup] $*"; }
log "Waiting for warp-svc..."
for i in $(seq 1 30); do warp-cli --accept-tos status &>/dev/null && break || sleep 2; done

log "Ensuring registration..."
_registered=false
# Check if already registered (status will show "Registration Missing" if not)
if warp-cli --accept-tos status 2>&1 | grep -qi "Registration Missing"; then
    _registered=false
else
    _registered=true
fi

if [ "$_registered" = false ]; then
    if [ -n "${WARP_CONNECTOR_TOKEN:-}" ]; then
        # WARP Connector mode: register with the connector token from the dashboard.
        # This registers the device as warp_connector@<team>.cloudflareaccess.com.
        log "Registering as WARP Connector..."
        warp-cli --accept-tos connector new "$WARP_CONNECTOR_TOKEN" || true
    else
        # Standard WARP mode: register using service token creds from MDM.
        # Device will register as non_identity@<team>.cloudflareaccess.com.
        log "Registering with standard WARP (service token via MDM)..."
        warp-cli --accept-tos registration new || true
    fi
    # Wait for registration to take effect
    sleep 3
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
log "Setting up NAT masquerading..."
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -t nat -A POSTROUTING -o "$WARP_INTERFACE" -j MASQUERADE
log "Restarting Dante..."
supervisorctl restart danted || /usr/sbin/danted -f /etc/danted.conf &
log "✅ Setup complete."
