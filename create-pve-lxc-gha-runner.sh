#!/usr/bin/env bash
#
# Creates and registers a GitHub Actions self-hosted runner inside a Proxmox LXC.
#
# Adapted from oNaiPs/proxmox-scripts (lxc_create_github_actions_runner.sh):
#   https://github.com/oNaiPs/proxmox-scripts/blob/main/lxc_create_github_actions_runner.sh
#
# Changes from the original:
#   1. Network: container gets its address via DHCP instead of a static IP/gateway.
#   2. Auth: instead of asking for a long-lived GITHUB_TOKEN (PAT), this script
#      authenticates as a GitHub App. It signs a JWT with the App's private key,
#      exchanges it for a short-lived installation access token, and uses that
#      token to request the runner registration token. Nothing long-lived is
#      stored on disk or passed to the container.
#   3. Container: created unprivileged (-unprivileged 1) instead of the
#      original's implicit privileged default, with fuse=1 added alongside
#      nesting/keyctl so Docker still works unprivileged if you install it
#      (see EXTRA_INSTALL_SCRIPT below). Requires Proxmox VE 9 (LXC 6 +
#      cgroup v2) for reliable Docker-in-LXC support at this isolation level
#      - see the comment above `pct create` below.
#   4. Ephemeral mode (EPHEMERAL_RUNNER=true): registers with --ephemeral
#      (GitHub deregisters the runner after one job) and runs it as a
#      one-shot systemd unit that powers the container off when the job
#      exits, instead of installing it as a persistent service. Also attaches
#      a post-stop hookscript (see gha_runner_hookscript.sh, a companion
#      file) so the container recreates itself after each job. See that
#      file's header for the setup steps this requires beyond running this
#      script once.
#   5. Dependencies: only git/curl/zip are installed by default. Docker,
#      language runtimes, or anything else your jobs need can be installed
#      via an optional EXTRA_INSTALL_SCRIPT (see that variable below) instead
#      of being baked into this script.
#
# Prerequisites:
#   - A GitHub App must exist (create one under Settings > Developer settings >
#     GitHub Apps, or your org's equivalent).
#   - The App needs Repository permissions: "Administration: Read and write"
#     (this is what grants access to the runner registration-token endpoint).
#     For organization-level runners instead of repo-level, give the App the
#     Organization permission "Self-hosted runners: Read and write" instead,
#     and adjust the registration-token URL near the bottom of this script
#     from /repos/$OWNERREPO/... to /orgs/$ORG/... (see comment there).
#   - The App must be installed on the target repo (or org).
#   - You need: the App ID, and the App's private key (.pem) downloaded locally.
#   - `openssl` must be available on the Proxmox host (it almost always is).
#
set -e

# Variables
# Ubuntu 24.04 LTS: matches what GitHub's own ubuntu-latest hosted runners use,
# and is supported into 2029 (the original script's 23.04 template is EOL and
# no longer mirrored). This filename can shift with point releases - if the
# download below 404s, run `pveam update && pveam available | grep ubuntu-24.04`
# on the Proxmox host to find the current one.
TEMPL_URL="http://download.proxmox.com/images/system/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
PCTSIZE="20G"
PCT_ARCH="amd64"
PCT_CORES="4"
PCT_MEMORY="4096"
PCT_SWAP="4096"
PCT_STORAGE="local-zfs"
# Templates (vztmpl) and container rootfs (rootdir) are different content
# types in Proxmox. A ZFS pool's default "local-zfs" storage is typically
# scoped to rootdir/images only - it will NOT accept `pveam download`, which
# needs vztmpl support. Templates go on TEMPL_STORAGE ("local", the
# directory-backed storage that ships with every install and does support
# vztmpl); the container itself is provisioned on PCT_STORAGE. Check
# `pvesm status` if unsure which of your storages has vztmpl in its content
# list.
TEMPL_STORAGE="local"
# Ephemeral mode: registers the runner with --ephemeral and runs it as a
# one-shot systemd unit (see the runner-install section below) instead of a
# persistent service. Set via env var so the companion hookscript can invoke
# this script non-interactively with EPHEMERAL_RUNNER=true.
EPHEMERAL_RUNNER="${EPHEMERAL_RUNNER:-false}"
# Where the post-stop hookscript lives, in Proxmox volid form. Only used when
# EPHEMERAL_RUNNER=true. Like TEMPL_STORAGE, this needs a storage with the
# "snippets" content type enabled - "local-zfs" won't have it by default,
# "local" (directory storage) does.
HOOKSCRIPT_VOLID="local:snippets/gha_runner_hookscript.sh"
# Optional local script (on the Proxmox host) to install extra dependencies
# inside the container beyond git/curl/zip - e.g. Docker, language runtimes,
# or CLIs your jobs need. Pushed in and run once, before the runner
# registers. Runs on every container creation, so in ephemeral mode it
# reruns per job - keep it fast. Unset by default.
EXTRA_INSTALL_SCRIPT="${EXTRA_INSTALL_SCRIPT:-}"
# Max concurrent gha-runner-* containers. Checked against `pct list` before
# any work happens below - applies whether this script was invoked by hand
# or by the post-stop hookscript recreating a finished runner, since both
# paths go through this same check rather than duplicating the limit in two
# places. Raise if you want a bigger pool; the hookscript needs no changes
# either way since it always requests exactly one replacement per job.
MAX_RUNNERS="${MAX_RUNNERS:-3}"

# log function prints text in yellow
log() {
    local text="$1"
    echo -e "\033[33m$text\033[0m"
}

RUNNING_RUNNERS=$(pct list 2>/dev/null | awk 'NR>1 && $NF ~ /^gha-runner-/ {c++} END{print c+0}')
if [ "$RUNNING_RUNNERS" -ge "$MAX_RUNNERS" ]; then
    log "Already at MAX_RUNNERS ($MAX_RUNNERS): found $RUNNING_RUNNERS existing gha-runner-* container(s). Not creating another."
    exit 0
fi

# --- Resolve the latest runner release + its published checksum ---
#
# GitHub enforces a minimum runner version at registration time (v2.329.0 as
# of March 2026), and this script previously pinned an old version, which is
# exactly what let it go stale. Resolving "latest" at runtime avoids that.
# The release asset filename includes the version (e.g.
# actions-runner-linux-x64-2.336.0.tar.gz) - there is no unversioned alias
# that resolves, so the version has to be looked up first.
log "-- Resolving latest actions/runner release"
RUNNER_RELEASE_JSON=$(curl -fsS -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/actions/runner/releases/latest")
RUNNER_TAG=$(echo "$RUNNER_RELEASE_JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
RUNNER_VERSION="${RUNNER_TAG#v}"
GITHUB_RUNNER_FILE="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
GITHUB_RUNNER_URL="https://github.com/actions/runner/releases/download/${RUNNER_TAG}/${GITHUB_RUNNER_FILE}"
GITHUB_RUNNER_SHA256=$(echo "$RUNNER_RELEASE_JSON" | grep -A30 "\"name\": \"$GITHUB_RUNNER_FILE\"" \
    | grep -m1 '"digest"' | sed -E 's/.*"digest": *"sha256:([a-f0-9]+)".*/\1/' || true)

if [ -z "$RUNNER_VERSION" ]; then
    echo "Could not resolve the latest actions/runner release version." >&2
    exit 1
fi
if [ -z "$GITHUB_RUNNER_SHA256" ]; then
    log "-- Warning: no published checksum found for $GITHUB_RUNNER_FILE; proceeding without integrity verification"
fi
log "-- Using runner $RUNNER_TAG"

# --- GitHub App inputs (instead of GITHUB_TOKEN) ---

if [ -z "$GITHUB_APP_ID" ]; then
    read -r -p "Enter GitHub App ID: " GITHUB_APP_ID
    echo
fi

if [ -z "$GITHUB_APP_PRIVATE_KEY_PATH" ]; then
    read -r -p "Enter path to GitHub App private key (.pem): " GITHUB_APP_PRIVATE_KEY_PATH
    echo
fi

if [ ! -f "$GITHUB_APP_PRIVATE_KEY_PATH" ]; then
    echo "Private key file not found at: $GITHUB_APP_PRIVATE_KEY_PATH" >&2
    exit 1
fi

if [ -z "$OWNERREPO" ]; then
    read -r -p "Enter github owner/repo: " OWNERREPO
    echo
fi

if [ -n "$EXTRA_INSTALL_SCRIPT" ] && [ ! -f "$EXTRA_INSTALL_SCRIPT" ]; then
    echo "EXTRA_INSTALL_SCRIPT set but not found at: $EXTRA_INSTALL_SCRIPT" >&2
    exit 1
fi

# --- Helpers for JWT creation ---

b64url() {
    openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

# Build and sign a JWT for GitHub App authentication (valid ~9 minutes).
generate_app_jwt() {
    local now iat exp header payload header_b64 payload_b64 signature
    now=$(date +%s)
    iat=$((now - 60))     # allow for clock drift
    exp=$((now + 540))    # GitHub's max is 10 minutes; use 9 to be safe

    header='{"alg":"RS256","typ":"JWT"}'
    payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$GITHUB_APP_ID")

    header_b64=$(printf '%s' "$header" | b64url)
    payload_b64=$(printf '%s' "$payload" | b64url)
    signature=$(printf '%s' "$header_b64.$payload_b64" | openssl dgst -sha256 -sign "$GITHUB_APP_PRIVATE_KEY_PATH" | b64url)

    echo "$header_b64.$payload_b64.$signature"
}

log "-- Generating GitHub App JWT"
APP_JWT=$(generate_app_jwt)

# --- Resolve installation ID for this repo (unless already provided) ---

if [ -z "$GITHUB_APP_INSTALLATION_ID" ]; then
    log "-- Looking up installation ID for $OWNERREPO"
    INSTALL_RES=$(curl -sS \
        -H "Authorization: Bearer $APP_JWT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$OWNERREPO/installation")
    # `|| true` matters here: under `set -e`, VAR=$(cmd | grep ...) aborts the
    # whole script with NO error message if grep finds nothing, because the
    # assignment's exit status follows the last command in the pipeline. The
    # explicit checks below only run because of this.
    GITHUB_APP_INSTALLATION_ID=$(echo "$INSTALL_RES" | grep -o '"id": *[0-9]*' | head -1 | grep -o '[0-9]*' || true)

    if [ -z "$GITHUB_APP_INSTALLATION_ID" ]; then
        echo "Could not find an installation of this App on $OWNERREPO. Is it installed there?" >&2
        echo "$INSTALL_RES" >&2
        exit 1
    fi
fi

# --- Exchange the JWT for a short-lived installation access token ---

log "-- Requesting installation access token"
INSTALL_TOKEN_RES=$(curl -sS -X POST \
    -H "Authorization: Bearer $APP_JWT" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/app/installations/$GITHUB_APP_INSTALLATION_ID/access_tokens")

INSTALLATION_TOKEN=$(echo "$INSTALL_TOKEN_RES" | grep -o '"token": *"[^"]*' | head -1 | grep -o '[^"]*$' || true)

if [ -z "$INSTALLATION_TOKEN" ]; then
    echo "Failed to obtain installation access token." >&2
    echo "$INSTALL_TOKEN_RES" >&2
    exit 1
fi

# Get filename from the template URL
TEMPL_FILE=$(basename "$TEMPL_URL")

# Get the next available ID from Proxmox
PCTID=$(pvesh get /cluster/nextid)

# Download Ubuntu template (prefer pveam: it checksum-verifies against
# Proxmox's published manifest, which a raw curl download does not)
log "-- Downloading $TEMPL_FILE template..."
if command -v pveam >/dev/null 2>&1 && pveam update >/dev/null 2>&1 \
    && pveam available --section system 2>/dev/null | grep -q "$TEMPL_FILE"; then
    pveam download "$TEMPL_STORAGE" "$TEMPL_FILE"
    TEMPL_FILE_PATH="/var/lib/vz/template/cache/$TEMPL_FILE"
    [ -f "$TEMPL_FILE_PATH" ] || TEMPL_FILE_PATH=$(pvesm path "$TEMPL_STORAGE:vztmpl/$TEMPL_FILE" 2>/dev/null || echo "$TEMPL_FILE")
else
    log "-- pveam manifest lookup failed, falling back to direct download (unverified)"
    curl -fsS -C - -o "$TEMPL_FILE" "$TEMPL_URL"
    TEMPL_FILE_PATH="$TEMPL_FILE"
fi

# Create LXC container (DHCP instead of static IP/gateway)
# Unprivileged (PVE 9): LXC 6 + cgroup v2 on PVE 9 make Docker-in-LXC work
# reliably unprivileged, avoiding the direct root-equivalent host-escape
# surface that privileged + nesting/keyctl carries. `fuse=1` is added
# alongside nesting/keyctl so Docker can fall back to fuse-overlayfs if the
# kernel overlay driver isn't usable unprivileged in your environment -
# without it, Docker's storage driver setup can fail inside unprivileged
# containers depending on kernel/config specifics.
#
# ZFS storage notes:
#   - Provisioned on $PCT_STORAGE (local-zfs), which gives the container its
#     own ZFS dataset for rootfs. Docker's overlay2 driver runs fine on top
#     of that (OpenZFS has supported the d_type readdir flag overlayfs
#     requires since 0.8.x, which any current PVE 9 pool has), so no Docker
#     storage-driver override is needed.
#   - Do NOT point Docker's own storage driver at zfs from inside the
#     container (`--storage-driver zfs`) - that expects direct access to a
#     ZFS pool/kernel module, which isn't available or safe to hand to an
#     unprivileged container. Leave Docker on its overlay2 default.
#   - $PCT_SWAP (a swapfile Proxmox creates inside the container) works fine
#     on a ZFS-backed dataset, but a swapfile sitting on top of ZFS's own
#     ARC caching is somewhat redundant memory pressure. Harmless for a CI
#     runner's workload, just worth knowing if you ever see memory pressure
#     that doesn't match what you'd expect from PCT_MEMORY alone.
log "-- Creating LXC container with ID:$PCTID"
PCT_CREATE_ARGS=(
    -arch $PCT_ARCH
    -ostype ubuntu
    -unprivileged 1
    -hostname "gha-runner-$PCTID"
    -cores $PCT_CORES
    -memory $PCT_MEMORY
    -swap $PCT_SWAP
    -storage $PCT_STORAGE
    -features nesting=1,keyctl=1,fuse=1
    -net0 name=eth0,bridge=vmbr0,ip=dhcp,type=veth
)
if [ "$EPHEMERAL_RUNNER" = "true" ]; then
    if [ ! -f "/var/lib/vz/snippets/$(basename "${HOOKSCRIPT_VOLID#*:snippets/}")" ] \
        && ! pvesm path "$HOOKSCRIPT_VOLID" >/dev/null 2>&1; then
        echo "Warning: hookscript $HOOKSCRIPT_VOLID not found. Copy" >&2
        echo "gha_runner_hookscript.sh into that storage's snippets directory" >&2
        echo "(e.g. /var/lib/vz/snippets/) before this container runs its first job," >&2
        echo "or it won't recreate itself on poweroff." >&2
    fi
    PCT_CREATE_ARGS+=(-hookscript "$HOOKSCRIPT_VOLID")
fi
pct create "$PCTID" "$TEMPL_FILE_PATH" "${PCT_CREATE_ARGS[@]}"

# Resize the container
log "-- Resizing container to $PCTSIZE"
pct resize "$PCTID" rootfs $PCTSIZE

# Start the container & run updates inside it
log "-- Starting container"
pct start "$PCTID"
sleep 10

log "-- Running updates"
# passwd -l (lock) disables password auth outright. The original script used
# `passwd -d` (delete), which leaves an EMPTY password - some PAM configs
# treat that as "no password required" rather than "login disabled," which
# is a real foothold if anything inside the container ever exposes a login
# prompt (sshd, getty, etc). Root access for you still works via `pct exec`/
# `pct enter` regardless, since that goes through the Proxmox host, not PAM.
pct exec "$PCTID" -- bash -c "apt update -y && apt install -y git curl zip && passwd -l root"

# Run the user-supplied extra dependency install script, if any
if [ -n "$EXTRA_INSTALL_SCRIPT" ]; then
    log "-- Running EXTRA_INSTALL_SCRIPT: $EXTRA_INSTALL_SCRIPT"
    pct push "$PCTID" "$EXTRA_INSTALL_SCRIPT" /root/extra-install.sh --perms 700
    pct exec "$PCTID" -- /root/extra-install.sh
    pct exec "$PCTID" -- rm -f /root/extra-install.sh
fi

# Get runner installation token (using the App's installation token instead of a PAT)
log "-- Getting runner installation token"
# For an org-level runner instead of a repo-level one, swap this URL for:
#   https://api.github.com/orgs/$ORG/actions/runners/registration-token
RES=$(curl -fsS -L \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $INSTALLATION_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$OWNERREPO/actions/runners/registration-token")
RUNNER_TOKEN=$(echo "$RES" | grep -o '"token": "[^"]*' | grep -o '[^"]*$' || true)

if [ -z "$RUNNER_TOKEN" ]; then
    echo "Failed to obtain runner registration token." >&2
    echo "$RES" >&2
    exit 1
fi

# Install and start the runner.
#
# NOTE on secret exposure: RUNNER_TOKEN is written to a script that's pushed
# into the container and executed there, rather than being inlined into a
# `pct exec ... bash -c "...$RUNNER_TOKEN..."` command - that form puts the
# token in that process's argv, visible via `ps` on the Proxmox HOST for the
# life of the call. This approach avoids that host-side exposure. It can't
# eliminate the exposure entirely: `config.sh` only accepts the token as a
# CLI flag (no stdin/env support), so it will still appear briefly in the
# container's own process list while config.sh runs - that's a limitation of
# the runner binary itself, not something a wrapper script can fix.
RUNNER_SETUP_SCRIPT=$(mktemp)
cat > "$RUNNER_SETUP_SCRIPT" <<EOF
#!/usr/bin/env bash
set -e
mkdir -p actions-runner && cd actions-runner
curl -fsS -o "$GITHUB_RUNNER_FILE" -L "$GITHUB_RUNNER_URL"
EOF
if [ -n "$GITHUB_RUNNER_SHA256" ]; then
    cat >> "$RUNNER_SETUP_SCRIPT" <<EOF
echo "$GITHUB_RUNNER_SHA256  $GITHUB_RUNNER_FILE" | sha256sum -c -
EOF
fi

if [ "$EPHEMERAL_RUNNER" = "true" ]; then
    # --ephemeral tells GitHub to deregister the runner after exactly one
    # job. That alone doesn't stop the *process* from idling afterward, so
    # it's paired with a one-shot systemd unit (Type=simple, Restart=no,
    # ExecStopPost=poweroff) rather than the persistent service svc.sh
    # installs. `systemctl start` on a Type=simple unit returns as soon as
    # the process forks, not when it finishes - so this call (and the whole
    # provisioning script) returns quickly, and the container then runs its
    # one job and powers itself off with no further host involvement. The
    # post-stop hookscript (see gha_runner_hookscript.sh) is what notices
    # the poweroff and recreates the next container.
    cat >> "$RUNNER_SETUP_SCRIPT" <<EOF
tar xzf "$GITHUB_RUNNER_FILE"
RUNNER_ALLOW_RUNASROOT=1 ./config.sh --unattended --ephemeral --url "https://github.com/$OWNERREPO" --token "$RUNNER_TOKEN"
cat > /etc/systemd/system/gha-runner.service <<'UNIT'
[Unit]
Description=GitHub Actions Ephemeral Runner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/root/actions-runner
ExecStart=/root/actions-runner/run.sh
ExecStopPost=/sbin/poweroff
Restart=no
User=root

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now gha-runner.service
EOF
else
    cat >> "$RUNNER_SETUP_SCRIPT" <<EOF
tar xzf "$GITHUB_RUNNER_FILE"
RUNNER_ALLOW_RUNASROOT=1 ./config.sh --unattended --url "https://github.com/$OWNERREPO" --token "$RUNNER_TOKEN"
./svc.sh install root
./svc.sh start
EOF
fi
chmod 700 "$RUNNER_SETUP_SCRIPT"

log "-- Installing runner"
pct push "$PCTID" "$RUNNER_SETUP_SCRIPT" /root/setup-runner.sh --perms 700
pct exec "$PCTID" -- /root/setup-runner.sh
# In ephemeral mode the container can power itself off before this next call
# runs (or shortly after), so a failure here is expected and harmless -
# there's nothing left to clean up on a container that's already gone.
pct exec "$PCTID" -- rm -f /root/setup-runner.sh || true
rm -f "$RUNNER_SETUP_SCRIPT"

# Delete the template only if we fetched it ourselves outside pveam's cache
# (pveam-managed copies are checksum-tracked and worth keeping for reuse)
if [ "$TEMPL_FILE_PATH" = "$TEMPL_FILE" ]; then
    rm -f "$TEMPL_FILE"
fi

log "-- Done. Container $PCTID is registered as a runner for $OWNERREPO."
if [ "$EPHEMERAL_RUNNER" = "true" ]; then
    log "-- Ephemeral mode: it will power off after one job and, if the"
    log "   hookscript is in place, recreate itself automatically."
fi
