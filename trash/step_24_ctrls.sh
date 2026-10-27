#!/bin/bash
# step_24_ctrls.sh — Phase 4, шаг 34: регулировки V4L2 (brightness/contrast/
#                    saturation/hue/sharpness)
#
# Что делает:
#   ставит модули, перезагружает драйвер (конфиг из modprobe.d как есть),
#   печатает --list-ctrls, снимает 25 кадров с дефолтными контролами (A),
#   затем ставит brightness=0x20 и saturation=0x60 и снимает ещё 25 (B).
#   Сравнивает среднюю яркость кадров: регулировки должны её менять.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   значения контролов (только в RAM, до reload/reboot).
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot.
#
# Риск: записи в AVIS 0x2270/0x2274/0x2280/0x2284/0x2260 — те же
# регистры, что вендор крутит из VideoProcAmp. Только video-ветка.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_ctrls.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
RAW=$PROJ/logs/${STAMP}_ctrls.raw
RAWA=$PROJ/logs/${STAMP}_ctrlA.raw
RAWB=$PROJ/logs/${STAMP}_ctrlB.raw
PNGA=$PROJ/logs/${STAMP}_ctrlA.png
PNGB=$PROJ/logs/${STAMP}_ctrlB.png
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# v4l2 controls $(date -Is)"

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
echo "dec_init=$(cat "$PARAM/dec_init") dcsc_power=$(cat "$PARAM/dcsc_power")"

echo "== list controls"
v4l2-ctl -d /dev/video0 --list-ctrls

dmesg -w > "$KMSG" &
LOGGER=$!

cap() {	# cap <raw>
	timeout 15 v4l2-ctl -d /dev/video0 --set-input=0 \
		--stream-mmap --stream-count=25 --stream-to="$1"
	echo "v4l2-ctl exit=$?"
}

echo "== A: defaults"
cap "$RAWA"
echo "== B: brightness=0x20 saturation=0x60 hue=0x40"
v4l2-ctl -d /dev/video0 --set-ctrl=brightness=0x20,saturation=0x60,hue=0x40
v4l2-ctl -d /dev/video0 --list-ctrls | grep -E 'brightness|saturation|hue'
cap "$RAWB"
sleep 1
kill "$LOGGER" 2>/dev/null

# frame 10 of each capture
tail -c +$((10 * 829440 + 1)) "$RAWA" | head -c 829440 > "$PROJ/logs/${STAMP}_ctrlA_frame10.raw"
tail -c +$((10 * 829440 + 1)) "$RAWB" | head -c 829440 > "$PROJ/logs/${STAMP}_ctrlB_frame10.raw"
ffmpeg -v error -y -f rawvideo -pix_fmt yuyv422 -s 720x576 \
	-i "$PROJ/logs/${STAMP}_ctrlA_frame10.raw" -frames:v 1 "$PNGA"
ffmpeg -v error -y -f rawvideo -pix_fmt yuyv422 -s 720x576 \
	-i "$PROJ/logs/${STAMP}_ctrlB_frame10.raw" -frames:v 1 "$PNGB"
ls -l "$PNGA" "$PNGB" 2>&1

echo "== brightness/U-V check"
python3 - "$PROJ/logs/${STAMP}_ctrlA_frame10.raw" \
	  "$PROJ/logs/${STAMP}_ctrlB_frame10.raw" <<'PY'
import collections, sys

def stats(path):
	d = open(path, 'rb').read()[:414720]
	y = d[0::2]
	uv = collections.Counter(d[1::2])
	return sum(y) / len(y), len(uv)

ya, uva = stats(sys.argv[1])
yb, uvb = stats(sys.argv[2])
print("A: mean luma %.1f, U/V distinct %d" % (ya, uva))
print("B: mean luma %.1f, U/V distinct %d" % (yb, uvb))
print("delta luma: %+.1f" % (yb - ya))
print("VERDICT:", "CONTROLS WORK" if abs(yb - ya) > 8 else "NO EFFECT")
PY

echo "== driver log"
grep -E "saa7231 (vfl|avis):" "$KMSG" | tail -n 8

echo "== done: $OUT / $PNGA / $PNGB"
