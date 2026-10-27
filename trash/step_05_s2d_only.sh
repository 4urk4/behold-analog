#!/bin/bash
# step_05_s2d_only.sh — Phase 4: isolate the hang (S2D/MMU only, no AVIS)
#
# Что делает:
#   ставит модули с маркерами (pr_info в xs2dtl и vfl), перезагружает
#   драйвер, оставляет dec_init=0 (AVIS не программируется) и пытается
#   принять 1 кадр с таймаутом 10 с.  Параллельно пишет ядерный лог в
#   файл, чтобы при зависании было видно последний маркер.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   регистры S2D/MMU — до reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot (при D-state — только reboot).
#
# Риск: зависание процесса в D-state (как в step_04), машина при этом
#   жива; лечится перезагрузкой.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_s2d_only.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
RAW=$PROJ/logs/${STAMP}_frame.raw
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# s2d only $(date -Is)"

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

echo "== dec_init stays 0"
cat "$PARAM/dec_init"

echo "== kernel log to $KMSG"
dmesg -w > "$KMSG" &
LOGGER=$!
sleep 1

echo "== stream 1 frame (S2D only), 10s timeout"
timeout --kill-after=5 10 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=1 --stream-to="$RAW"
echo "v4l2-ctl exit=$?"
sleep 1
kill "$LOGGER" 2>/dev/null

echo "== marker tail (from kmsg file)"
tail -n 40 "$KMSG" 2>&1

for off in 0x120000 0x12000c 0x1200a0 0x1200a4 0x120fd8 0x120fdc 0x120ffc; do
	echo "== read $off ($(date +%H:%M:%S))"
	sync
	echo "$off" > "$PARAM/dbg_avis"
	sync
	sleep 1
done

echo "== frame file"
if [ -f "$RAW" ]; then
	ls -l "$RAW"
else
	echo "no frame file"
fi

echo "== dmesg tail"
dmesg | tail -n 60
echo "== done: $OUT"
