#!/bin/bash
# step_11_chctrl.sh — Phase 4: compare S2D channel-control variants
#
# Что делает:
#   ставит модули, перезагружает драйвер, включает dec_init=1 и
#   dcsc_power=1, затем для трёх значений video_chctrl (0x2b0, 0x290,
#   0x2f0) снимает по 3 кадра и смотрит раскладку байтов в строке:
#   сколько данных в первой/второй половине строки, чередование байтов,
#   диапазон яркости.  Для каждого варианта делает PNG (первые 720 байт
#   каждой строки как яркость 720x576).
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   S2D/AVIS/DCSC — до reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot.
#
# Риск: один регистр CHx_CTRL на вариант; значения вендорские.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_chctrl.out
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# chctrl $(date -Is)"

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

for cc in 0x2b0 0x290 0x2f0; do
	RAW=$PROJ/logs/${STAMP}_cc${cc}.raw
	PGM=/tmp/cc${cc}.pgm
	PNG=$PROJ/logs/${STAMP}_cc${cc}.png

	echo "== chctrl $cc"
	echo "$cc" > "$PARAM/video_chctrl"
	timeout 10 v4l2-ctl -d /dev/video0 --set-input=0 \
		--stream-mmap --stream-count=3 --stream-to="$RAW"
	echo "exit=$?"

	python3 - "$RAW" "$PGM" <<'PY'
import sys
try:
    d = open(sys.argv[1], 'rb').read(829440)
except OSError:
    print("no file"); raise SystemExit
if not d:
    print("empty"); raise SystemExit
r0 = d[:1440]
print("nonzero 0..719:", sum(1 for b in r0[:720] if b),
      " 720..1439:", sum(1 for b in r0[720:] if b))
print("even:", sum(1 for b in r0[:720:2] if b),
      " odd:", sum(1 for b in r0[1:720:2] if b))
ys = d[:829440:2]
print("distinct", len(set(d)), "Y min/max", min(ys), max(ys),
      "Y distinct", len(set(ys)))
g = bytearray()
for y in range(576):
    g += d[y*1440:y*1440+720]
open(sys.argv[2], 'wb').write(b'P5\n720 576\n255\n' + bytes(g))
PY
	ffmpeg -v error -y -i "$PGM" "$PNG" 2>&1
	echo "png: $PNG"
done

echo "== done: $OUT"
