#!/bin/bash
# step_07_live_dump.sh — Phase 4: look at AVIS/S2D while streaming
#
# Что делает:
#   ставит модули, перезагружает драйвер, включает dec_init=1, запускает
#   поток через v4l2-ctl в фоне (без записи в файл) и, пока поток идёт,
#   читает регистры AVIS/S2D через dbg_avis.  Затем снимает поток и
#   показывает счётчик кадров из драйвера.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   регистры S2D/MMU и AVIS — до reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot (при D-state — только reboot).
#
# Риск: запись в AVIS (окно 0x200000..0x280000), как в step_04/06.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_live_dump.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# live dump $(date -Is)"

echo "== install modules"
install -m 644 "$PROJ/src/saa7231_core.ko" "$DEST/" || exit 1
install -m 644 "$PROJ/src/saa7231_drv.ko" "$DEST/" || exit 1
depmod -a "$KVER"

echo "== reload driver"
modprobe -r saa7231_drv 2>/dev/null
modprobe -r saa7231_core 2>/dev/null
modprobe saa7231_core || exit 1
modprobe saa7231_drv || exit 1
sleep 1

echo "== dec_init=1, start stream in background"
echo 1 > "$PARAM/dec_init"
dmesg -w > "$KMSG" &
LOGGER=$!
v4l2-ctl -d /dev/video0 --set-input=0 --stream-mmap --stream-count=1000 \
	>/dev/null 2>&1 &
VPID=$!
sleep 3

echo "== registers while streaming"
for off in 0x120000 0x120010 0x1200a0 0x1200a4 0x120fe0 0x120fe4 0x12c080 \
	   0x202330 0x202338 0x20233c 0x20239c 0x202410 0x202414 \
	   0x2033c0 0x2033c8 0x2033f4 0x203398 0x20339c; do
	echo "-- $off"
	echo "$off" > "$PARAM/dbg_avis"
	sleep 0.2
done

echo "== stop stream"
kill -TERM "$VPID" 2>/dev/null
sleep 2
kill "$LOGGER" 2>/dev/null

echo "== markers and register reads"
grep -E "saa7231 (vfl|avis|s2d):|saa7231 dbg_mmio" "$KMSG" | tail -n 60

echo "== dmesg tail"
dmesg | tail -n 20
echo "== done: $OUT"
