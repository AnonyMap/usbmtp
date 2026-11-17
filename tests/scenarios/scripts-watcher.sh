P=/tmp/kmtp-test/plugin/usbmtp.koplugin/mtp
sleep 60 & KO=$!
KMTP_WATCH_PID=$KO sh $P/mtp-start.sh | grep "MTP is ON"
echo "watcher pid file: $(cat /var/tmp/kmtp/watcher.pid 2>/dev/null)"
# (KOReader's launcher resumes volumd as soon as KOReader exits)
[ -e /tmp/kmtp-test/fake/launcher_resumes_volumd ] && echo "999 (volumd) S 1 1" >/tmp/kmtp-test/fake/proc/999/stat
kill $KO; wait $KO 2>/dev/null
sleep 4
grep "watcher:" $P/mtp.log
echo "-- state: $(ls /var/tmp/kmtp/state 2>/dev/null || echo gone)"
echo "-- modules: $(cut -d' ' -f1 /proc/modules | tr '\n' ' ')"
