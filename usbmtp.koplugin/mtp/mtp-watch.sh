#!/bin/sh
# usbmtp crash watcher: if the process that started MTP (KOReader) dies
# without stopping it, stop it ourselves. KOReader's launcher resumes Amazon's
# volumd right after KOReader exits, so volumd is paused again while we tear
# down, and resumed afterwards.
# Usage (started by mtp-start.sh):  sh mtp-watch.sh <pid-to-watch>

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

WATCH="$1"
[ -n "${WATCH}" ] || exit 0
trap '' HUP

# Once a second, with shell builtins only (this runs for the whole session on a
# single slow core): the process is gone when kill -0 fails, or it's a zombie
# (kill -0 still succeeds on one, so look at its state when we can read it).
alive() {
    kill -0 "${WATCH}" 2>/dev/null || return 1
    read -r _stat <"/proc/${WATCH}/stat" 2>/dev/null || return 0
    _rest="${_stat##*) }"          # (the process name, in parentheses, can contain spaces)
    [ "${_rest%% *}" != "Z" ]
}
while [ -f "${KMTP_STATE}" ] && alive; do
    sleep 1
done

if [ -f "${KMTP_STATE}" ]; then
    log "watcher: process ${WATCH} is gone but MTP is still on; stopping it"
    PAUSED_VOLUMD=""
    if [ "$(volumd_state)" = "running" ]; then
        PAUSED_VOLUMD="$(pidof volumd 2>/dev/null)"
        # shellcheck disable=SC2086
        [ -n "${PAUSED_VOLUMD}" ] && kill -STOP ${PAUSED_VOLUMD} 2>/dev/null && log "watcher: paused volumd during teardown"
    fi
    sh "${KMTP_SRC}/mtp-stop.sh" >/dev/null 2>&1
    if [ -n "${PAUSED_VOLUMD}" ]; then
        # Unless KOReader was started again meanwhile: its launcher paused volumd
        # for it, and waking it would let it take USB away from the new KOReader.
        if pidof luajit >/dev/null 2>&1; then
            log "watcher: KOReader is running again; leaving volumd paused for it"
        else
            # shellcheck disable=SC2086
            kill -CONT ${PAUSED_VOLUMD} 2>/dev/null
            log "watcher: resumed volumd"
        fi
    fi
fi
