# secure-devcontainer

A hardened [Dev Container](https://containers.dev) template for running
[Claude Code](https://claude.com/claude-code) (or any AI coding agent) in
no-permissions / auto-accept mode with a meaningfully reduced blast radius if
the agent goes off the rails.

## Security model

| Control | Mechanism | Where |
| --- | --- | --- |
| Non-root agent user | Runs as `node` (uid 1000), no sudo | `devcontainer.json` `remoteUser` |
| No privilege escalation | `no-new-privileges:true` | `docker-compose.yml` `security_opt` |
| No Linux capabilities | `cap_drop: [ALL]` — agent inherits none | `docker-compose.yml` |
| Bounded filesystem | Only the host project is mounted; sibling repos and parent-dir secrets are not visible | `volumes: ..:/workspaces:cached` |
| Egress allowlist | iptables + ipset default-deny; programmed by root at PID 1, then NET_ADMIN is gone from the agent's user namespace | `init-firewall.sh` |
| Pinned CLI | `DISABLE_AUTOUPDATER=1` so Claude Code can't silently self-update inside the sandbox | `Dockerfile` |
| Persistent Claude login | Named volume `claude-config` survives rebuilds | `docker-compose.yml` |

The firewall runs once at container start as root (PID 1, which holds
`NET_ADMIN`) and then idles. The agent runs as `node`, which has neither
`NET_ADMIN` nor sudo, so it cannot tear the rules down. VS Code attaches over
Docker's exec channel, not over the network, so a locked-down firewall never
prevents attaching.

## Use as a template

```sh
# Create a new project from this template
gh repo create my-project --template dennisworks/secure-devcontainer --private --clone
cd my-project

# Open in VS Code and reopen in the dev container
code .
# Cmd+Shift+P → "Dev Containers: Reopen in Container"
```

Or copy the folder into an existing project:

```sh
cp -r /path/to/secure-devcontainer/.devcontainer ./
```

## Per-project customization

Most projects need to tweak a handful of things — every spot is commented in
the source files.

1. **Allowed egress** — `.devcontainer/init-firewall.sh`, `ALLOWED_DOMAINS`.
   The base set covers Claude + GitHub + npm. Uncomment / add entries for your
   language's package mirror (PyPI, crates.io, proxy.golang.org, …) and any
   API hosts your project calls.
2. **Post-create install** — `.devcontainer/devcontainer.json`,
   `postCreateCommand`. Append your project's install step:
   - Node: `"npm install && npm install -g @anthropic-ai/claude-code"`
   - Python: `"pip install -r requirements.txt && npm install -g @anthropic-ai/claude-code"`
3. **Auto-start dev server** — `.devcontainer/devcontainer.json`,
   `postStartCommand`. Uncomment and point at your run command.
4. **Sibling services** — `.devcontainer/docker-compose.yml`. Add `postgres`,
   `mongo`, `redis`, etc. as additional services and reference them via
   `depends_on`. Sibling services on the compose network are reachable without
   adding them to the firewall allowlist (the Docker subnet is already
   allowed).
5. **Ports** — `.devcontainer/docker-compose.yml`, `ports:` block. Uncomment
   to expose your dev server to the host.

## Verifying the sandbox

After the container boots:

```sh
# Inside the dev container, as `node`
sudo -n true 2>&1                 # should: "sudo: a password is required" (no sudo)
id                                # uid=1000(node) gid=1000(node)
curl -m 3 https://example.com     # should: time out (not on allowlist)
curl -m 5 https://api.github.com  # should: 200 OK (on allowlist)
iptables -L 2>&1                  # should: "Permission denied" (no NET_ADMIN)
```

## Notes

- macOS Docker Desktop exposes bind mounts as accessible regardless of uid, so
  `updateRemoteUserUID: false` is safe and avoids a startup chown that would
  fail under `cap_drop: ALL`.
- `init-firewall.sh` allowlists the IPs each domain resolves to **at startup**.
  CDN-backed hosts can rotate IPs; if a normally-allowed host starts failing,
  rebuild the container (or re-run the script as root) to re-resolve.
- Claude Code's auto-updater is disabled in the sandbox via
  `DISABLE_AUTOUPDATER=1` so the pinned version inside the container can't
  drift mid-session.

## License

MIT.
