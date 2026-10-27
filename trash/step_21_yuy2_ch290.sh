#!/bin/bash
# step_21_yuy2_ch290.sh — Phase 4, шаг 30: YUY2 с CHx_CTRL=0x290
#
# Что делает:
#   ставит модули, перезагружает драйвер, включает dec_init=1, dcsc_power=1,
#   avis_fmt=0x10 (YUY2), video_chctrl=0x290 (вместо вендорского 0x2b0),
#   video_s2d_ctrl=0x7012c, adc_clk=0, adc_start=0.
#   Снимает 6 кадров сырым DMA (raw_dump=1, fill_aa=1) и считает, перестали
#   ли U/V быть ровно 0x80.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   AVIS/S2D — до reload/reboot.
#
# Откат:
#   sudo trash/step_19_adc_clk.sh   (вернёт CHx_CTRL=0x2b0)
#   либо reboot.
#
# Риск: тот же, что в step_12..20 (проверен). Только чтение регистров.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_yuy2_ch290.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
RAWR=$PROJ/logs/${STAMP}_yuy2_ch290.raw
PNG=$PROJ/logs/${STAMP}_yuy2_ch290.png
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# yuy2 avis_fmt=0x10 ctrl=0x7012c chctrl=0x290 $(date -Is)"

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
echo 0 > "$PARAM/adc_clk"
echo 0 > "$PARAM/adc_start"
echo 0x290 > "$PARAM/video_chctrl"
echo 0x10 > "$PARAM/avis_fmt"
echo 0x7012c > "$PARAM/video_s2d_ctrl"
echo 1 > "$PARAM/packed_src"
echo 1 > "$PARAM/raw_dump"
echo 1 > "$PARAM/fill_aa"

dmesg -w > "$KMSG" &
LOGGER=$!

echo "== raw pass: 6 frames, YUY2 CHx_CTRL=0x290"
timeout 12 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=6 --stream-to="$RAWR"
echo "raw pass exit=$?"
echo 0 > "$PARAM/fill_aa"

echo "== registers"
for off in 0x120000 0x120004 0x120010 0x202288 0x202290 0x2022a4 \
	   0x2022c0 0x202260 0x202338 0x20233c 0x2033c0 0x2033c8 \
	   0x2033f4 0x203660; do
	echo "$off" > "$PARAM/dbg_mmio"
	sleep 0.05
done
kill "$LOGGER" 2>/dev/null

echo "== YUY2 analysis"
python3 - "$RAWR" <<'PY'
import collections, sys
size = 829440
d = open(sys.argv[1], 'rb').read()
n = len(d) // size
print("frames:", n, "bytes:", len(d))
if n < 3:
    sys.exit(0)
fr = d[2 * size:3 * size]
# raw_dump gives one field (288 lines, 414720 bytes); the rest is fill_aa
real = fr[:414720]
print("first32:", fr[:32].hex(' '))
print("aa bytes in real field:", real.count(0xaa), "/", len(real))
y = collections.Counter(real[0::2])
uv = collections.Counter(real[1::2])
print("Y  distinct=%d top=%s" % (len(y), y.most_common(5)))
print("UV distinct=%d top=%s" % (len(uv), uv.most_common(5)))
print("UV exactly 0x80: %d / %d" % (uv.get(0x80, 0), sum(uv.values())))
print("UV != 0x80: %d" % (sum(v for k, v in uv.items() if k != 0x80)))
PY

dd if="$RAWR" of="${RAWR%.raw}_frame2.raw" bs=829440 skip=2 count=1 status=none
ffmpeg -v error -y -f rawvideo -pix_fmt yuyv422 -s 720x576 \
	-i "${RAWR%.raw}_frame2.raw" -frames:v 1 "$PNG" 2>&1
ls -l "$PNG" 2>&1

echo "== driver log"
grep -E "saa7231 (s2d|vfl|avis|cgu):" "$KMSG" | tail -n 20

echo "== done: $OUT / $PNG"
