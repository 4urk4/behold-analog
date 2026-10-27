#!/bin/bash
# step_08_dcsc.sh — Phase 4: DIGOUT timing fix + DCSC power write
#
# Что делает:
#   ставит модули, перезагружает драйвер, включает dec_init=1 и
#   dcsc_power=1 (вендорский старт пишет DCSC=0x16), запускает поток в
#   фоне и читает регистры AVIS/S2D во время потока.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   S2D/MMU, AVIS и DCSC (0x2ff000) — до reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot (при D-state — только reboot).
#
# Риск: ПЕРВАЯ запись в DCSC (0x2ff000), вендор пишет туда 0x16 при каждом
#   старте. Известная ловушка — 0x300000, сюда не попадаем. При зависании —
#   только reset.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_dcsc.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# dcsc $(date -Is)"

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

echo "== dec_init=1 dcsc_power=1"
echo 1 > "$PARAM/dec_init"
echo 1 > "$PARAM/dcsc_power"
dmesg -w > "$KMSG" &
LOGGER=$!
v4l2-ctl -d /dev/video0 --set-input=0 --stream-mmap --stream-count=1000 \
	>/dev/null 2>&1 &
VPID=$!
sleep 3

echo "== registers while streaming"
for off in 0x120000 0x120010 0x1200a0 0x1200a4 0x20233c 0x20239c \
	   0x2033c0 0x2033c8 0x2033cc 0x2033f4 0x203398; do
	echo "-- $off"
	echo "$off" > "$PARAM/dbg_avis"
	sleep 0.2
done

echo "== stop stream"
kill -TERM "$VPID" 2>/dev/null
sleep 2
kill "$LOGGER" 2>/dev/null

echo "== markers"
grep -E "saa7231 (vfl|avis|s2d):|saa7231 dbg_mmio" "$KMSG" | tail -n 40

echo "== dmesg tail"
dmesg | tail -n 15
echo "== done: $OUT"
