#!/usr/bin/env bash
#
# Creates and registers a GitHub Actions self-hosted runner inside a Proxmox LXC.
#
# Adapted from oNaiPs/proxmox-scripts (lxc_create_github_actions_runner.sh):
#   https://github.com/oNaiPs/proxmox-scripts/blob/main/lxc_create_github_actions_runner.sh
#
# Changes from the original:
#   1. DHCP instead of a static IP/gateway.
#   2. Auth via GitHub App instead of a long-lived GITHUB_TOKEN (PAT): signs a
#      JWT with the App's private key, exchanges it for a short-lived
#      installation access token, uses that to request the runner
#      registration token. Nothing long-lived is stored on disk or passed to
#      the container.
#   3. Unprivileged container (-unprivileged 1) with fuse=1 alongside
#      nesting/keyctl so Docker still works if installed via
#      EXTRA_INSTALL_SCRIPT. Requires Proxmox VE 9 (LXC 6 + cgroup v2).
#   4. Ephemeral mode (EPHEMERAL_RUNNER=true): registers with --ephemeral and
#      runs as a one-shot systemd unit that powers the container off after
#      one job, paired with a post-stop hookscript (gha_runner_hookscript.sh)
#      that recreates the container. See that file's header for setup.
#   5. Only git/curl/zip installed by default, plus
#      ./bin/installdependencies.sh (the runner's own OS-dependency
#      installer). Anything else your jobs need goes in EXTRA_INSTALL_SCRIPT.
#
# Prerequisites:
#   - A GitHub App with Repository permission "Administration: Read and
#     write" (grants access to the runner registration-token endpoint). For
#     org-level runners (GITHUB_SCOPE=org) use the Organization permission
#     "Self-hosted runners: Read and write" instead - it is narrower.
#   - The App installed on the target repo (or org).
#   - The App ID and its private key (.pem) downloaded locally.
#   - `openssl` available on the Proxmox host.
#
# Release version of these scripts. Set to the release version in the release
# PR (see CONTRIBUTING.md); must match gha_runner_hookscript.sh. Print it
# without running anything with: ./create-pve-lxc-gha-runner.sh --version
VERSION="1.2.0"
if [ "${1:-}" = "--version" ]; then
    echo "pve-gha-runner $VERSION"
    exit 0
fi

set -e

# Variables
# Ubuntu 24.04 LTS - matches GitHub's ubuntu-latest, supported into 2029.
# Filename can shift with point releases; if the download 404s, run
# `pveam update && pveam available | grep ubuntu-24.04` to find the current one.
TEMPL_URL="http://download.proxmox.com/images/system/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
PCTSIZE="20G"
PCT_ARCH="amd64"
PCT_CORES="4"
PCT_MEMORY="4096"
PCT_SWAP="4096"
PCT_STORAGE="local-zfs"
# vztmpl (templates) and rootdir (container disks) are different Proxmox
# storage content types - a ZFS pool's "local-zfs" storage typically only
# supports rootdir/images, not vztmpl. Templates go on TEMPL_STORAGE
# ("local"); the container itself goes on PCT_STORAGE. Check `pvesm status`
# if unsure which storage has vztmpl.
TEMPL_STORAGE="local"
# Set via env var so the hookscript can invoke this non-interactively.
EPHEMERAL_RUNNER="${EPHEMERAL_RUNNER:-false}"
# Proxmox volid of the post-stop hookscript. Needs a storage with the
# "snippets" content type - "local-zfs" won't have it, "local" does.
HOOKSCRIPT_VOLID="local:snippets/gha_runner_hookscript.sh"
# Optional local script (on the Proxmox host) to install extra dependencies
# inside the container beyond git/curl/zip. Pushed in and run once per
# container creation - keep it fast, since ephemeral mode reruns it per job.
EXTRA_INSTALL_SCRIPT="${EXTRA_INSTALL_SCRIPT:-}"
# Max concurrent gha-runner-* containers, checked via `pct list` before any
# work starts. Applies to both manual and hookscript-triggered invocations.
# The hookscript always requests exactly one replacement per job, so this is
# a ceiling/safety-net, not something that actively tops the pool back up.
# Precedence: exported env var, then MAX_RUNNERS in the target's
# /etc/gha-runner/<slug>.conf (resolved below, once the slug is known), then 3.
MAX_RUNNERS="${MAX_RUNNERS:-}"
CONFIG_DIR="/etc/gha-runner"

log() {
    local text="$1"
    echo -e "\033[33m$text\033[0m"
}

# Fetches a "token" field from a GitHub API POST response, retrying on
# transient failures (api.github.com occasionally 5xx's, e.g. a bare 503 on
# the registration-token endpoint with no other explanation). Deliberately
# does NOT use curl's -f here: -f discards the response body on a non-2xx,
# which is exactly what we need to log for debugging, and as a bare
# assignment (not piped) a -f failure would abort the whole script under
# `set -e` before the retry loop - or any error message - ever ran.
# Prints the token on success; on exhausted retries, prints the last
# response to stderr and returns non-zero.
fetch_gh_token() {
    local desc="$1"
    shift
    local max_attempts=5 attempt=1 delay=3
    local res token
    while [ "$attempt" -le "$max_attempts" ]; do
        res=$(curl -sS "$@")
        token=$(echo "$res" | grep -o '"token": *"[^"]*' | head -1 | grep -o '[^"]*$' || true)
        if [ -n "$token" ]; then
            printf '%s' "$token"
            return 0
        fi
        if [ "$attempt" -eq "$max_attempts" ]; then
            echo "$res" >&2
            return 1
        fi
        log "-- $desc: no token in response (attempt $attempt/$max_attempts), retrying in ${delay}s..." >&2
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}

log "-- pve-gha-runner $VERSION"

# GITHUB_SCOPE selects what the runner registers against:
#   repo (default) - one repository, identified by OWNERREPO ("owner/repo").
#   org            - an organization, identified by GITHUB_ORG. Needs the App's
#                    Organization permission "Self-hosted runners: Read and
#                    write" rather than the repo "Administration" permission.
# The target is needed up front (before the App/JWT prompts below) so
# MAX_RUNNERS can be checked per target: each target gets its own pool via a
# "repo-<slug>" tag on the container, rather than sharing one global count of
# all gha-runner-* containers.
GITHUB_SCOPE="${GITHUB_SCOPE:-repo}"
case "$GITHUB_SCOPE" in
    repo)
        if [ -z "${OWNERREPO:-}" ]; then
            read -r -p "Enter github owner/repo: " OWNERREPO
            echo
        fi
        if ! [[ "$OWNERREPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
            echo "OWNERREPO must look like owner/repo, got: $OWNERREPO" >&2
            exit 1
        fi
        TARGET="$OWNERREPO"
        TARGET_API="repos/$OWNERREPO"
        TARGET_URL="https://github.com/$OWNERREPO"
        # Proxmox tags allow [a-z0-9_.-] - lowercase and swap "/" for "-".
        REPO_SLUG=$(echo "$OWNERREPO" | tr '[:upper:]' '[:lower:]' | tr '/' '-')
        ;;
    org)
        if [ -z "${GITHUB_ORG:-}" ]; then
            read -r -p "Enter github organization: " GITHUB_ORG
            echo
        fi
        if ! [[ "$GITHUB_ORG" =~ ^[A-Za-z0-9._-]+$ ]]; then
            echo "GITHUB_ORG must be an organization name, got: $GITHUB_ORG" >&2
            exit 1
        fi
        TARGET="$GITHUB_ORG"
        TARGET_API="orgs/$GITHUB_ORG"
        TARGET_URL="https://github.com/$GITHUB_ORG"
        # GitHub owner names can't contain ".", so an "org." prefix can never
        # collide with a repo slug ("owner-repo").
        REPO_SLUG="org.$(echo "$GITHUB_ORG" | tr '[:upper:]' '[:lower:]')"
        ;;
    *)
        echo "GITHUB_SCOPE must be 'repo' or 'org', got: $GITHUB_SCOPE" >&2
        exit 1
        ;;
esac

# Honor the per-target cap from the same config the hookscript sources, so
# manual runs and hookscript recreations enforce the same MAX_RUNNERS. Sourced
# in a subshell so only that one value is taken from the file.
REPO_CONF="$CONFIG_DIR/$REPO_SLUG.conf"
if [ -z "$MAX_RUNNERS" ] && [ -f "$REPO_CONF" ]; then
    # shellcheck source=/dev/null
    MAX_RUNNERS=$(. "$REPO_CONF" >/dev/null 2>&1 && printf '%s' "${MAX_RUNNERS:-}") || MAX_RUNNERS=""
    [ -n "$MAX_RUNNERS" ] && log "-- Using MAX_RUNNERS=$MAX_RUNNERS from $REPO_CONF"
fi
MAX_RUNNERS="${MAX_RUNNERS:-3}"
if ! [[ "$MAX_RUNNERS" =~ ^[0-9]+$ ]]; then
    echo "MAX_RUNNERS must be a non-negative integer, got: $MAX_RUNNERS" >&2
    exit 1
fi

RUNNING_RUNNERS=0
for ctid in $(pct list 2>/dev/null | awk 'NR>1 && $NF ~ /^gha-runner-/ {print $1}'); do
    CTTAGS=$(pct config "$ctid" 2>/dev/null | awk -F': ' '/^tags:/ {print $2}')
    # Tolerate comma as well as the standard semicolon separator, in case of
    # older PVE versions or manually-edited tags.
    case ";$(echo "$CTTAGS" | tr ',' ';');" in
        *";repo-$REPO_SLUG;"*) RUNNING_RUNNERS=$((RUNNING_RUNNERS + 1)) ;;
    esac
done
if [ "$RUNNING_RUNNERS" -ge "$MAX_RUNNERS" ]; then
    log "Already at MAX_RUNNERS ($MAX_RUNNERS) for $TARGET: found $RUNNING_RUNNERS existing gha-runner-* container(s) tagged repo-$REPO_SLUG. Not creating another."
    exit 0
fi

# --- Resolve the latest runner release + its published checksum ---
# The asset filename includes the version (e.g.
# actions-runner-linux-x64-2.336.0.tar.gz), so the version has to be looked
# up first - there's no unversioned alias that resolves.
log "-- Resolving latest actions/runner release"
RUNNER_RELEASE_JSON=$(curl -fsS -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/actions/runner/releases/latest")
RUNNER_TAG=$(echo "$RUNNER_RELEASE_JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
RUNNER_VERSION="${RUNNER_TAG#v}"
GITHUB_RUNNER_FILE="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
GITHUB_RUNNER_URL="https://github.com/actions/runner/releases/download/${RUNNER_TAG}/${GITHUB_RUNNER_FILE}"
GITHUB_RUNNER_SHA256=$(echo "$RUNNER_RELEASE_JSON" | grep -A30 "\"name\": \"$GITHUB_RUNNER_FILE\"" |
    grep -m1 '"digest"' | sed -E 's/.*"digest": *"sha256:([a-f0-9]+)".*/\1/' || true)

if [ -z "$RUNNER_VERSION" ]; then
    echo "Could not resolve the latest actions/runner release version." >&2
    exit 1
fi
if [ -z "$GITHUB_RUNNER_SHA256" ]; then
    log "-- Warning: no published checksum found for $GITHUB_RUNNER_FILE; proceeding without integrity verification"
fi
log "-- Using runner $RUNNER_TAG"

# --- GitHub App inputs (instead of GITHUB_TOKEN) ---

if [ -z "${GITHUB_APP_ID:-}" ]; then
    read -r -p "Enter GitHub App ID: " GITHUB_APP_ID
    echo
fi

if [ -z "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ]; then
    read -r -p "Enter path to GitHub App private key (.pem): " GITHUB_APP_PRIVATE_KEY_PATH
    echo
fi

if [ ! -f "$GITHUB_APP_PRIVATE_KEY_PATH" ]; then
    echo "Private key file not found at: $GITHUB_APP_PRIVATE_KEY_PATH" >&2
    exit 1
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
    iat=$((now - 60))  # allow for clock drift
    exp=$((now + 540)) # GitHub's max is 10 minutes; use 9 to be safe

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

if [ -z "${GITHUB_APP_INSTALLATION_ID:-}" ]; then
    log "-- Looking up installation ID for $TARGET"
    INSTALL_RES=$(curl -sS \
        -H "Authorization: Bearer $APP_JWT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/$TARGET_API/installation")
    # `|| true`: under `set -e`, VAR=$(cmd | grep ...) aborts silently if
    # grep finds nothing, since the assignment's exit status follows the
    # pipeline's last command. The check below only runs because of this.
    GITHUB_APP_INSTALLATION_ID=$(echo "$INSTALL_RES" | grep -o '"id": *[0-9]*' | head -1 | grep -o '[0-9]*' || true)

    if [ -z "$GITHUB_APP_INSTALLATION_ID" ]; then
        echo "Could not find an installation of this App on $TARGET. Is it installed there?" >&2
        echo "$INSTALL_RES" >&2
        exit 1
    fi
fi

# --- Exchange the JWT for a short-lived installation access token ---

log "-- Requesting installation access token"
INSTALLATION_TOKEN=$(fetch_gh_token "installation access token" -X POST \
    -H "Authorization: Bearer $APP_JWT" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/app/installations/$GITHUB_APP_INSTALLATION_ID/access_tokens") || {
    echo "Failed to obtain installation access token after retries." >&2
    exit 1
}

TEMPL_FILE=$(basename "$TEMPL_URL")
PCTID=$(pvesh get /cluster/nextid)

# pveam checksum-verifies against Proxmox's manifest; a raw curl download doesn't.
log "-- Downloading $TEMPL_FILE template..."
if command -v pveam >/dev/null 2>&1 && pveam update >/dev/null 2>&1 &&
    pveam available --section system 2>/dev/null | grep -q "$TEMPL_FILE"; then
    pveam download "$TEMPL_STORAGE" "$TEMPL_FILE"
    TEMPL_FILE_PATH="/var/lib/vz/template/cache/$TEMPL_FILE"
    [ -f "$TEMPL_FILE_PATH" ] || TEMPL_FILE_PATH=$(pvesm path "$TEMPL_STORAGE:vztmpl/$TEMPL_FILE" 2>/dev/null || echo "$TEMPL_FILE")
else
    log "-- pveam manifest lookup failed, falling back to direct download (unverified)"
    curl -fsS -C - -o "$TEMPL_FILE" "$TEMPL_URL"
    TEMPL_FILE_PATH="$TEMPL_FILE"
fi

# ZFS notes: Docker's overlay2 driver works fine on a ZFS-backed rootfs
# (OpenZFS has supported the d_type flag overlayfs needs since 0.8.x). Don't
# point Docker's own storage driver at zfs from inside the container - that
# needs direct pool/kernel-module access an unprivileged container shouldn't
# have. Leave Docker on overlay2.
log "-- Creating LXC container with ID:$PCTID"
PCT_CREATE_ARGS=(
    -arch "$PCT_ARCH"
    -ostype ubuntu
    -unprivileged 1
    -hostname "gha-runner-$PCTID"
    -cores "$PCT_CORES"
    -memory "$PCT_MEMORY"
    -swap "$PCT_SWAP"
    -storage "$PCT_STORAGE"
    -features "nesting=1,keyctl=1,fuse=1"
    -net0 "name=eth0,bridge=vmbr0,ip=dhcp,type=veth"
    # "repo-<slug>" lets one hookscript serve multiple repos: it reads this
    # tag back at post-stop time to know which repo/App config to use,
    # instead of having a single repo hardcoded in the hookscript file.
    # Proxmox tags are semicolon-separated (both in `pct config` output and
    # the -tags argument here).
    -tags "gha-runner;repo-$REPO_SLUG"
)
if [ "$EPHEMERAL_RUNNER" = "true" ]; then
    if [ ! -f "/var/lib/vz/snippets/$(basename "${HOOKSCRIPT_VOLID#*:snippets/}")" ] &&
        ! pvesm path "$HOOKSCRIPT_VOLID" >/dev/null 2>&1; then
        echo "Warning: hookscript $HOOKSCRIPT_VOLID not found. Copy" >&2
        echo "gha_runner_hookscript.sh into that storage's snippets directory" >&2
        echo "(e.g. /var/lib/vz/snippets/) before this container runs its first job," >&2
        echo "or it won't recreate itself on poweroff." >&2
    fi
    PCT_CREATE_ARGS+=(-hookscript "$HOOKSCRIPT_VOLID")
fi
pct create "$PCTID" "$TEMPL_FILE_PATH" "${PCT_CREATE_ARGS[@]}"

log "-- Resizing container to $PCTSIZE"
pct resize "$PCTID" rootfs "$PCTSIZE"

log "-- Starting container"
pct start "$PCTID"
sleep 10

log "-- Running updates"
# passwd -l (lock) instead of -d (delete): an empty password can mean "no
# password required" under some PAM configs. Your own access via pct exec/
# pct enter is unaffected, since that goes through the host, not PAM.
pct exec "$PCTID" -- bash -c "apt update -y && apt install -y git curl zip && passwd -l root"

if [ -n "$EXTRA_INSTALL_SCRIPT" ]; then
    log "-- Running EXTRA_INSTALL_SCRIPT: $EXTRA_INSTALL_SCRIPT"
    pct push "$PCTID" "$EXTRA_INSTALL_SCRIPT" /root/extra-install.sh --perms 700
    pct exec "$PCTID" -- /root/extra-install.sh
    pct exec "$PCTID" -- rm -f /root/extra-install.sh
fi

log "-- Getting runner installation token"
RUNNER_TOKEN=$(fetch_gh_token "runner registration token" -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $INSTALLATION_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/$TARGET_API/actions/runners/registration-token") || {
    echo "Failed to obtain runner registration token after retries." >&2
    exit 1
}

# RUNNER_TOKEN is written into a script pushed into the container and run
# there, rather than inlined into `pct exec ... bash -c "...$RUNNER_TOKEN..."`,
# which would expose it in that process's argv via `ps` on the host.
RUNNER_SETUP_SCRIPT=$(mktemp)
cat >"$RUNNER_SETUP_SCRIPT" <<EOF
#!/usr/bin/env bash
set -e
# Absolute path, not relative + cd: pct exec without --cwd starts the
# command using the calling host process's cwd if that path also exists in
# the container ("/" always does) - a relative "actions-runner" here can
# silently land at /actions-runner instead of /root/actions-runner
# depending on what invoked this script.
mkdir -p /root/actions-runner && cd /root/actions-runner
curl -fsS -o "$GITHUB_RUNNER_FILE" -L "$GITHUB_RUNNER_URL"
EOF
if [ -n "$GITHUB_RUNNER_SHA256" ]; then
    cat >>"$RUNNER_SETUP_SCRIPT" <<EOF
echo "$GITHUB_RUNNER_SHA256  $GITHUB_RUNNER_FILE" | sha256sum -c -
EOF
fi
cat >>"$RUNNER_SETUP_SCRIPT" <<EOF
tar xzf "$GITHUB_RUNNER_FILE"
if [ ! -x run.sh ]; then
    echo "FATAL: run.sh missing or not executable after tar extraction. Contents of actions-runner/:" >&2
    ls -la >&2
    exit 1
fi
./bin/installdependencies.sh
EOF

if [ "$EPHEMERAL_RUNNER" = "true" ]; then
    cat >>"$RUNNER_SETUP_SCRIPT" <<EOF
RUNNER_ALLOW_RUNASROOT=1 ./config.sh --unattended --ephemeral --replace --url "$TARGET_URL" --token "$RUNNER_TOKEN"
if [ ! -x run.sh ]; then
    echo "FATAL: run.sh missing or not executable after config.sh. Contents of actions-runner/:" >&2
    ls -la >&2
    exit 1
fi
cat > /etc/systemd/system/gha-runner.service <<'UNIT'
[Unit]
Description=GitHub Actions Ephemeral Runner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/root/actions-runner
Environment=RUNNER_ALLOW_RUNASROOT=1
ExecStart=/root/actions-runner/run.sh
ExecStopPost=/sbin/poweroff
Restart=no
User=root

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now gha-runner.service
# systemctl's exit code doesn't confirm run.sh actually launched - for
# Type=simple it returns once the process forks, not once exec() succeeds.
sleep 2
if ! systemctl is-active --quiet gha-runner.service; then
    echo "FATAL: gha-runner.service is not active 2s after enable --now. Status:" >&2
    systemctl status gha-runner.service --no-pager >&2 || true
    exit 1
fi
EOF
else
    cat >>"$RUNNER_SETUP_SCRIPT" <<EOF
RUNNER_ALLOW_RUNASROOT=1 ./config.sh --unattended --replace --url "$TARGET_URL" --token "$RUNNER_TOKEN"
./svc.sh install root
./svc.sh start
EOF
fi
chmod 700 "$RUNNER_SETUP_SCRIPT"

log "-- Installing runner"
pct push "$PCTID" "$RUNNER_SETUP_SCRIPT" /root/setup-runner.sh --perms 700
pct exec "$PCTID" -- /root/setup-runner.sh
# Ephemeral containers can power off before/during this call - harmless.
pct exec "$PCTID" -- rm -f /root/setup-runner.sh || true
rm -f "$RUNNER_SETUP_SCRIPT"

# Only clean up templates we fetched ourselves - pveam-managed ones are
# checksum-tracked and worth keeping for reuse.
if [ "$TEMPL_FILE_PATH" = "$TEMPL_FILE" ]; then
    rm -f "$TEMPL_FILE"
fi

log "-- Done. Container $PCTID is registered as a runner for $TARGET."
if [ "$EPHEMERAL_RUNNER" = "true" ]; then
    log "-- Ephemeral mode: it will power off after one job and, if the"
    log "   hookscript is in place, recreate itself automatically."
fi
