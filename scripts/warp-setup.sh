#!/usr/bin/env bash
# warp-setup.sh – WARP registration and connection
#
# Reads WARP_MODE to choose the correct registration path:
#   zero-trust  – register via MDM service token or connector token
#   warp-plus   – register as consumer, then apply license key
#   free        – register as consumer (no license)

set -euo pipefail

WARP_INTERFACE="CloudflareWARP"
WARP_MODE="${WARP_MODE:-zero-trust}"

log() { echo "[warp-setup] $*"; }

log "Waiting for warp-svc..."
for i in $(seq 1 30); do
    warp-cli --accept-tos status &>/dev/null && break || sleep 2
done

log "Device hostname: $(hostname)"
log "Ensuring registration (mode=${WARP_MODE})..."

_registered=false
if warp-cli --accept-tos status 2>&1 | grep -qi "Registration Missing"; then
    _registered=false
else
    _registered=true
fi

if [ "$_registered" = false ]; then
    case "$WARP_MODE" in
        zero-trust)
            if [ -n "${WARP_CONNECTOR_TOKEN:-}" ]; then
                log "Registering as WARP Connector..."
                warp-cli --accept-tos connector new "$WARP_CONNECTOR_TOKEN" || true
            else
                log "Registering with Zero Trust (service token via MDM)..."
                warp-cli --accept-tos registration new || true
            fi
            ;;
        warp-plus)
            log "Registering as consumer WARP client..."
            warp-cli --accept-tos registration new || true
            sleep 3
            log "Applying WARP+ license key..."
            warp-cli --accept-tos registration license "${WARP_LICENSE_KEY}" || {
                log "WARNING: License key application failed. Continuing in free mode."
            }
            ;;
        free)
            log "Registering as free WARP client..."
            warp-cli --accept-tos registration new || true
            ;;
    esac
    sleep 3
else
    log "Already registered."

    # If warp-plus mode, try to apply license even if already registered
    # (covers the case where the container was restarted with a new key).
    if [ "$WARP_MODE" = "warp-plus" ] && [ -n "${WARP_LICENSE_KEY:-}" ]; then
        _current_license=$(warp-cli --accept-tos registration show 2>/dev/null | grep -i "license" || true)
        if echo "$_current_license" | grep -qi "WARP+"; then
            log "WARP+ license already active."
        else
            log "Applying WARP+ license key..."
            warp-cli --accept-tos registration license "${WARP_LICENSE_KEY}" || {
                log "WARNING: License key application failed."
            }
        fi
    fi
fi

# ── Add local IP exclusions ───────────────────────────────────────────────────
log "Adding local exclusions..."

# Always exclude Docker bridge subnets so container-to-container traffic and
# Docker port-forwarding are not tunnelled through WARP.
# WARP's routing table includes 172.0.0.0/6 which swallows 172.16-31.x.x.
for _docker_cidr in 172.16.0.0/12 192.168.0.0/16 10.0.0.0/8; do
    log "  Auto-excluding Docker/RFC-1918 range: $_docker_cidr"
    warp-cli --accept-tos tunnel ip add-range "$_docker_cidr" || true
done

if [ -n "${WARP_EXCLUDE_RANGES:-}" ]; then
    IFS=',' read -ra _ranges <<< "$WARP_EXCLUDE_RANGES"
    for _cidr in "${_ranges[@]}"; do
        _cidr="$(echo "$_cidr" | tr -d ' ')"
        [ -z "$_cidr" ] && continue
        log "  Excluding $_cidr"
        warp-cli --accept-tos tunnel ip add-range "$_cidr" || true
    done
else
    log "  WARP_EXCLUDE_RANGES not set, skipping additional custom exclusions"
fi

# ── Set device name in Cloudflare dashboard ───────────────────────────────
if [ -n "${HOST_NAME:-}" ] && [ -f /var/lib/cloudflare-warp/reg.json ]; then
    _reg_id=$(grep -o '"registration_id":"[^"]*"' /var/lib/cloudflare-warp/reg.json | cut -d'"' -f4 || true)
    _api_token=$(grep -o '"api_token":"[^"]*"' /var/lib/cloudflare-warp/reg.json | cut -d'"' -f4 || true)
    if [ -n "$_reg_id" ] && [ -n "$_api_token" ]; then
        log "Setting device name to: ${HOST_NAME}"
        _resp=$(curl -sf -X PATCH \
            "https://api.cloudflareclient.com/v0a4005/reg/$_reg_id" \
            -H "Authorization: Bearer $_api_token" \
            -H "Content-Type: application/json" \
            -d "{\"model\": \"${HOST_NAME}\"}" 2>&1) && \
            log "Device name set successfully." || \
            log "WARNING: Could not set device name (non-critical)."
    fi
fi

# ── Connect ───────────────────────────────────────────────────────────────────
log "Connecting to WARP..."
warp-cli --accept-tos connect

log "Waiting for Connected state..."
for i in $(seq 1 30); do
    if warp-cli --accept-tos status | grep -qi "Connected"; then
        log "Connected!"
        break
    fi
    sleep 2
done

# ── Verify WARP+ seat (informational) ────────────────────────────────────────
if [ "$WARP_MODE" = "warp-plus" ]; then
    _account=$(warp-cli --accept-tos account 2>/dev/null || true)
    if echo "$_account" | grep -qi "WARP+"; then
        log "✅ WARP+ license confirmed active."
    else
        log "⚠️  WARP+ license could not be confirmed – running in free mode."
        log "   Check your license key and account at https://one.one.one.one"
    fi
fi

# ── NAT masquerading (idempotent) ─────────────────────────────────────────────
log "Setting up NAT masquerading..."
# Only add rules if they don't already exist (idempotent)
iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -t nat -C POSTROUTING -o "$WARP_INTERFACE" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "$WARP_INTERFACE" -j MASQUERADE

# ── Allow inbound SOCKS5 connections on eth0 (WARP client blocks eth0 by default) ──
# The Cloudflare WARP client installs an nftables policy that drops all input AND
# output on non-loopback interfaces. Accept all traffic on eth0 (Docker bridge)
# since eth0 is not an internet-facing interface; CloudflareWARP handles egress.
_socks_port="${SOCKS5_PORT:-1080}"
log "Opening eth0 in WARP nftables (bypass drop policy)..."
nft add rule inet cloudflare-warp input  iif "eth0" accept 2>/dev/null || true
nft add rule inet cloudflare-warp output oif "eth0" accept 2>/dev/null || true

# ── Fix WARP IP policy routing for Docker bridge traffic ──────────────────────
# In Zero Trust Connector mode, warp-cli tunnel ip add-range is ignored.
# WARP's table 65743 routes RFC-1918 ranges through CloudflareWARP, which means
# reply packets from Dante back to Docker bridge clients are misrouted.
# Add high-priority ip rules to force RFC-1918 traffic to use the main table.
log "Adding ip rules for RFC-1918 → main table (priority 100)..."
for _cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
    ip rule add to "$_cidr" table main priority 100 2>/dev/null || true
done

# ── Start Dante ───────────────────────────────────────────────────────────────
log "Restarting Dante..."
supervisorctl restart danted || /usr/sbin/danted -f /etc/danted.conf &

log "✅ Setup complete."
