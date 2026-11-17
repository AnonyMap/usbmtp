#!/bin/sh
# usbmtp: share the Kindle's storage over MTP while KOReader keeps running.
# Usage (from KOReader's terminal or SSH):
#   sh /mnt/us/koreader/plugins/usbmtp.koplugin/mtp/mtp-start.sh
# Stop with:
#   sh /mnt/us/koreader/plugins/usbmtp.koplugin/mtp/mtp-stop.sh
#
# Env overrides:  KMTP_MODE=gffs  (skip configfs, use the legacy g_ffs gadget)
#                 KMTP_DRIVE=<image>  (instead of MTP, share that disk image as a
#                                      plain USB drive; see usbmtp_fat.lua)
#                 FORCE=1         (skip the kernel-version check)
#                 KMTP_WATCH_PID=<pid>  (stop automatically if that process dies;
#                                        the KOReader plugin passes its own pid)

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

mv -f "${KMTP_LOG}" "${KMTP_LOG}.1" 2>/dev/null # (keep the previous run's log: it may record a failed stop)
: >"${KMTP_LOG}" 2>/dev/null
log "=== usbmtp start ($(date)) version $(cat "${KMTP_SRC}/VERSION" 2>/dev/null) ==="
log "kernel $(uname -r), volumd: $(volumd_state), USB: $(udc_state)"

# ---------- preflight (nothing has been changed yet) ----------
[ "$(id -u)" = "0" ] || die "must run as root"

if [ "$(uname -r)" != "${EXPECTED_KERNEL}" ] && [ "${FORCE:-0}" != "1" ]; then
    die "This Kindle model isn't supported: it runs Linux $(uname -r), and the plugin is built for ${EXPECTED_KERNEL}. (Testers: FORCE=1 overrides this from a terminal.)"
fi

[ -d "/sys/class/udc/${UDC_NAME}" ] || die "This Kindle model isn't supported: its USB controller (${UDC_NAME}) wasn't found."
DRIVE="${KMTP_DRIVE:-}"
if [ -z "${DRIVE}" ]; then
    [ -f "${KMTP_SRC}/bin/umtprd" ] || die "The plugin's files are incomplete (bin/umtprd is missing). Reinstall the plugin."
    [ -f "${MODDIR}/function/usb_f_fs.ko" ] || die "This Kindle's software lacks the USB module MTP needs (usb_f_fs.ko). The USB drive connection may still work."
else
    case "${DRIVE}" in
        /mnt/base-us/*) ;;
        *) die "the drive image must be under /mnt/base-us (not the /mnt/us FUSE view): ${DRIVE}" ;;
    esac
    [ -f "${DRIVE}" ] || die "The USB drive's file is missing (${DRIVE}). Start again to recreate it."
    [ -f "${MODDIR}/legacy/g_mass_storage.ko" ] || die "This Kindle's software lacks the USB drive module (g_mass_storage.ko)."
fi

if [ -f "${KMTP_STATE}" ] || daemon_pid >/dev/null; then
    die "USB file transfer is already on, or was left on by a crash. Use Reset USB in the plugin's menu."
fi

case "$(volumd_state)" in
    running)
        die "The Kindle's own USB service is active, so the plugin can't take over USB. Start KOReader from KUAL (or exit KOReader and use the Kindle's normal USB mode). (volumd is running)"
        ;;
esac

if mod_loaded g_ether || mod_loaded g_ffs; then
    die "Another USB mode (such as USBNetwork) is on. Turn it off first."
fi

if gms_exporting; then
    die "The Kindle is shared as a USB drive right now. Eject it on the computer and unplug first."
fi

# Report the Kindle's own serial (as the stock USB mode does), so Calibre and other
# hosts can tell devices apart and remember per-device settings.
SERIAL="$(kindle_serial)"

# ---------- stage binaries on tmpfs ----------
mkdir -p "${KMTP_RUN}" || die "cannot create ${KMTP_RUN}"
rm -f "${KMTP_RECEIVED}"
if [ -z "${DRIVE}" ]; then
    : >"${KMTP_DLOG}"
    cp -f "${KMTP_SRC}/bin/umtprd" "${KMTP_RUN}/umtprd" || die "cannot copy umtprd"
    cp -f "${KMTP_SRC}/conf/umtprd.conf" "${KMTP_RUN}/umtprd.conf" || die "cannot copy config"
    VERSION="$(cat "${KMTP_SRC}/VERSION" 2>/dev/null)"
    sed -e "s/^serial .*/serial \"${SERIAL}\"/" \
        -e "s/^firmware_version .*/firmware_version \"usbmtp ${VERSION:-unknown}\"/" \
        "${KMTP_RUN}/umtprd.conf" >"${KMTP_RUN}/umtprd.conf.tmp" &&
        mv -f "${KMTP_RUN}/umtprd.conf.tmp" "${KMTP_RUN}/umtprd.conf" || die "cannot write config"
    chmod 755 "${KMTP_RUN}/umtprd"
fi
# Nothing has changed yet: if the state can't be saved (/var/tmp full), stop here.
state_set STARTED "$(date +%s)" || die "Not enough free memory to start (could not write to /var/tmp). Restart the Kindle and try again."

# Crash safety: if the caller (KOReader) dies without stopping us, stop ourselves.
start_watcher() {
    if [ -n "${KMTP_WATCH_PID:-}" ]; then
        sh "${KMTP_SRC}/mtp-watch.sh" "${KMTP_WATCH_PID}" >/dev/null 2>&1 </dev/null &
        echo $! >"${KMTP_WATCHER_PIDFILE}"
        log "watching process ${KMTP_WATCH_PID}"
    fi
}

# From here on, any failure must roll back.
fail() {
    log "ERROR: $*"
    [ -f "${KMTP_DLOG}" ] && { log "--- umtprd output ---"; tail -n 15 "${KMTP_DLOG}" | redact_serial | while read -r l; do log "  ${l}"; done; }
    redact_serial <"${KMTP_DLOG}" >"${KMTP_SRC}/umtprd-last.log" 2>/dev/null
    log "rolling back..."
    if teardown; then
        log "rolled back; stock USB restored"
    else
        log "rolled back, but stock USB was not restored. Reboot the Kindle."
    fi
    exit 1
}

# ---------- release the controller from the stock driver ----------
if mod_loaded g_mass_storage; then
    state_set GMS_WAS_LOADED yes || die "Not enough free memory to start (could not write to /var/tmp). Restart the Kindle and try again."
    save_gms_params || die "Not enough free memory to start (could not write to /var/tmp). Restart the Kindle and try again."
    log "unloading g_mass_storage"
    rmmod g_mass_storage || fail "could not unload g_mass_storage (in use?)"
else
    state_set GMS_WAS_LOADED no || die "Not enough free memory to start (could not write to /var/tmp). Restart the Kindle and try again."
fi

# ---------- or: share a disk image as a plain USB drive ----------
# The stock driver again, but backed by the image (a separate filesystem the
# Kindle doesn't have mounted) and under its own USB identity, so the computer
# doesn't take it for the Kindle's own storage. removable=1: ejecting it on the
# computer closes the image, which is how the plugin knows the books are in.
if [ -n "${DRIVE}" ]; then
    state_set MODE drive
    state_set DRIVE "${DRIVE}"
    log "sharing ${DRIVE} as a USB drive"
    # Recorded first, so a teardown after any interruption knows a loaded
    # g_mass_storage is ours (teardown checks it's actually loaded).
    state_set DRIVE_LOADED yes || fail "could not save the USB state"
    insmod "${MODDIR}/legacy/g_mass_storage.ko" file="${DRIVE}" removable=1 ro=0 stall=0 luns=1 \
        idVendor=0x1d6b idProduct=0x0104 iManufacturer=KOReader 'iProduct="Kindle drive"' \
        iSerialNumber="${SERIAL}" || fail "could not load the USB drive driver"
    LUN=""
    for _f in /sys/class/udc/${UDC_NAME}/device/gadget/lun*/file; do
        [ "$(cat "${_f}" 2>/dev/null)" = "${DRIVE}" ] && { LUN="${_f}"; break; }
    done
    if [ -z "${LUN}" ]; then
        for _f in $(find /sys/devices -path '*/gadget/lun*/file' 2>/dev/null); do
            [ "$(cat "${_f}" 2>/dev/null)" = "${DRIVE}" ] && { LUN="${_f}"; break; }
        done
    fi
    [ -n "${LUN}" ] || fail "the USB drive driver didn't take the image"
    state_set DRIVE_LUN "${LUN}"
    start_watcher
    log "USB drive is ON (USB: $(udc_state))"
    exit 0
fi

# ---------- build the MTP gadget ----------
setup_configfs() {
    load_mod libcomposite libcomposite.ko || return 1
    if ! mod_loaded usb_f_fs; then
        load_mod usb_f_fs function/usb_f_fs.ko || return 1
        state_set LOADED_USB_F_FS yes
    fi
    if ! grep -q " ${CFGFS} configfs" /proc/mounts; then
        mkdir -p "${CFGFS}" 2>/dev/null
        mount -t configfs none "${CFGFS}" || return 1
        state_set MOUNTED_CONFIGFS yes
    fi
    [ -d "${CFGFS}/usb_gadget" ] || { log "configfs has no usb_gadget directory"; return 1; }

    mkdir "${GADGET}" || return 1
    echo 0x1d6b >"${GADGET}/idVendor"
    echo 0x0100 >"${GADGET}/idProduct"
    echo 0x0200 >"${GADGET}/bcdUSB"
    mkdir "${GADGET}/strings/0x409" || return 1
    echo "${SERIAL}" >"${GADGET}/strings/0x409/serialnumber"
    echo "KOReader" >"${GADGET}/strings/0x409/manufacturer"
    echo "Kindle (MTP)" >"${GADGET}/strings/0x409/product"
    mkdir "${GADGET}/functions/ffs.mtp" || return 1
    mkdir "${GADGET}/configs/c.1" || return 1
    mkdir "${GADGET}/configs/c.1/strings/0x409" || return 1
    echo "MTP" >"${GADGET}/configs/c.1/strings/0x409/configuration"
    echo 500 >"${GADGET}/configs/c.1/MaxPower"
    ln -s "${GADGET}/functions/ffs.mtp" "${GADGET}/configs/c.1/" || return 1

    mkdir -p "${FFS_MNT}"
    mount -t functionfs mtp "${FFS_MNT}" || return 1
    return 0
}

setup_gffs() {
    if ! mod_loaded usb_f_fs; then
        load_mod usb_f_fs function/usb_f_fs.ko || return 1
        state_set LOADED_USB_F_FS yes
    fi
    load_mod g_ffs legacy/g_ffs.ko functions=mtp idVendor=0x1d6b idProduct=0x0100 iManufacturer=KOReader iProduct=Kindle-MTP iSerialNumber="${SERIAL}" || return 1
    mkdir -p "${FFS_MNT}"
    mount -t functionfs mtp "${FFS_MNT}" || return 1
    return 0
}

MODE="${KMTP_MODE:-configfs}"
if [ "${MODE}" = "configfs" ]; then
    log "setting up configfs MTP gadget"
    if ! setup_configfs; then
        log "configfs setup failed, cleaning up and trying legacy g_ffs"
        teardown_gadget || fail "could not clean up the half-built configfs gadget"
        MODE="gffs"
    fi
fi
if [ "${MODE}" = "gffs" ]; then
    log "setting up g_ffs MTP gadget"
    setup_gffs || fail "g_ffs setup failed"
fi
state_set MODE "${MODE}"

# ---------- start the responder ----------
log "starting umtprd"
cd "${KMTP_RUN}" || fail "cannot cd ${KMTP_RUN}"
# An ignored SIGHUP survives exec, so the daemon outlives the caller's terminal
# without needing nohup (not every BusyBox build has it).
trap '' HUP
./umtprd -conf ./umtprd.conf >"${KMTP_DLOG}" 2>&1 </dev/null &
echo $! >"${KMTP_PIDFILE}"
cd / || true

# umtprd writes its USB descriptors to ep0; the data endpoints appear once that worked.
i=0
while [ ! -e "${FFS_MNT}/ep1" ] && [ ${i} -lt 40 ]; do
    daemon_pid >/dev/null || fail "umtprd exited during startup"
    usleep 250000 2>/dev/null || sleep 1
    i=$((i + 1))
done
[ -e "${FFS_MNT}/ep1" ] || fail "umtprd never set up its USB endpoints"

# Anything in documents/ newer than this marker arrived over MTP. (umtprd never
# applies the computer's timestamps, so received files are always "new".)
: >"${KMTP_MARK}"
rm -f "${KMTP_RECEIVED}"

if [ "${MODE}" = "configfs" ]; then
    log "binding gadget to ${UDC_NAME}"
    echo "${UDC_NAME}" >"${GADGET}/UDC" || fail "could not bind gadget to ${UDC_NAME}"
fi

usleep 500000 2>/dev/null || sleep 1
daemon_pid >/dev/null || fail "umtprd died after binding"

start_watcher

log "MTP is ON (mode: ${MODE}, USB: $(udc_state))"
log "Plug in the cable if it isn't already. Keep the Kindle awake while copying."
log "When finished: sh ${KMTP_SRC}/mtp-stop.sh  (then unplug)"
