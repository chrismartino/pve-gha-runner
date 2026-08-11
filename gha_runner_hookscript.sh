#!/usr/bin/env bash
#
# Proxmox hookscript for ephemeral GitHub Actions runner containers.
# Companion to lxc_create_github_actions_runner_app.sh (EPHEMERAL_RUNNER=true).
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
#    The private key path must be readable by root only - this hookscript
#    runs as root, same trust level as running the main script by hand.
#    EXTRA_INSTALL_SCRIPT is optional - see EXTRA_INSTALL_SCRIPT in the main
#    script if you want extra dependencies installed in every container.
#
# 3. The FIRST container needs to be created by hand, once, with
#    EPHEMERAL_RUNNER=true, so it picks up -hookscript pointing at this file
#    (see HOOKSCRIPT_VOLID in the main script). Every container it recreates
#    after that inherits the same flag automatically.
#
# How Proxmox invokes this: `<script> <vmid> <phase>` where phase is one of
# pre-start, post-start, pre-stop, post-stop. Only post-stop does anything
# here; the others exit immediately.
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
MIN_RECREATE_INTERVAL=60  # seconds - flap guard, see header

log() {
    logger -t gha-runner-hook "$*"
    echo "[gha-runner-hook] $*"
}

# Only act on post-stop; Proxmox calls this script for every phase.
if [ "$PHASE" != "post-stop" ]; then
    exit 0
fi

# Only act on containers this setup actually owns. The hookscript is
# attached per-container via `-hookscript`, so in practice this only fires
# for our own runners - this check is a second guard in case the same
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

# Everything below runs in a detached background job (see the bottom of this
# file), not inline here. Reason: this hookscript is invoked SYNCHRONOUSLY as
# part of the stop task itself - `pct` hasn't released its lock on $VMID yet
# when post-stop fires, it's still unwinding the outer stop operation. Calling
# `pct destroy` directly from here races that unwind and fails with "container
# is running" even seconds later, because the outer task is itself blocked
# waiting on this hookscript to return - a retry loop in the foreground can't
# out-wait a lock that won't clear until this process exits. Backgrounding the
# real work and returning immediately lets the outer stop task actually finish
# and release the lock before anything tries to touch $VMID again.
handle_poststop() {

# --- Flap guard ---
# If registration is broken (revoked App install, bad key, GitHub API down,
# etc), the container could crash-loop: start, fail immediately, poweroff,
# get recreated, fail again. Without this guard that's a tight spin burning
# GitHub API calls and filling the journal. Refuse to recreate more than
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

# Short initial wait before the first attempt - addresses a different,
# already-confirmed issue than the retry loop below: even backgrounded, the
# outer stop task needs a moment to fully release its PVE-level lock on
# $VMID, or the first attempt fails with "container is running" rather than
# a ZFS-level error. Unlike the retry *count* below, this specific wait was
# validated to matter, so it stays even though extending the retry budget
# itself didn't help.
sleep 2

# Confirmed root cause of "dataset is busy": systemd auto-generates a .mount
# unit for any path it discovers in the mount table, independent of the
# container's own lifecycle - pve-container@$VMID.service deactivates
# cleanly on schedule, but its rootfs's *.mount unit stays active/mounted
# regardless, and that unit's own hold on the mount is what blocks
# pct destroy/zfs destroy (no process has an open fd - lsof/fuser confirmed
# that separately). Fix: stop that unit explicitly before destroying, rather
# than just retrying and hoping something external clears it.
ROOTFS_VOLID=$(pct config "$VMID" 2>/dev/null | grep '^rootfs:' | sed -E 's/^rootfs: *([^,]+),.*/\1/')
MOUNT_UNIT=""
if [ -n "$ROOTFS_VOLID" ]; then
    ROOTFS_PATH=$(pvesm path "$ROOTFS_VOLID" 2>/dev/null)
    if [ -n "$ROOTFS_PATH" ] && command -v systemd-escape >/dev/null 2>&1; then
        MOUNT_UNIT=$(systemd-escape --path --suffix=mount "$ROOTFS_PATH")
    fi
fi

# Retry budget kept short (~40s) rather than long: testing showed extending
# it to ~2 minutes didn't change the outcome when the systemd-unit fix below
# wasn't yet in place - genuinely transient cases resolve fast, and
# persistent ones (like the mount-unit hold) need the fix above, not more
# waiting. Persistent failures fall through to the diagnostics below either way.
DESTROY_OK=false
DESTROY_ERR=""
for attempt in $(seq 1 8); do
    # Stop the mount unit before every attempt, not just after a failure -
    # systemd can regenerate/re-activate these transient units, so this is
    # cheap insurance on each pass rather than a one-time fix.
    if [ -n "$MOUNT_UNIT" ]; then
        systemctl stop "$MOUNT_UNIT" >/dev/null 2>&1 || true
    fi
    # Defensive: if this container was ever inspected via `pct mount` during
    # debugging and never explicitly unmounted, the ZFS dataset stays held
    # and every destroy attempt fails with "dataset is busy" indefinitely -
    # not a transient race, a real leftover resource. No-op (and harmless)
    # if it wasn't mounted.
    pct unmount "$VMID" >/dev/null 2>&1 || true
    if DESTROY_ERR=$(pct destroy "$VMID" --purge 2>&1); then
        DESTROY_OK=true
        break
    fi
    log "pct destroy $VMID attempt $attempt/8 failed, retrying in 5s: $DESTROY_ERR"
    # Lightweight check captured WHILE it's still failing, not after - the
    # detailed zfs/mount diagnostics below only run once, at the very end,
    # by which point whatever was holding it may have already cleared and
    # given a misleadingly clean reading. This catches the host-side systemd
    # unit for the container specifically, since that's tracked separately
    # from the container's own "stopped" state that triggered this hook.
    SYSTEMD_UNITS=$(systemctl list-units --all --no-legend 2>/dev/null | grep -F "$VMID" || true)
    [ -n "$SYSTEMD_UNITS" ] && log "  (attempt $attempt) systemd units mentioning $VMID: $SYSTEMD_UNITS"
    sleep 5
done

if [ "$DESTROY_OK" != "true" ]; then
    log "ERROR: pct destroy $VMID failed after 8 attempts (~40s). Not attempting" \
        "to create a replacement until this is resolved (leftover container may be in a" \
        "bad state)."
    log "Last error: $DESTROY_ERR"

    # Diagnostics: capture what's actually holding the dataset busy, since a
    # fixed-duration retry not clearing it points at something that won't
    # resolve just by waiting longer (a leaked mount, not a slow teardown).
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

( handle_poststop ) >>"$STATE_DIR/hook.log" 2>&1 &
disown

exit 0
