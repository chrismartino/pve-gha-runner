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
    pct destroy "$VMID" --purge >/dev/null 2>&1
    exit 0
fi

echo "$NOW" > "$LAST_RECREATE_FILE"

log "CT $VMID finished its job and powered off. Destroying and recreating."

if ! pct destroy "$VMID" --purge; then
    log "ERROR: pct destroy $VMID failed. Not attempting to create a replacement" \
        "until this is resolved (leftover container may be in a bad state)."
    exit 1
fi

if [ ! -x "$MAIN_SCRIPT_PATH" ]; then
    log "ERROR: $MAIN_SCRIPT_PATH not found or not executable. CT $VMID was destroyed" \
        "but no replacement was created. Fix MAIN_SCRIPT_PATH in this hookscript and" \
        "either rerun it by hand or wait for the next trigger."
    exit 1
fi

export EPHEMERAL_RUNNER=true
export GITHUB_APP_ID
export GITHUB_APP_PRIVATE_KEY_PATH
export OWNERREPO
[ -n "$EXTRA_INSTALL_SCRIPT" ] && export EXTRA_INSTALL_SCRIPT

# Run in the background: Proxmox expects hookscripts to return promptly, and
# while container creation itself is quick, we don't want a slow step (e.g.
# a stalled download) to make Proxmox think the hook itself hung.
nohup "$MAIN_SCRIPT_PATH" >>"$STATE_DIR/recreate.log" 2>&1 &
disown

log "Recreation started in the background (see $STATE_DIR/recreate.log)."
exit 0
