#!/bin/bash
# step_16_s2d_fmt.sh [s2d_ctrl] [packed_src] — Phase 4: S2D output format (YUY2)
#
# Что делает:
#   ставит модули, перезагружает драйвер, включает dec_init=1, dcsc_power=1,
#   avis_fmt=0x00 (YUY2), video_chctrl=0x2b0 и video_s2d_ctrl (по умолчанию
#   0x7012c — вендорское значение FUN_00021cec для subtype 2).
#   Снимает два прохода:
#     1) raw_dump=1 + fill_aa=1 — сырые строки DMA (видно, пишет ли S2D
#        вторую половину строки);
#     2) обычный захват 20 кадров + PNG, с packed_src (по умолчанию 1).
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   S2D/AVIS/DCSC — до reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot.
#
# Риск: тот же, что в step_12..15 (проверен). Только чтение регистров.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
CTRL=${1:-0x7012c}
PACKED=${2:-1}
OUT=$PROJ/logs/${STAMP}_s2d_fmt.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
RAWR=$PROJ/logs/${STAMP}_rawpass.raw
RAW=$PROJ/logs/${STAMP}_normal.raw
PNG=$PROJ/logs/${STAMP}_normal.png
RAWPASS=$PROJ/logs/${STAMP}_rawpass.png
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# s2d fmt ctrl=$CTRL packed_src=$PACKED $(date -Is)"

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
echo 0 > "$PARAM/avis_fmt"
echo "$CTRL" > "$PARAM/video_s2d_ctrl"
echo "$PACKED" > "$PARAM/packed_src"
dmesg -w > "$KMSG" &
LOGGER=$!

echo "== raw pass: 6 frames, raw_dump=1 fill_aa=1"
echo 1 > "$PARAM/raw_dump"
echo 1 > "$PARAM/fill_aa"
timeout 12 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=6 --stream-to="$RAWR"
echo "raw pass exit=$?"
echo 0 > "$PARAM/fill_aa"
sleep 1

echo "== normal pass: 75 frames, raw_dump=0"
echo 0 > "$PARAM/raw_dump"
timeout 15 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=75 --stream-to="$RAW" &
VPID=$!
sleep 1.5

echo "== registers during stream"
for off in 0x120000 0x120004 0x120008 0x12000c 0x120010 \
	   0x120020 0x120024 0x120028 0x12002c 0x120030 0x120034 \
	   0x120040 0x120044 0x120048 0x12004c 0x120050 0x120054; do
	echo "$off" > "$PARAM/dbg_mmio"
	sleep 0.05
done
for off in 0x202048 0x202288 0x202290 0x2022a4 0x2022c0 0x202260 \
	   0x202330 0x202338 0x20233c 0x202398 0x20239c \
	   0x2033c0 0x2033c8 0x2033f4 0x203660; do
	echo "$off" > "$PARAM/dbg_avis"
	sleep 0.05
done
wait "$VPID"
echo "normal exit=$?"
sleep 1
kill "$LOGGER" 2>/dev/null

echo "== raw pass layout (whole 829440-byte DMA buffer)"
python3 - "$RAWR" <<'PY'
import collections, sys
size = 829440
d = open(sys.argv[1], 'rb').read()
n = len(d) // size
print("raw frames:", n, "bytes:", len(d))
if n < 3:
    sys.exit(0)
fr = d[2 * size:3 * size]
for r in (0, 1, 100, 287, 288, 300, 575):
    line = fr[r * 1440:(r + 1) * 1440]
    a, b = line[:720], line[720:]
    ca, cb = collections.Counter(a), collections.Counter(b)
    print("line %3d: first distinct=%3d top=%s | second distinct=%3d top=%s"
          % (r, len(ca), ca.most_common(2), len(cb), cb.most_common(2)))
    print("   first32=%s" % line[:32].hex(' '))
    print("   mid32  =%s" % line[704:736].hex(' '))
for blk in (0, 288):
    part = fr[blk * 1440:(blk + 288) * 1440]
    print("block %3d..%3d: aa=%d/%d" % (blk, blk + 287, part.count(0xaa), len(part)))
PY

echo "== normal layout (YUY2 720x576)"
python3 - "$RAW" <<'PY'
import collections, sys
size = 829440
d = open(sys.argv[1], 'rb').read()
n = len(d) // size
print("frames:", n, "bytes:", len(d))
if n < 11:
    sys.exit(0)
fr = d[10 * size:11 * size]
first, second = collections.Counter(), collections.Counter()
for r in range(576):
    line = fr[r * 1440:(r + 1) * 1440]
    first.update(line[:720]); second.update(line[720:])
print("first  half: distinct=%d top=%s" % (len(first), first.most_common(3)))
print("second half: distinct=%d top=%s" % (len(second), second.most_common(3)))
even = collections.Counter(fr[0::2])
odd = collections.Counter(fr[1::2])
print("Y positions: distinct=%d top=%s" % (len(even), even.most_common(3)))
print("U/V positions: distinct=%d top=%s" % (len(odd), odd.most_common(3)))
PY
ffmpeg -v error -y -f rawvideo -pix_fmt yuyv422 -s 720x576 \
	-i "$RAW" -frames:v 1 "$PNG" 2>&1
ffmpeg -v error -y -f rawvideo -pix_fmt yuyv422 -s 720x576 \
	-i "$RAWR" -frames:v 1 "$RAWPASS" 2>&1
ls -l "$PNG" "$RAWPASS" 2>&1

echo "== driver log"
grep -E "saa7231 (s2d|vfl):" "$KMSG" | tail -n 20

echo "== done: $OUT / $PNG / $RAWPASS"
