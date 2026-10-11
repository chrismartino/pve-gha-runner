#!/usr/bin/env bash
#
# Proxmox hookscript for ephemeral GitHub Actions runner containers.
# Companion to create-pve-lxc-gha-runner.sh (EPHEMERAL_RUNNER=true).
#
# On post-stop, destroys the container that just finished its one job and
# creates a fresh one to replace it, so there's always a runner available.
#
# --- One-time setup ---
#
# 1. Copy this file to a storage with the "snippets" content type enabled
#    (local-zfs won't have it by default; "local" does):
#      cp gha_runner_hookscript.sh /var/lib/vz/snippets/
#      chmod 700 /var/lib/vz/snippets/gha_runner_hookscript.sh
#
# 2. Put the main creation script somewhere permanent and set MAIN_SCRIPT_PATH
#    below if it's not at the default location.
#
# 3. For each repo, create a per-repo config file at
#    /etc/gha-runner/<slug>.conf (slug = owner/repo with "/" -> "-", e.g.
#    /etc/gha-runner/myorg-myrepo.conf), setting GITHUB_APP_ID,
#    GITHUB_APP_PRIVATE_KEY_PATH, OWNERREPO, and optionally MAX_RUNNERS /
#    EXTRA_INSTALL_SCRIPT for that repo. For an org-level pool set
#    GITHUB_SCOPE="org" and GITHUB_ORG instead of OWNERREPO; its file is
#    /etc/gha-runner/org.<org>.conf (lowercased). See examples/repo.conf.example.
#    Each private key path must be readable by root only. This hookscript
#    file is shared across all repos - it reads back the "repo-<slug>" tag
#    (set by the main script at container creation) to know which repo a
#    given container belongs to, and sources that repo's config file.
#
# 4. The FIRST container for each repo needs to be created by hand, once,
#    with EPHEMERAL_RUNNER=true and OWNERREPO set to that repo, so it picks
#    up -hookscript pointing at this file (see HOOKSCRIPT_VOLID in the main
#    script) and the "repo-<slug>" tag. Every container it recreates after
#    that inherits both automatically.
#
# 5. Install the log rotation config, or recreate-<slug>.log/hook-<slug>.log
#    (one pair per repo, under /var/lib/gha-runner-hook/) will grow unbounded:
#      cp gha-runner-hook.logrotate /etc/logrotate.d/gha-runner-hook
#
# How Proxmox invokes this: `<script> <vmid> <phase>` where phase is one of
# pre-start, post-start, pre-stop, post-stop. Only post-stop does anything
# here. This file also re-invokes itself with an internal marker in place of
# a real phase (see DETACHED_MARKER) to escape the sandboxed context it's
# originally invoked under - not a Proxmox concept, just an internal handoff.
#
set -u

# Release version of these scripts. Set to the release version in the release
# PR (see CONTRIBUTING.md); must match create-pve-lxc-gha-runner.sh.
VERSION="0.1.0-dev"

VMID="$1"
PHASE="$2"

# --- CONFIG: fill this in ---
MAIN_SCRIPT_PATH="/root/scripts/create-pve-lxc-gha-runner.sh"
# Per-repo config lives in $CONFIG_DIR/<slug>.conf - see step 3 above.
CONFIG_DIR="/etc/gha-runner"
# --- end config ---

STATE_DIR="/var/lib/gha-runner-hook"
MIN_RECREATE_INTERVAL=60 # seconds - flap guard, see below

# Marker used to re-invoke this file via systemd-run instead of a real phase.
DETACHED_MARKER="__gha_detached_post_stop__"

# Set once the repo tag is resolved below - declared empty here (rather than
# left unset) so log() can reference it safely under `set -u` even for the
# messages logged before that point (hostname mismatch, missing tag).
REPO_SLUG=""

log() {
    local repo_tag=""
    [ -n "$REPO_SLUG" ] && repo_tag="[$REPO_SLUG] "
    # Syslog tag stays constant (not repo-suffixed) so `journalctl -t
    # gha-runner-hook` still catches everything across every repo; the
    # per-repo prefix lives in the message text instead.
    logger -t gha-runner-hook "$repo_tag$*"
    echo "[gha-runner-hook] $repo_tag$*"
}

# Only act on post-stop (or our own detached re-invocation).
if [ "$PHASE" != "post-stop" ] && [ "$PHASE" != "$DETACHED_MARKER" ]; then
    exit 0
fi

# Only act on containers this setup owns - a second guard in case this
# hookscript ever gets attached to something else by mistake.
HOSTNAME=$(pct config "$VMID" 2>/dev/null | grep '^hostname:' | awk '{print $2}')
case "$HOSTNAME" in
    gha-runner-*) ;;
    *)
        log "post-stop fired for CT $VMID (hostname: ${HOSTNAME:-unknown}), doesn't look like one of ours - ignoring"
        exit 0
        ;;
esac

# Resolve which repo this container belongs to from its "repo-<slug>" tag
# (set by the main script at creation - see -tags there) and source that
# repo's config. This is what lets one hookscript file serve any number of
# repos instead of one hardcoded OWNERREPO.
CTTAGS=$(pct config "$VMID" 2>/dev/null | awk -F': ' '/^tags:/ {print $2}')
REPO_SLUG=""
for tag in $(echo "$CTTAGS" | tr ',;' '  '); do
    case "$tag" in
        repo-*) REPO_SLUG="${tag#repo-}" ;;
    esac
done
if [ -z "$REPO_SLUG" ]; then
    log "post-stop fired for CT $VMID but no repo-<slug> tag found (tags: ${CTTAGS:-none}) - can't tell which repo config to use, ignoring"
    exit 0
fi

# The slug becomes part of a file path that is then sourced as root, so only
# accept what the main script can produce (Proxmox tag characters).
if ! [[ "$REPO_SLUG" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
    log "post-stop fired for CT $VMID but repo slug '$REPO_SLUG' has unexpected characters - ignoring"
    exit 0
fi

REPO_CONF="$CONFIG_DIR/$REPO_SLUG.conf"
if [ ! -f "$REPO_CONF" ]; then
    log "post-stop fired for CT $VMID (repo slug: $REPO_SLUG) but no config at $REPO_CONF - ignoring"
    exit 0
fi
# shellcheck source=/dev/null
. "$REPO_CONF"
GITHUB_SCOPE="${GITHUB_SCOPE:-repo}"
if [ -z "${GITHUB_APP_ID:-}" ] || [ -z "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ]; then
    log "ERROR: $REPO_CONF is missing GITHUB_APP_ID or GITHUB_APP_PRIVATE_KEY_PATH - refusing to act on CT $VMID"
    exit 1
fi
if [ "$GITHUB_SCOPE" = "org" ]; then
    if [ -z "${GITHUB_ORG:-}" ]; then
        log "ERROR: $REPO_CONF sets GITHUB_SCOPE=org but not GITHUB_ORG - refusing to act on CT $VMID"
        exit 1
    fi
elif [ -z "${OWNERREPO:-}" ]; then
    log "ERROR: $REPO_CONF is missing OWNERREPO - refusing to act on CT $VMID"
    exit 1
fi
MAX_RUNNERS="${MAX_RUNNERS:-3}"

# Per-repo, not one shared file: with multiple repos' containers stopping
# independently, a single hook.log/recreate.log interleaves unrelated repos'
# output with only "CT $VMID" in each line to tell them apart.
HOOK_LOG="$STATE_DIR/hook-$REPO_SLUG.log"
RECREATE_LOG="$STATE_DIR/recreate-$REPO_SLUG.log"

# Per-VMID, not a single global file: two runners (from the same or
# different repos) finishing jobs within MIN_RECREATE_INTERVAL of each other
# is normal under load, and shouldn't make the second look like a flap of
# the first.
LAST_RECREATE_FILE="$STATE_DIR/last_recreate-$VMID"

mkdir -p "$STATE_DIR"

# Everything below runs via systemd-run, not a plain background job:
#   1. This hookscript runs synchronously as part of the stop task itself -
#      `pct` hasn't released its lock on $VMID yet, so an immediate destroy
#      fails with "container is running". Backgrounding fixes this part.
#   2. Backgrounding alone doesn't escape the cgroup/mount-namespace
#      sandboxing this hookscript inherits from whatever spawned it (likely
#      pve-container@$VMID.service, mid-teardown at this moment) - that
#      surfaced as "Permission denied" mounting the replacement container's
#      dataset. systemd-run launches a genuinely independent unit as a child
#      of PID 1 instead.
handle_poststop() {

    # --- Flap guard ---
    # If registration is broken (revoked App install, bad key, GitHub API down),
    # the container could crash-loop indefinitely. Refuse to recreate more than
    # once per MIN_RECREATE_INTERVAL and make the failure loud instead.
    NOW=$(date +%s)
    LAST=0
    [ -f "$LAST_RECREATE_FILE" ] && LAST=$(cat "$LAST_RECREATE_FILE" 2>/dev/null || echo 0)
    ELAPSED=$((NOW - LAST))

    if [ "$ELAPSED" -lt "$MIN_RECREATE_INTERVAL" ]; then
        log "CT $VMID stopped only ${ELAPSED}s after the last recreate (< ${MIN_RECREATE_INTERVAL}s threshold)."
        log "Refusing to recreate automatically - this usually means registration is failing repeatedly."
        log "Check: App installation still valid? Private key readable? GitHub API reachable?"
        log "Destroying CT $VMID but NOT creating a replacement. Fix the underlying issue, then run"
        log "$MAIN_SCRIPT_PATH by hand (with EPHEMERAL_RUNNER=true) to resume."
        if ! FLAP_DESTROY_ERR=$(pct destroy "$VMID" --purge 2>&1); then
            log "Additionally, pct destroy $VMID failed: $FLAP_DESTROY_ERR"
        fi
        return 0
    fi

    echo "$NOW" >"$LAST_RECREATE_FILE"

    log "CT $VMID finished its job and powered off. Destroying and recreating."

    # This file (in the snippets directory) and the creation script are installed
    # separately, so they can end up on different versions. Warn, don't block.
    MAIN_VERSION=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$MAIN_SCRIPT_PATH" 2>/dev/null | head -1)
    if [ "${MAIN_VERSION:-unknown (older than 0.1.0)}" != "$VERSION" ]; then
        log "WARNING: hookscript is $VERSION but $MAIN_SCRIPT_PATH is ${MAIN_VERSION:-unknown (older than 0.1.0)}. Update both (see README: Upgrading)."
    fi

    # Even backgrounded, the outer stop task needs a moment to release its
    # PVE-level lock on $VMID, or the first attempt fails with "container is
    # running" instead of a ZFS-level error.
    sleep 2

    # systemd auto-generates a .mount unit for any mounted path, independent of
    # the container's own lifecycle - pve-container@$VMID.service deactivates
    # cleanly, but its rootfs's .mount unit stays active regardless, and that's
    # what blocks pct destroy/zfs destroy with "dataset is busy" (no process has
    # an open fd - lsof/fuser confirmed that separately). Stop it explicitly
    # before destroying.
    ROOTFS_VOLID=$(pct config "$VMID" 2>/dev/null | grep '^rootfs:' | sed -E 's/^rootfs: *([^,]+),.*/\1/')
    MOUNT_UNIT=""
    if [ -n "$ROOTFS_VOLID" ]; then
        ROOTFS_PATH=$(pvesm path "$ROOTFS_VOLID" 2>/dev/null)
        if [ -n "$ROOTFS_PATH" ] && command -v systemd-escape >/dev/null 2>&1; then
            MOUNT_UNIT=$(systemd-escape --path --suffix=mount "$ROOTFS_PATH")
        fi
    fi

    DESTROY_OK=false
    DESTROY_ERR=""
    for attempt in $(seq 1 8); do
        # Stop the mount unit before every attempt - systemd can
        # regenerate/re-activate it, so this is cheap insurance each pass.
        if [ -n "$MOUNT_UNIT" ]; then
            systemctl stop "$MOUNT_UNIT" >/dev/null 2>&1 || true
        fi
        # If this container was ever inspected via `pct mount` during debugging
        # and never unmounted, the dataset stays held indefinitely. No-op if it
        # wasn't mounted.
        pct unmount "$VMID" >/dev/null 2>&1 || true
        if DESTROY_ERR=$(pct destroy "$VMID" --purge 2>&1); then
            DESTROY_OK=true
            break
        fi
        log "pct destroy $VMID attempt $attempt/8 failed, retrying in 5s: $DESTROY_ERR"
        # Captured while still failing, not after - by the time all attempts are
        # exhausted, whatever was holding it may have already cleared.
        SYSTEMD_UNITS=$(systemctl list-units --all --no-legend 2>/dev/null | grep -F "$VMID" || true)
        [ -n "$SYSTEMD_UNITS" ] && log "  (attempt $attempt) systemd units mentioning $VMID: $SYSTEMD_UNITS"
        sleep 5
    done

    if [ "$DESTROY_OK" != "true" ]; then
        log "ERROR: pct destroy $VMID failed after 8 attempts (~40s). Not attempting" \
            "to create a replacement until this is resolved (leftover container may be in a" \
            "bad state)."
        log "Last error: $DESTROY_ERR"

        ZFS_DATASET=$(echo "$DESTROY_ERR" | grep -oE "destroy '[^']+'" | sed -E "s/destroy '(.+)'/\1/")
        if [ -n "$ZFS_DATASET" ]; then
            log "Diagnostics for $ZFS_DATASET:"
            log "  zfs holds: $(zfs holds "$ZFS_DATASET" 2>&1)"
            MOUNTPOINT=$(zfs get -H -o value mountpoint "$ZFS_DATASET" 2>/dev/null)
            log "  mountpoint: ${MOUNTPOINT:-unknown}"
            log "  host mounts under it: $(mount | grep -F "${MOUNTPOINT:-__none__}" || echo "none")"
            if [ -n "$MOUNTPOINT" ] && command -v fuser >/dev/null 2>&1; then
                log "  fuser -vm: $(fuser -vm "$MOUNTPOINT" 2>&1)"
            fi
            if [ -n "$MOUNTPOINT" ] && command -v lsof >/dev/null 2>&1; then
                log "  lsof (first 20 lines): $(lsof +D "$MOUNTPOINT" 2>&1 | head -20)"
            fi
        else
            log "Could not parse dataset name out of the destroy error to run diagnostics on."
        fi

        return 1
    fi

    if [ ! -x "$MAIN_SCRIPT_PATH" ]; then
        log "ERROR: $MAIN_SCRIPT_PATH not found or not executable. CT $VMID was destroyed" \
            "but no replacement was created. Fix MAIN_SCRIPT_PATH in this hookscript and" \
            "either rerun it by hand or wait for the next trigger."
        return 1
    fi

    export EPHEMERAL_RUNNER=true
    export GITHUB_APP_ID
    export GITHUB_APP_PRIVATE_KEY_PATH
    export GITHUB_SCOPE
    [ -n "${OWNERREPO:-}" ] && export OWNERREPO
    [ -n "${GITHUB_ORG:-}" ] && export GITHUB_ORG
    export MAX_RUNNERS
    [ -n "${EXTRA_INSTALL_SCRIPT:-}" ] && export EXTRA_INSTALL_SCRIPT
    [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ] && export GITHUB_APP_INSTALLATION_ID

    log "Recreating..."
    if ! "$MAIN_SCRIPT_PATH" >>"$RECREATE_LOG" 2>&1; then
        log "ERROR: $MAIN_SCRIPT_PATH exited non-zero. Check $RECREATE_LOG."
        return 1
    fi

    log "Recreation finished (see $RECREATE_LOG for details)."
}

if [ "$PHASE" = "$DETACHED_MARKER" ]; then
    # We are the detached re-invocation launched via systemd-run below - do
    # the actual work and report its exit status.
    handle_poststop
    exit $?
fi

# Relaunch this file via systemd-run rather than backgrounding it directly:
# systemd-run starts a genuinely independent transient unit as a child of
# PID 1, escaping the cgroup/namespace context this hookscript was invoked
# under (plain `&`/`disown` only detach shell job-control tracking). Passing
# vmid+marker to re-run the FILE (rather than exporting a function/vars
# through systemd-run) sidesteps environment-inheritance uncertainty - a
# fresh transient unit doesn't inherit the caller's shell environment by
# default, but the detached re-invocation re-derives everything itself (repo
# tag lookup, sourcing the per-repo config) rather than depending on
# anything from this process's environment, so a clean re-invocation just
# works.
log "post-stop received for CT $VMID (pve-gha-runner hookscript $VERSION), relaunching detached via systemd-run"
if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --quiet --collect \
        --unit="gha-runner-hook-${VMID}-$(date +%s)" \
        --description="GHA runner post-stop handler for CT $VMID" \
        "$0" "$VMID" "$DETACHED_MARKER" >>"$HOOK_LOG" 2>&1
else
    log "Warning: systemd-run not found, falling back to plain background job"
    (handle_poststop) >>"$HOOK_LOG" 2>&1 &
    disown
fi

exit 0
