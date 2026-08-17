#!/usr/bin/env bash
#
# Stops and destroys all gha-runner-<ID> LXC containers, without letting the
# ephemeral hookscript recreate them.
#
# gha_runner_hookscript.sh fires on post-stop for ANY stop of a container it's
# attached to - including the stop this script itself performs - and would
# otherwise recreate whatever gets torn down here. To prevent that, each
# container has its -hookscript property removed before it's stopped. This
# also stops (but does not wait to complete) any gha-runner-hook-* detached
# recreate jobs already in flight from a stop that happened moments before
# this script ran, so they don't race a fresh container into existence while
# cleanup is underway.
#
# Run as root on the Proxmox host. Destructive: any job currently running on
# a gha-runner-* container is killed mid-execution.
#
set -u

FORCE=false
[ "${1:-}" = "-y" ] && FORCE=true

log() {
    echo -e "\033[33m$*\033[0m"
}

STATE_DIR="/var/lib/gha-runner-hook"

# --- Preview what we're about to touch, and confirm unless -y was passed ---
CTIDS=$(pct list 2>/dev/null | awk 'NR>1 {print $1}')
TARGETS=""
for ctid in $CTIDS; do
    HOSTNAME=$(pct config "$ctid" 2>/dev/null | awk '/^hostname:/ {print $2}')
    case "$HOSTNAME" in
        gha-runner-*) TARGETS="$TARGETS $ctid" ;;
    esac
done

if [ -z "$TARGETS" ]; then
    log "-- No gha-runner-* containers found. Nothing to do."
    exit 0
fi

log "-- About to stop and destroy (--purge) these containers:$TARGETS"
if [ "$FORCE" != "true" ]; then
    read -r -p "Proceed? [y/N] " CONFIRM
    case "$CONFIRM" in
        y|Y|yes|YES) ;;
        *) log "-- Aborted."; exit 1 ;;
    esac
fi

# --- Stop any recreate job already in flight, so it can't win a race and
# spin a replacement back up while this script is working. ---
IN_FLIGHT=$(systemctl list-units --all --no-legend 2>/dev/null | awk '$1 ~ /^gha-runner-hook-/ {print $1}')
if [ -n "$IN_FLIGHT" ]; then
    log "-- Stopping in-flight recreate job(s): $IN_FLIGHT"
    for unit in $IN_FLIGHT; do
        systemctl stop "$unit" >/dev/null 2>&1 || true
    done
fi

# --- Repeat discovery+destroy a few passes: a hookscript invocation that
# had already read its per-repo config just before its container's
# -hookscript property gets cleared below can still finish recreating one
# replacement, so sweep again to catch it. ---
MAX_PASSES=5
for pass in $(seq 1 $MAX_PASSES); do
    CTIDS=$(pct list 2>/dev/null | awk 'NR>1 {print $1}')
    FOUND=""
    for ctid in $CTIDS; do
        HOSTNAME=$(pct config "$ctid" 2>/dev/null | awk '/^hostname:/ {print $2}')
        case "$HOSTNAME" in
            gha-runner-*) FOUND="$FOUND $ctid" ;;
        esac
    done

    if [ -z "$FOUND" ]; then
        log "-- No gha-runner-* containers remain (pass $pass)."
        break
    fi

    log "-- Pass $pass: found gha-runner-* container(s):$FOUND"
    for ctid in $FOUND; do
        log "   CT $ctid: detaching hookscript so it won't recreate on stop"
        pct set "$ctid" --delete hookscript >/dev/null 2>&1 || true

        STATUS=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
        if [ "$STATUS" = "running" ]; then
            log "   CT $ctid: stopping"
            pct stop "$ctid" >/dev/null 2>&1 || true
            for i in $(seq 1 10); do
                STATUS=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
                [ "$STATUS" != "running" ] && break
                sleep 1
            done
        fi

        log "   CT $ctid: destroying"
        if ! DESTROY_ERR=$(pct destroy "$ctid" --purge 2>&1); then
            log "   WARNING: pct destroy $ctid failed: $DESTROY_ERR"
        fi

        rm -f "$STATE_DIR/last_recreate-$ctid"
    done

    if [ "$pass" -eq "$MAX_PASSES" ]; then
        log "-- WARNING: reached $MAX_PASSES passes; some containers may still remain. Rerun this script or check manually with 'pct list'."
    fi
done

log "-- Done."
