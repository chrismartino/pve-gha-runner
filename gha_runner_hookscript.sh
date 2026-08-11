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
# 2. Put the main creation script somewhere permanent and fill in CONFIG below
#    (MAIN_SCRIPT_PATH, GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY_PATH, OWNERREPO).
#    The private key path must be readable by root only.
#
# 3. The FIRST container needs to be created by hand, once, with
#    EPHEMERAL_RUNNER=true, so it picks up -hookscript pointing at this file
#    (see HOOKSCRIPT_VOLID in the main script). Every container it recreates
#    after that inherits the same flag automatically.
#
# 4. Install the log rotation config, or recreate.log/hook.log will grow
#    unbounded:
#      cp gha-runner-hook.logrotate /etc/logrotate.d/gha-runner-hook
#
# How Proxmox invokes this: `<script> <vmid> <phase>` where phase is one of
# pre-start, post-start, pre-stop, post-stop. Only post-stop does anything
# here. This file also re-invokes itself with an internal marker in place of
# a real phase (see DETACHED_MARKER) to escape the sandboxed context it's
# originally invoked under - not a Proxmox concept, just an internal handoff.
#
set -u

VMID="$1"
PHASE="$2"

# --- CONFIG: fill these in ---
MAIN_SCRIPT_PATH="/root/lxc_create_github_actions_runner_app.sh"
GITHUB_APP_ID=""
GITHUB_APP_PRIVATE_KEY_PATH=""
OWNERREPO=""
EXTRA_INSTALL_SCRIPT=""
# --- end config ---

STATE_DIR="/var/lib/gha-runner-hook"
LAST_RECREATE_FILE="$STATE_DIR/last_recreate"
MIN_RECREATE_INTERVAL=60  # seconds - flap guard, see below

# Marker used to re-invoke this file via systemd-run instead of a real phase.
DETACHED_MARKER="__gha_detached_post_stop__"

log() {
    logger -t gha-runner-hook "$*"
    echo "[gha-runner-hook] $*"
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

echo "$NOW" > "$LAST_RECREATE_FILE"

log "CT $VMID finished its job and powered off. Destroying and recreating."

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
export OWNERREPO
[ -n "$EXTRA_INSTALL_SCRIPT" ] && export EXTRA_INSTALL_SCRIPT

log "Recreating..."
if ! "$MAIN_SCRIPT_PATH" >>"$STATE_DIR/recreate.log" 2>&1; then
    log "ERROR: $MAIN_SCRIPT_PATH exited non-zero. Check $STATE_DIR/recreate.log."
    return 1
fi

log "Recreation finished (see $STATE_DIR/recreate.log for details)."
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
# default, but the CONFIG block above is hardcoded literals read fresh from
# the file, so a clean re-invocation just works.
log "post-stop received for CT $VMID, relaunching detached via systemd-run"
if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --quiet --collect \
        --unit="gha-runner-hook-${VMID}-$(date +%s)" \
        --description="GHA runner post-stop handler for CT $VMID" \
        "$0" "$VMID" "$DETACHED_MARKER" >>"$STATE_DIR/hook.log" 2>&1
else
    log "Warning: systemd-run not found, falling back to plain background job"
    ( handle_poststop ) >>"$STATE_DIR/hook.log" 2>&1 &
    disown
fi

exit 0
