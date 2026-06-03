#!/usr/bin/env bash
#
# Egress allowlist firewall for running AI agents in no-permissions mode.
#
# Runs once at container start AS ROOT (needs NET_ADMIN — see cap_add in
# .devcontainer/docker-compose.yml). After it runs, outbound traffic is dropped
# by default; only the destinations allowlisted below are reachable. The agent
# runs as the non-root `node` user, which has no NET_ADMIN and no sudo, so it
# CANNOT modify or tear down these rules.
#
# VS Code / `devcontainer exec` attach over Docker's exec channel (not the
# network), so a locked-down firewall never prevents attaching to the container.
#
# Tune ALLOWED_DOMAINS for your workflow. Note: this allowlists the IPs each
# domain resolves to AT STARTUP. CDN-backed hosts (npm, etc.) can rotate IPs, so
# if a normally-allowed host starts failing, re-run this script to re-resolve.
set -euo pipefail
IFS=$'\n\t'

log() { echo "[init-firewall] $*"; }

# --- Hostnames the agent / build is allowed to reach ----------------------
# Core set covers Claude Code + git/gh + npm. Add language/tool-specific
# package mirrors as needed (pypi.org, files.pythonhosted.org, crates.io,
# proxy.golang.org, etc.).
ALLOWED_DOMAINS=(
  registry.npmjs.org          # npm
  api.anthropic.com           # Claude API / Claude Code
  statsig.anthropic.com       # Claude Code telemetry (drop if undesired)
  claude.ai                   # Claude Code subscription login (Pro)
  console.anthropic.com       # Claude Code OAuth token + refresh (Pro login)
  github.com                  # git / gh
  api.github.com
  codeload.github.com
  objects.githubusercontent.com
  raw.githubusercontent.com
  # --- add project-specific hosts below ---
  # binaries.prisma.sh        # Prisma engines
  # checkpoint.prisma.io
  # pypi.org                  # Python
  # files.pythonhosted.org
  # crates.io                 # Rust
  # static.crates.io
  # proxy.golang.org          # Go
  # sum.golang.org
)

# --- Wait for eth0 to attach ----------------------------------------------
# Docker can start the container's command BEFORE the network namespace's
# veth pair is fully set up — especially on Docker Desktop for Mac, and
# especially for single-service compose projects with no `depends_on` to give
# the network time to warm. Without this wait, the `dig` calls below would
# fail with no A records, the ipset would be empty, default-deny would lock
# the container down with nothing allowlisted, and you'd get cryptic
# EAI_AGAIN errors from npm/curl/etc. for the rest of the container's life.
log "waiting for eth0 to come up..."
for i in $(seq 1 30); do
  if ip -4 addr show eth0 2>/dev/null | grep -q 'inet '; then
    log "eth0 up after ~$(awk "BEGIN { printf \"%.1f\", $i * 0.5 }")s"
    break
  fi
  sleep 0.5
done
if ! ip -4 addr show eth0 2>/dev/null | grep -q 'inet '; then
  log "ERROR: eth0 never came up — Docker likely failed to attach the network"
  log "       (commonly a port-bind conflict on the host). Applying default-deny"
  log "       anyway; fix the underlying issue and rebuild the container."
fi

# --- Reset the filter table only ------------------------------------------
# Do NOT flush nat/mangle: Docker's embedded-DNS redirect for 127.0.0.11 lives
# in this container's nat table, and flushing it breaks all name resolution.
iptables -F
iptables -X
ipset destroy allowed-domains 2>/dev/null || true

# --- Outbound essentials (evaluated before the default-deny below) --------
# Loopback
iptables -A OUTPUT -o lo -j ACCEPT
# Docker's embedded DNS resolver (127.0.0.11) — needed to resolve names
iptables -A OUTPUT -d 127.0.0.11 -j ACCEPT
# DNS — required to resolve the allowlist and at runtime
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
# Replies to connections we accepted (lets the dev server answer host requests)
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# The local Docker network, so the app can reach sibling services
# (postgres, mongo, redis, etc.) defined in docker-compose.yml.
DOCKER_SUBNET=$(ip route show dev eth0 2>/dev/null \
  | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | head -n1 || true)
if [ -n "${DOCKER_SUBNET:-}" ]; then
  iptables -A OUTPUT -d "$DOCKER_SUBNET" -j ACCEPT
  log "allowed docker subnet $DOCKER_SUBNET (sibling services)"
else
  log "WARN: could not determine docker subnet; sibling services may be unreachable"
fi

# --- Build the allowed-destination ipset ----------------------------------
ipset create allowed-domains hash:net

# GitHub publishes its CIDR ranges; pull them so all of git/gh works reliably.
if gh_meta=$(curl -fsS --max-time 10 https://api.github.com/meta 2>/dev/null); then
  echo "$gh_meta" | tr -d ' ",' \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | sort -u \
    | while read -r cidr; do ipset add allowed-domains "$cidr" 2>/dev/null || true; done
  log "added GitHub IP ranges from api.github.com/meta"
else
  log "WARN: could not fetch GitHub meta ranges (falling back to A records below)"
fi

# Resolve each allowlisted hostname to its current A records.
for domain in "${ALLOWED_DOMAINS[@]}"; do
  ips=$(dig +short A "$domain" 2>/dev/null \
    | grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true)
  if [ -z "$ips" ]; then
    log "WARN: no A record for $domain"
    continue
  fi
  for ip in $ips; do ipset add allowed-domains "$ip" 2>/dev/null || true; done
  log "allowed $domain"
done

iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# --- Default policy: deny egress, keep inbound (local dev) open -----------
iptables -P INPUT ACCEPT     # inbound to a local dev container is low-risk
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
log "egress default-deny active"
