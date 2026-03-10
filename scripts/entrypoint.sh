#!/usr/bin/env bash
# entrypoint.sh – container bootstrap

set -euo pipefail

# ── Verify TUN device is available ───────────────────────────────────────────
if [[ ! -c /dev/net/tun ]]; then
    echo "[entrypoint] ERROR: /dev/net/tun not found."
    echo "             Run the container with --device /dev/net/tun and --cap-add NET_ADMIN"
    exit 1
fi

# ── Validate required environment variables ──────────────────────────────────
: "${WARP_ORG:?WARP_ORG must be set to your Cloudflare Zero Trust organization name}"
: "${CF_ACCESS_CLIENT_ID:?CF_ACCESS_CLIENT_ID must be set}"
: "${CF_ACCESS_CLIENT_SECRET:?CF_ACCESS_CLIENT_SECRET must be set}"

# ── Setup Cloudflare Zero Trust MDM file ──────────────────────────────────────
echo "[entrypoint] Setting up MDM configuration for Zero Trust..."
mkdir -p /var/lib/cloudflare-warp
cat <<EOF > /var/lib/cloudflare-warp/mdm.xml
<?xml version="1.0" encoding="UTF-8"?>
<dict>
  <key>organization</key>
  <string>${WARP_ORG}</string>
  <key>auth_client_id</key>
  <string>${CF_ACCESS_CLIENT_ID}</string>
  <key>auth_client_secret</key>
  <string>${CF_ACCESS_CLIENT_SECRET}</string>
  <key>warp_connector_token</key>
  <string>${WARP_CONNECTOR_TOKEN:-}</string>
  <key>service_mode</key>
  <string>warp</string>
  <key>enable_teams_registration</key>
  <true/>
</dict>
EOF

# ── Generate danted.conf with runtime ALLOWED_RANGES ─────────────────────────
ALLOWED="${ALLOWED_RANGES:-0.0.0.0/0}"
echo "[entrypoint] Configuring Dante with allowed client ranges: ${ALLOWED}"
cat <<DCONF > /etc/danted.conf
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = 1080
external: CloudflareWARP

socksmethod: none
clientmethod: none

DCONF

# Generate client pass and socks pass blocks for each allowed range
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

# ── Create log directories ────────────────────────────────────────────────────
mkdir -p /var/log/supervisor

# ── Hand off to supervisord ───────────────────────────────────────────────────
echo "[entrypoint] Starting supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
