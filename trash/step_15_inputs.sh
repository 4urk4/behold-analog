#!/bin/bash
# step_15_inputs.sh — Phase 4: the same base mode on every crossbar input (0..3)
#
# Что делает:
#   грузит модули один раз (dec_init=1, dcsc_power=1, raw_dump=1, fill_aa=1)
#   и по очереди прогоняет набор конфигураций AVIS: обычную, subtype 0,
#   альтернативный DIGOUT, FUN_000248e4(1), их комбинацию, клок АЦП и
#   аудио-PLL.  Для каждой — 10 кадров, разбор половин строки и PNG
#   (_luma/_chroma) в logs/.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   S2D/AVIS/DCSC/CGU — до reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot.
#
# Риск: те же записи, что в step_13 (проверены по отдельности).

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_inputs.out
KMSG=$PROJ/logs/${STAMP}_inputs_kmsg.out
PARAM=/sys/module/saa7231_core/parameters

# name FMT PLL DIG C0 SON ADC
CFGS=(
	"in0_composite 0"
	"in1_svideo    1"
	"in2_ypbpr     2"
	"in3_rgb       3"
)

exec > >(tee -a "$OUT") 2>&1
echo "# inputs $(date -Is)"

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

echo 1 > "$PARAM/dec_init"
echo 1 > "$PARAM/dcsc_power"
echo 0x2b0 > "$PARAM/video_chctrl"
echo 1 > "$PARAM/raw_dump"
echo 1 > "$PARAM/fill_aa"

for cfg in "${CFGS[@]}"; do
	set -- $cfg
	NAME=$1 IN=$2
	echo
	echo "=== $NAME  input=$IN"
	echo 0 > "$PARAM/avis_fmt"
	echo 0x70 > "$PARAM/avis_c0"
	echo 0 > "$PARAM/audio_pll"
	echo 0 > "$PARAM/digout_alt"
	echo 0 > "$PARAM/stream_on"
	echo 0 > "$PARAM/adc_clk"

	RAW=$PROJ/logs/${STAMP}_${NAME}.raw
	timeout 15 v4l2-ctl -d /dev/video0 --set-input="$IN" \
		--stream-mmap --stream-count=10 --stream-to="$RAW" >/dev/null 2>&1
	echo "v4l2-ctl exit=$?"

	timeout 20 python3 - "$RAW" "$PROJ/logs/${STAMP}_${NAME}" <<'PY'
import collections, sys
size = 829440
try:
    d = open(sys.argv[1], 'rb').read()
except OSError:
    d = b""
n = len(d) // size
print("frames:", n)
if n < 6:
    print("RESULT: no frames")
    sys.exit(0)
fr = d[5 * size:6 * size]
first, second = collections.Counter(), collections.Counter()
luma, chroma = bytearray(720 * 576), bytearray(720 * 576)
for r in range(576):
    line = fr[r * 1440:(r + 1) * 1440]
    first.update(line[:720]); second.update(line[720:])
    luma[r * 720:(r + 1) * 720] = line[:720]
    chroma[r * 720:(r + 1) * 720] = line[720:]
open(sys.argv[2] + "_luma.gray", 'wb').write(luma)
open(sys.argv[2] + "_chroma.gray", 'wb').write(chroma)
print("first  half: distinct=%d top=%s" % (len(first), first.most_common(2)))
print("second half: distinct=%d top=%s" % (len(second), second.most_common(2)))
PY
	for H in luma chroma; do
		ffmpeg -v error -y -f rawvideo -pix_fmt gray -s 720x576 \
			-i "$PROJ/logs/${STAMP}_${NAME}_$H.gray" \
			"$PROJ/logs/${STAMP}_${NAME}_$H.png" > /dev/null 2>&1 || true
	done
done

echo
echo "== done: $OUT"
ls -l "$PROJ/logs/${STAMP}"_*_luma.png 2>/dev/null
