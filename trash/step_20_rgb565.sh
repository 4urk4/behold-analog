#!/bin/bash
# step_20_rgb565.sh — Phase 4, шаг 29: проверка выходного тракта AVIS в RGB565
#
# Что делает:
#   ставит модули, перезагружает драйвер, включает dec_init=1, dcsc_power=1,
#   avis_fmt=0x38 (RGB565), video_chctrl=0x290, video_s2d_ctrl=0xff01002c
#   (вендорские значения FUN_00021cec для subtype 7), adc_clk=0, adc_start=0.
#   Снимает 6 кадров сырым DMA (raw_dump=1, fill_aa=1), конвертирует один
#   кадр как RGB565 и считает, есть ли вообще разница между R/G/B.
#
# Перед запуском открой на мониторе в кадре гарантированно цветной фон
# (например, красный на весь экран) — иначе серый кадр ничего не докажет.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   AVIS/S2D — до reload/reboot.
#
# Откат:
#   sudo trash/step_19_adc_clk.sh   (вернёт YUY2)
#   либо reboot.
#
# Риск: тот же, что в step_12..19 (проверен). Только чтение регистров.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_rgb565.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
RAWR=$PROJ/logs/${STAMP}_rgb565.raw
PNG=$PROJ/logs/${STAMP}_rgb565.png
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# rgb565 avis_fmt=0x38 ctrl=0xff01002c chctrl=0x290 $(date -Is)"

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
echo 0x38 > "$PARAM/avis_fmt"
echo 0xff01002c > "$PARAM/video_s2d_ctrl"
echo 1 > "$PARAM/packed_src"
echo 1 > "$PARAM/raw_dump"
echo 1 > "$PARAM/fill_aa"

dmesg -w > "$KMSG" &
LOGGER=$!

echo "== raw pass: 6 frames, RGB565"
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

echo "== RGB565 analysis (DMA buffer, whole frame)"
python3 - "$RAWR" <<'PY'
import collections, sys
size = 829440
d = open(sys.argv[1], 'rb').read()
n = len(d) // size
print("frames:", n, "bytes:", len(d))
if n < 3:
    sys.exit(0)
fr = d[2 * size:3 * size]
print("first32:", fr[:32].hex(' '))
print("aa bytes in frame:", fr.count(0xaa), "/", len(fr))

def c8(v):
    return (v << 3) | (v >> 2)

hist = collections.Counter()
diff = 0
mx = [0, 0, 0]
mn = [255, 255, 255]
sums = [0, 0, 0]
npix = 0
for i in range(0, len(fr) - 1, 2):
    v = fr[i] | (fr[i + 1] << 8)
    if v == 0xaaaa:          # untouched fill_aa area, not a real pixel
        continue
    r = c8((v >> 11) & 0x1f)
    g = c8((v >> 5) & 0x3f)
    b = c8(v & 0x1f)
    sums[0] += r; sums[1] += g; sums[2] += b
    mx[0] = max(mx[0], r); mx[1] = max(mx[1], g); mx[2] = max(mx[2], b)
    mn[0] = min(mn[0], r); mn[1] = min(mn[1], g); mn[2] = min(mn[2], b)
    if max(r, g, b) - min(r, g, b) > 8:
        diff += 1
    hist[(r >> 4, g >> 4, b >> 4)] += 1
    npix += 1
print("real pixels (non-0xaaaa):", npix)
if not npix:
    sys.exit(0)
print("R min/max/avg: %d %d %.1f" % (mn[0], mx[0], sums[0] / npix))
print("G min/max/avg: %d %d %.1f" % (mn[1], mx[1], sums[1] / npix))
print("B min/max/avg: %d %d %.1f" % (mn[2], mx[2], sums[2] / npix))
print("pixels with channel diff > 8: %d / %d (%.2f%%)"
      % (diff, npix, 100.0 * diff / npix))
print("top 8 (r>>4,g>>4,b>>4):", hist.most_common(8))
PY

dd if="$RAWR" of="${RAWR%.raw}_frame2.raw" bs=829440 skip=2 count=1 status=none
ffmpeg -v error -y -f rawvideo -pix_fmt rgb565le -s 720x576 \
	-i "${RAWR%.raw}_frame2.raw" -frames:v 1 "$PNG" 2>&1
ls -l "$PNG" 2>&1

echo "== driver log"
grep -E "saa7231 (s2d|vfl|avis|cgu):" "$KMSG" | tail -n 20

echo "== done: $OUT / $PNG"
