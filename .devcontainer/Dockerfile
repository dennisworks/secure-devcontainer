# Secure Dev Container image for running Claude Code (or any AI coding agent)
# in no-permissions / auto-accept mode without exposing the host.
#
# Pairs with .devcontainer/docker-compose.yml, which:
#   - drops ALL Linux capabilities (adds NET_ADMIN/NET_RAW only for the
#     firewall init, which the non-root agent user cannot use anyway)
#   - sets no-new-privileges
#   - scopes the bind mount to ONLY the host project (no sibling repos)
#   - runs init-firewall.sh at startup to apply an egress allowlist
#
# Debian-based so Dev Container Features (git-lfs, github-cli, node, dot-config)
# install correctly — those Features ship bash install scripts targeting
# apt-based distros and fail on Alpine.
FROM node:22-bookworm-slim AS devcontainer

# Base tooling the Features and the egress firewall expect.
# openssl is here because Prisma's query engine needs it at runtime; safe to
# leave in for non-Prisma projects (small footprint).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dnsutils \
        git \
        gnupg2 \
        iproute2 \
        iptables \
        ipset \
        openssl \
        wget \
    && rm -rf /var/lib/apt/lists/*

# Egress allowlist firewall, run as root at container start (see the `command`
# and cap_add in .devcontainer/docker-compose.yml). dnsutils/iptables/ipset above
# are what the script needs.
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh

# Claude Code itself is installed at create-time via postCreateCommand in
# devcontainer.json. Here we pre-create the node user's config dir so the
# persisted `claude-config` volume initializes owned by node — at runtime all
# caps are dropped, so a startup chown cannot run.
# Also pin the CLI (no self-update inside the sandbox).
ENV DISABLE_AUTOUPDATER=1
RUN mkdir -p /home/node/.claude && chown -R node:node /home/node/.claude

WORKDIR /workspaces
