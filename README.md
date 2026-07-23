# 🔐🚇 ssh-mcp-stack

Deploy [`ssh-mcp-server`](https://github.com/10bn/ssh-mcp-server) as a **remote,
publicly reachable MCP server** behind a **Cloudflare Tunnel** — no port
forwarding, no exposed SSH port, no firewall changes. Point any remote-MCP
client (e.g. a Claude.ai custom connector) at the tunnel URL, and it can run
whitelisted SSH commands against your servers through a bearer-token-protected
HTTPS endpoint.

## Quickstart

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/10bn/ssh-mcp-stack/main/install.sh)"
```

This clones the repo to `~/ssh-mcp-stack`, walks you through an interactive
setup wizard (SSH target, command whitelist, tunnel mode), starts the stack
with Docker Compose, and prints your public MCP endpoint URL + bearer token.

> Run it with `bash -c "$(curl ...)"` rather than `curl ... | bash` — this
> form keeps your terminal attached so the wizard's prompts actually work.

## Architecture

```
                         ┌───────────────────────────────┐
 MCP client  ── HTTPS ──▶│  Cloudflare Tunnel (cloudflared)│
 (Claude, etc.)          └───────────────┬─────────────────┘
                                          │ http://mcp-bridge:8000 (docker network)
                                          ▼
                          ┌─────────────────────────────────┐
                          │ mcp-bridge container             │
                          │  ┌─────────────┐   ┌────────────┐│
                          │  │ auth-proxy   │──▶│ supergateway││
                          │  │ (bearer      │   │ (stdio↔SSE) ││
                          │  │  token check)│   └─────┬──────┘│
                          │  └─────────────┘         │ stdio  │
                          │                    ┌──────▼──────┐│
                          │                    │ssh-mcp-server││
                          │                    └──────┬──────┘│
                          └───────────────────────────┼───────┘
                                                        │ SSH
                                                        ▼
                                              your target server(s)
```

- **`ssh-mcp-server`** only speaks stdio and makes *outbound* SSH connections
  — it never listens on the network itself.
- **`supergateway`** wraps it and exposes an SSE (or Streamable HTTP) endpoint
  on an internal, container-local port.
- **`auth-proxy`** sits in front of supergateway inside the same container and
  rejects any request that doesn't carry `Authorization: Bearer <MCP_BEARER_TOKEN>`
  (supergateway has no built-in auth for inbound requests, so this is required
  — do not skip it).
- **`cloudflared`** exposes the bridge publicly, in one of two modes.

## Tunnel modes

Set `TUNNEL_MODE` in `.env` (the installer asks for this):

| Mode    | Setup                                                | URL                                  |
|---------|-------------------------------------------------------|---------------------------------------|
| `quick` | No Cloudflare account needed                          | Random `*.trycloudflare.com`, changes every restart |
| `named` | Requires a tunnel token from the Cloudflare Zero Trust dashboard | Stable custom hostname on your own domain |

### Setting up a named tunnel

1. In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/) go to **Networks → Tunnels → Create a tunnel** (Cloudflared type).
2. Copy the tunnel token shown during setup.
3. Add a **Public Hostname** for the tunnel: hostname of your choice, service
   `HTTP` → `mcp-bridge:8000` (this resolves inside the stack's Docker network).
4. Re-run the installer with `STACK_RECONFIGURE=1` and choose `named`, or set
   in `.env`:
   ```
   TUNNEL_MODE=named
   CLOUDFLARE_TUNNEL_TOKEN=<paste token>
   CLOUDFLARE_TUNNEL_HOSTNAME=mcp.example.com
   ```
5. `docker compose up -d`

## Connecting an MCP client

After install, you'll get a URL like `https://<something>.trycloudflare.com/sse`
(or `https://mcp.example.com/sse` for named tunnels) and a bearer token.
Configure your MCP client to call that URL with:

```
Authorization: Bearer <MCP_BEARER_TOKEN>
```

Quick manual test:

```bash
curl -N -H "Authorization: Bearer $(grep MCP_BEARER_TOKEN .env | cut -d= -f2-)" \
  https://<your-tunnel-url>/sse
```

A `401 {"error":"unauthorized"}` means the token is missing/wrong. A stream
that stays open means the SSE endpoint is reachable and authenticated.

## Configuration files

- **`.env`** (gitignored) — `MCP_BEARER_TOKEN`, `MCP_OUTPUT_TRANSPORT`,
  `TUNNEL_MODE`, `CLOUDFLARE_TUNNEL_TOKEN`, `CLOUDFLARE_TUNNEL_HOSTNAME`. See
  [`.env.example`](.env.example).
- **`config/ssh-config.json`** (gitignored) — SSH target(s) in
  [`ssh-mcp-server`'s `--config-file` format](https://github.com/classfang/ssh-mcp-server#-managing-multiple-ssh-connections).
  See [`config/ssh-config.example.json`](config/ssh-config.example.json). The
  installer writes a single `"default"` connection; edit this file directly
  to add more servers.
- **`secrets/`** (gitignored) — private keys referenced from
  `ssh-config.json` (e.g. `/secrets/id_key`), mounted read-only into
  `mcp-bridge`.

## Security notes (read before exposing this to the internet)

- **The bearer token is your only line of defense** once the tunnel is up.
  Treat it like a password: it's generated once by the installer, stored in
  `.env`, and never printed to logs. Rotate it by editing `.env` and running
  `docker compose up -d` again.
- **Always set a `commandWhitelist`.** Without one, any command the
  underlying `ssh-mcp-server` supports can run on your target host through
  this endpoint. The installer warns loudly and asks for confirmation if you
  skip it — don't skip it in production.
- **Always set `allowedRemotePaths`.** Without it, SFTP upload/download
  accepts any absolute remote path, including files like
  `~/.ssh/authorized_keys` or `/etc/ssh/sshd_config`.
- **For production, layer on [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/policies/access/)**
  in front of the named tunnel (e.g. email OTP or SSO login policy on the
  public hostname). This is optional but strongly recommended in addition to
  the bearer token, not instead of it.
- Manage the SSH credentials in `config/ssh-config.json` and `secrets/` like
  any other production secret — restrict filesystem permissions on the host
  running this stack.

## Manual operation

```bash
cd ~/ssh-mcp-stack
docker compose ps                 # status
docker compose logs -f            # tail all logs
docker compose logs -f cloudflared    # find the current trycloudflare.com URL
docker compose restart
docker compose down                # stop everything
STACK_RECONFIGURE=1 bash install.sh   # redo the setup wizard
```

## Non-interactive install (CI / scripted)

Export `STACK_NONINTERACTIVE=1` plus the variables the wizard would have
asked for: `SSH_HOST`, `SSH_PORT`, `SSH_USER`, `SSH_AUTH_METHOD`
(`password`|`key`), `SSH_PASSWORD` or `SSH_PRIVATE_KEY_PATH` (+
`SSH_PASSPHRASE`), `COMMAND_WHITELIST`, `ALLOWED_REMOTE_PATHS`, `TUNNEL_MODE`,
and — for `named` — `CLOUDFLARE_TUNNEL_TOKEN` + `CLOUDFLARE_TUNNEL_HOSTNAME`.
Then run `bash install.sh` (a plain clone + `bash install.sh` also works fine
here, since there are no interactive prompts left to break).

## Scope

This repo only wires together deployment/networking for the existing
`ssh-mcp-server`. It does not add multi-tenant management, a web UI, or user
accounts, and it does not automate Cloudflare zone/tunnel creation via API —
the named-tunnel token and hostname are created manually in the Cloudflare
dashboard, as documented above.

## License

MIT — see [LICENSE](LICENSE).
