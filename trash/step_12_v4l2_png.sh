#!/bin/bash
# step_12_v4l2_png.sh — Phase 4: grab through V4L2 and decode to PNG
#
# Что делает:
#   ставит модули, перезагружает драйвер, включает dec_init=1,
#   dcsc_power=1, не трогает avis_fmt/video_chctrl/video_s2d_ctrl
#   (проверяются дефолты модуля: avis_fmt=0 — вендорский YUY2),
#   снимает 25 кадров через v4l2-ctl (штатный YUYV 720x576),
#   конвертирует 10-й кадр в PNG (первые кадры переходные после
#   инициализации АЦП) и печатает вердикт по U/V.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   S2D/AVIS/DCSC — до reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot.
#
# Риск: тот же, что в step_08..11 (уже проверен).

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_v4l2.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
RAW=$PROJ/logs/${STAMP}_v4l2.raw
SKIP=$PROJ/logs/${STAMP}_frame10.raw
PNG=$PROJ/logs/${STAMP}_frame10.png
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# v4l2 png $(date -Is)"

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

echo "== params"
echo 1 > "$PARAM/dec_init"
echo 1 > "$PARAM/dcsc_power"
# avis_fmt/video_chctrl/video_s2d_ctrl не трогаем: проверяем дефолты модуля
echo "avis_fmt=$(cat "$PARAM/avis_fmt") chctrl=$(cat "$PARAM/video_chctrl") s2d=$(cat "$PARAM/video_s2d_ctrl") packed=$(cat "$PARAM/packed_src")"
dmesg -w > "$KMSG" &
LOGGER=$!

echo "== capture 25 frames via V4L2"
timeout 15 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=25 --stream-to="$RAW"
echo "v4l2-ctl exit=$?"
sleep 1
kill "$LOGGER" 2>/dev/null

echo "== skip 10 frames, decode the next one"
tail -c +$((10 * 829440 + 1)) "$RAW" | head -c 829440 > "$SKIP"
ls -l "$RAW" "$SKIP" 2>&1
ffmpeg -v error -y -f rawvideo -pix_fmt yuyv422 -s 720x576 \
	-i "$SKIP" -frames:v 1 "$PNG" 2>&1
ls -l "$PNG" 2>&1

echo "== chroma check (frame 10)"
python3 - "$SKIP" <<'PY'
import collections, sys
d = open(sys.argv[1], 'rb').read()[:414720]
uv = collections.Counter(d[1::2])
tot = sum(uv.values())
gray = uv.get(0x80, 0)
print("U/V distinct=%d, exactly 0x80: %d / %d (%.1f%%)"
      % (len(uv), gray, tot, 100.0 * gray / tot))
print("top U/V:", uv.most_common(5))
print("VERDICT:", "GRAY/NO CHROMA" if len(uv) <= 2 else "COLOR OK")
PY

echo "== driver frame counter"
grep -E "saa7231 vfl: (first frame|stop)" "$KMSG" | tail -n 3

echo "== done: $OUT / $PNG"
