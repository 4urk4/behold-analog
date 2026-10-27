#!/bin/bash
# step_13_chroma.sh [avis_fmt] — Phase 4: enable 16-bit AVIS output, check chroma
#
# Что делает:
#   ставит модули, перезагружает драйвер, включает dec_init=1,
#   dcsc_power=1, video_chctrl=0x2b0 и avis_fmt (по умолчанию 0 —
#   YUY2-ветка FUN_00023ff4; 0x10 — это UYVY), снимает 20 кадров
#   через v4l2-ctl и печатает разбор половин строк DMA.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   S2D/AVIS/DCSC — до reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot.
#
# Риск: тот же, что в step_08..12 (проверен).

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
FMT=${1:-0x00}
PLL=${2:-0}
DIG=${3:-0}
AA=${4:-0}
C0=${5:-0x70}
SON=${6:-0}
ADC=${7:-0}
OUT=$PROJ/logs/${STAMP}_chroma.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
RAW=$PROJ/logs/${STAMP}_chroma.raw
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# chroma fmt=$FMT pll=$PLL digout=$DIG fill_aa=$AA c0=$C0 stream_on=$SON adc_clk=$ADC $(date -Is)"

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
echo 0x2b0 > "$PARAM/video_chctrl"
echo "$FMT" > "$PARAM/avis_fmt"
echo 1 > "$PARAM/raw_dump"
echo "$PLL" > "$PARAM/audio_pll"
echo "$DIG" > "$PARAM/digout_alt"
echo "$AA" > "$PARAM/fill_aa"
echo "$C0" > "$PARAM/avis_c0"
echo "$SON" > "$PARAM/stream_on"
echo "$ADC" > "$PARAM/adc_clk"
dmesg -w > "$KMSG" &
LOGGER=$!

echo "== capture 20 frames"
timeout 15 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=20 --stream-to="$RAW"
echo "v4l2-ctl exit=$?"
sleep 1

echo "== registers (dbg_avis, read after stop)"
for off in 0x202330 0x202338 0x20233c 0x202398 0x20239c 0x202280 0x202288 \
	   0x202290 0x202294 0x2022a4 0x2022c0 0x2022c4 0x202260 \
	   0x202410 0x202414 0x2033c0 0x2033c8 0x2033f4; do
	echo "$off" > "$PARAM/dbg_avis"
	sleep 0.1
done
sleep 1
kill "$LOGGER" 2>/dev/null

echo "== line layout + PNG (field 10, 576 lines x 1440 bytes)"
python3 - "$RAW" "$PROJ/logs/${STAMP}_luma.gray" "$PROJ/logs/${STAMP}_chroma.gray" <<'PY'
import collections, sys
size = 829440
d = open(sys.argv[1], 'rb').read()
n = len(d) // size
print("frames:", n, "bytes:", len(d))
if n < 11:
    sys.exit(0)
fr = d[10 * size:11 * size]
first, second = collections.Counter(), collections.Counter()
luma, chroma = bytearray(720 * 576), bytearray(720 * 576)
for r in range(576):
    line = fr[r * 1440:(r + 1) * 1440]
    first.update(line[:720]); second.update(line[720:])
    luma[r * 720:(r + 1) * 720] = line[:720]
    chroma[r * 720:(r + 1) * 720] = line[720:]
open(sys.argv[2], 'wb').write(luma)
open(sys.argv[3], 'wb').write(chroma)
print("first  half: distinct=%d top=%s" % (len(first), first.most_common(3)))
print("second half: distinct=%d top=%s" % (len(second), second.most_common(3)))
PY
for H in luma chroma; do
	ffmpeg -v error -y -f rawvideo -pix_fmt gray -s 720x576 \
		-i "$PROJ/logs/${STAMP}_$H.gray" "$PROJ/logs/${STAMP}_$H.png"
done
ls -l "$PROJ/logs/${STAMP}_luma.png" "$PROJ/logs/${STAMP}_chroma.png"

echo "== avis registers"
grep -E "dbg_avis|dbg_mmio" "$KMSG" | tail -n 25

echo "== done: $OUT"
