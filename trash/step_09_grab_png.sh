#!/bin/bash
# step_09_grab_png.sh — Phase 4: grab real frames and decode one to PNG
#
# Что делает:
#   ставит модули, перезагружает драйвер, включает dec_init=1 и
#   dcsc_power=1, снимает 25 кадров в raw-файл, конвертирует первый кадр
#   в PNG через ffmpeg.  Регистры не пишет (кроме обычного старта потока).
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   S2D/AVIS/DCSC — до reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot.
#
# Риск: тот же, что в step_08 (AVIS + DCSC + S2D), уже проверен.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_grab.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
RAW=$PROJ/logs/${STAMP}_frame.raw
PNG=$PROJ/logs/${STAMP}_frame.png
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# grab $(date -Is)"

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

echo "== capture 25 frames"
timeout 15 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=25 --stream-to="$RAW"
echo "v4l2-ctl exit=$?"
sleep 1
kill "$LOGGER" 2>/dev/null

echo "== frame file"
ls -l "$RAW" 2>&1
echo -n "non-zero bytes in first frame: "
head -c 829440 "$RAW" | tr -d '\0' | wc -c

echo "== decode first frame to PNG"
ffmpeg -v error -y -f rawvideo -pix_fmt yuyv422 -s 720x576 \
	-i "$RAW" -frames:v 1 "$PNG" 2>&1
ls -l "$PNG" 2>&1

echo "== driver frame counter"
grep -E "saa7231 vfl: (first frame|stop)" "$KMSG" | tail -n 5

echo "== done: $OUT / $PNG"
