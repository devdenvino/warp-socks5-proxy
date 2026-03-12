#!/usr/bin/env bash
# entrypoint.sh – container bootstrap
#
# Supported WARP_MODE values:
#   zero-trust  (default) – enroll into a Cloudflare Zero Trust org via service token
#   warp-plus             – consumer WARP+ with a license key
#   free                  – free Cloudflare WARP, no credentials required

set -euo pipefail

# ── Verify TUN device is available ───────────────────────────────────────────
if [[ ! -c /dev/net/tun ]]; then
    echo "[entrypoint] ERROR: /dev/net/tun not found."
    echo "             Run the container with --device /dev/net/tun and --cap-add NET_ADMIN"
    exit 1
fi

WARP_MODE="${WARP_MODE:-zero-trust}"
echo "[entrypoint] WARP_MODE=${WARP_MODE}"

# ── Validate required environment variables per mode ─────────────────────────
case "$WARP_MODE" in
    zero-trust)
        : "${WARP_ORG:?WARP_ORG must be set in zero-trust mode}"
        if [ -z "${WARP_CONNECTOR_TOKEN:-}" ]; then
            : "${CF_ACCESS_CLIENT_ID:?CF_ACCESS_CLIENT_ID must be set (or provide WARP_CONNECTOR_TOKEN)}"
            : "${CF_ACCESS_CLIENT_SECRET:?CF_ACCESS_CLIENT_SECRET must be set (or provide WARP_CONNECTOR_TOKEN)}"
        fi
        ;;
    warp-plus)
        : "${WARP_LICENSE_KEY:?WARP_LICENSE_KEY must be set in warp-plus mode}"
        ;;
    free)
        echo "[entrypoint] Free WARP mode – no credentials required."
        ;;
    *)
        echo "[entrypoint] ERROR: Unknown WARP_MODE '${WARP_MODE}'. Use: zero-trust | warp-plus | free"
        exit 1
        ;;
esac

# ── Setup Cloudflare Zero Trust MDM file ──────────────────────────────────────
mkdir -p /var/lib/cloudflare-warp

case "$WARP_MODE" in
    zero-trust)
        if [ -n "${WARP_CONNECTOR_TOKEN:-}" ]; then
            echo "[entrypoint] Setting up MDM for WARP Connector mode..."
            cat <<EOF > /var/lib/cloudflare-warp/mdm.xml
<?xml version="1.0" encoding="UTF-8"?>
<dict>
  <key>organization</key>
  <string>${WARP_ORG}</string>
  <key>service_mode</key>
  <string>warp</string>
</dict>
EOF
        else
            echo "[entrypoint] Setting up MDM for Zero Trust (service token) mode..."
            cat <<EOF > /var/lib/cloudflare-warp/mdm.xml
<?xml version="1.0" encoding="UTF-8"?>
<dict>
  <key>organization</key>
  <string>${WARP_ORG}</string>
  <key>auth_client_id</key>
  <string>${CF_ACCESS_CLIENT_ID}</string>
  <key>auth_client_secret</key>
  <string>${CF_ACCESS_CLIENT_SECRET}</string>
  <key>service_mode</key>
  <string>warp</string>
</dict>
EOF
        fi
        ;;
    warp-plus|free)
        # Consumer modes: remove any stale MDM file to prevent unintended org enrollment.
        rm -f /var/lib/cloudflare-warp/mdm.xml
        echo "[entrypoint] No MDM file written (consumer mode)."
        ;;
esac

# ── Generate danted.conf with runtime port + ALLOWED_RANGES ──────────────────
ALLOWED="${ALLOWED_RANGES:-0.0.0.0/0}"
SOCKS_PORT="${SOCKS5_PORT:-1080}"
echo "[entrypoint] Configuring Dante on port ${SOCKS_PORT} with allowed client ranges: ${ALLOWED}"

cat <<DCONF > /etc/danted.conf
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = ${SOCKS_PORT}
external: CloudflareWARP

socksmethod: none
clientmethod: none

DCONF

IFS=',' read -ra _allowed <<< "$ALLOWED"
for _range in "${_allowed[@]}"; do
    _range="$(echo "$_range" | tr -d ' ')"
    [ -z "$_range" ] && continue
    cat <<DCONF >> /etc/danted.conf
client pass {
    from: ${_range} to: 0.0.0.0/0
    log: connect disconnect error
}

socks pass {
    from: ${_range} to: 0.0.0.0/0
    protocol: tcp udp
    log: connect disconnect error
}

DCONF
done

# ── Set hostname for WARP device identification ──────────────────────────────
# The WARP client reports the system hostname as the device name in the dashboard.
# Explicitly set it here so warp-svc picks it up before registration.
if [ -n "${HOST_NAME:-}" ]; then
    echo "[entrypoint] Setting hostname to: ${HOST_NAME}"
    hostname "${HOST_NAME}" 2>/dev/null || true
fi

# ── Create log directories ────────────────────────────────────────────────────
mkdir -p /var/log/supervisor

# ── Hand off to supervisord ───────────────────────────────────────────────────
echo "[entrypoint] Starting supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
