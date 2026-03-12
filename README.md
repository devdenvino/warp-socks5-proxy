# warp-socks5-proxy

Dockerised [Cloudflare WARP](https://developers.cloudflare.com/warp-client/) client exposed as a **SOCKS5 proxy** via [Dante](https://www.inet.no/dante/).

Connect any application through Cloudflare's network by pointing it at the container's SOCKS5 port.

## Quick start

```bash
# 1. Clone the repo
git clone https://github.com/devdenvino/warp-proxy-setup.git
cd warp-proxy-setup

# 2. Create your .env from the template
cp .env.example .env
# Edit .env – set WARP_MODE and the credentials for your chosen mode

# 3. Start the container
docker compose up -d

# 4. Test the proxy
curl -x socks5h://localhost:1080 https://cloudflare.com/cdn-cgi/trace
```

## Configuration

All options are set through environment variables in your `.env` file.
See [.env.example](.env.example) for the full list with descriptions.

### WARP modes

The container supports three modes, selected via `WARP_MODE`:

| Mode | Description | Required variables |
|---|---|---|
| `zero-trust` (default) | Cloudflare Zero Trust / Teams via service token | `WARP_ORG`, `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` |
| `warp-plus` | Consumer WARP+ with a license key | `WARP_LICENSE_KEY` |
| `free` | Free Cloudflare WARP, no credentials needed | — |

**Zero Trust (default – existing behaviour):**

```env
WARP_MODE=zero-trust
WARP_ORG=my-company
CF_ACCESS_CLIENT_ID=xxx.access
CF_ACCESS_CLIENT_SECRET=xxx
```

**WARP+ (consumer paid):**

```env
WARP_MODE=warp-plus
WARP_LICENSE_KEY=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**Free WARP:**

```env
WARP_MODE=free
```

### Environment variables

| Variable | Required | Description |
|---|---|---|
| `WARP_MODE` | No | `zero-trust` (default), `warp-plus`, or `free` |
| `WARP_ORG` | zero-trust | Cloudflare Zero Trust organization slug |
| `CF_ACCESS_CLIENT_ID` | zero-trust* | Service token Client ID |
| `CF_ACCESS_CLIENT_SECRET` | zero-trust* | Service token Client Secret |
| `WARP_CONNECTOR_TOKEN` | No | Connector token (alternative to service token creds) |
| `WARP_LICENSE_KEY` | warp-plus | WARP+ license key from [one.one.one.one](https://one.one.one.one) |
| `WARP_EXCLUDE_RANGES` | No | Comma-separated CIDRs to exclude from tunnel |
| `SOCKS5_PORT` | No | Proxy listen port (default: `1080`) |
| `SOCKS5_LISTEN` | No | Host bind address (default: `0.0.0.0`) |
| `ALLOWED_RANGES` | No | CIDRs allowed to connect to proxy (default: `0.0.0.0/0`) |

\* Not required when `WARP_CONNECTOR_TOKEN` is provided instead.

### Multi-server setup

For running multiple instances (e.g. different sites), create separate env files and reference them:

```bash
docker compose --env-file server1.env up -d
```

## Architecture

```
┌────────────┐      ┌─────────────────────────────────────────────┐
│ Your app   │─────▶│  Container                                  │
│ SOCKS5     │:1080 │  ┌──────────┐   ┌───────────────────────┐   │
│            │      │  │  Dante   │──▶│  Cloudflare WARP      │───┼──▶ Internet
│            │      │  │  SOCKS5  │   │  (CloudflareWARP tun) │   │    (via CF network)
└────────────┘      │  └──────────┘   └───────────────────────┘   │
                    │  managed by supervisord                     │
                    └─────────────────────────────────────────────┘
```

## Requirements

- Docker Engine 20.10+ with Compose V2
- Linux host (WARP client requires Linux; tested on Ubuntu/Debian and Raspberry Pi OS)
- `NET_ADMIN` capability and `/dev/net/tun` device access

## Security notes

- **Never commit `.env` files** with real credentials. They are excluded by `.gitignore`.
- Set `ALLOWED_RANGES` to your local subnet(s) in production to prevent unauthorized proxy usage.
- The SOCKS5 proxy has **no authentication** by default. Restrict access at the network level or via `ALLOWED_RANGES`.

## Troubleshooting

```bash
# Check WARP status inside the container
docker exec warp-proxy warp-cli --accept-tos status

# View logs
docker compose logs -f

# Manual connectivity test from inside the container
docker exec warp-proxy curl -I https://cloudflare.com/cdn-cgi/trace
```

## License

[MIT](LICENSE)
