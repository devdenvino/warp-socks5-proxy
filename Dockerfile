FROM ubuntu:22.04

LABEL org.opencontainers.image.title="warp-socks5-proxy" \
   org.opencontainers.image.description="Cloudflare WARP client exposed as a SOCKS5 proxy via Dante" \
   org.opencontainers.image.source="https://github.com/devdenvino/warp-proxy-setup" \
   org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# ── System dependencies ───────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
   curl \
   gnupg \
   lsb-release \
   ca-certificates \
   iproute2 \
   iptables \
   net-tools \
   dante-server \
   supervisor \
   jq \
   dnsutils \
   iputils-ping \
   procps \
   && rm -rf /var/lib/apt/lists/*

# ── Install Cloudflare WARP client (detect architecture automatically) ────────
RUN ARCH=$(dpkg --print-architecture) \
   && curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
   | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
   && echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
   https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
   | tee /etc/apt/sources.list.d/cloudflare-client.list \
   && apt-get update \
   && apt-get install -y --no-install-recommends cloudflare-warp \
   && rm -rf /var/lib/apt/lists/*

# ── Copy configuration files ───────────────────────────────────────────────────
COPY conf/danted.conf       /etc/danted.conf
COPY conf/supervisord.conf  /etc/supervisor/conf.d/supervisord.conf
COPY scripts/entrypoint.sh  /entrypoint.sh
COPY scripts/warp-setup.sh  /warp-setup.sh

RUN chmod +x /entrypoint.sh /warp-setup.sh

# ── Socks5 proxy port (Dante) ─────────────────────────────────────────────────
EXPOSE 1080

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
   CMD warp-cli --accept-tos status | grep -q Connected || exit 1

# ── WARP needs TUN device and NET_ADMIN ───────────────────────────────────────
# Run with: --cap-add NET_ADMIN --device /dev/net/tun
# See docker-compose.yml for the full recommended invocation.

ENTRYPOINT ["/entrypoint.sh"]
