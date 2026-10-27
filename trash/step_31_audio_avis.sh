#!/bin/bash
# step_31_audio_avis.sh — Phase 5, шаг 40: маршрутизация АЦП из эталона Windows
#
# Что делает:
#   audio_init=1 + audio_rgu=1, плюс avis_adc_ref=1 (AVIS 0x14/0x20/0x24/0x28
#   берутся ровно как в logs/win_avis_run.txt) и avis_48=0xb71870 (вендор
#   держит бит 0x800, мы его гасили). Снимает 25 кадров с PNG (проверить,
#   что видео не сломалось) и читает AUDIO/STREAM.
#
# Что меняет: модули; регистры AVIS/AUDIO/AS2D/STREAM; RGU_RESET_CTRL1.
# Откат: reload драйвера либо reboot (все параметры по умолчанию 0/-1).
# Риск: записи в AVIS 0x14/0x20/0x24/0x28 — те же, что делает вендор.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_audio_avis.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
RAW=$PROJ/logs/${STAMP}_audio_avis.raw
SKIP=$PROJ/logs/${STAMP}_frame10.raw
PNG=$PROJ/logs/${STAMP}_frame10.png
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# audio avis reference $(date -Is)"

install -m 644 "$PROJ/src/saa7231_core.ko" "$DEST/" || exit 1
install -m 644 "$PROJ/src/saa7231_drv.ko" "$DEST/" || exit 1
depmod -a "$KVER"
modprobe -r saa7231_drv 2>/dev/null
modprobe -r saa7231_core 2>/dev/null
modprobe saa7231_core || exit 1
modprobe saa7231_drv || exit 1
sleep 1
echo 1 > "$PARAM/audio_init"
echo 1 > "$PARAM/audio_rgu"
echo 2 > "$PARAM/avis_adc_ref"
echo 1 > "$PARAM/adc_clk"
echo 0xb71870 > "$PARAM/avis_48"
echo "audio_init=$(cat "$PARAM/audio_init") rgu=$(cat "$PARAM/audio_rgu") adc_ref=$(cat "$PARAM/avis_adc_ref") adc_clk=$(cat "$PARAM/adc_clk") avis_48=$(cat "$PARAM/avis_48")"

dmesg -w > "$KMSG" &
LOGGER=$!

BEFORE=$(grep -c 'saa7231 audio: buf' "$KMSG")
timeout 20 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=30 --stream-to="$RAW"
echo "v4l2-ctl exit=$?"
sleep 1
echo "-- audio buffers: $(( $(grep -c 'saa7231 audio: buf' "$KMSG") - BEFORE ))"
grep "saa7231 audio: buf" "$KMSG" | tail -n 4

echo "== AUDIO / STREAM / AVIS routing"
for r in 0x280000:8 0x280010:8 0x280180:8 0x2801c0:8 0x12c100:8 0x201000:8; do
	echo "$r" > "$PARAM/dbg_dump"
	sleep 0.15
	grep "saa7231 dbg_dump bar0 ${r%%:*}" "$KMSG" | tail -n 1 | sed 's/.*bar0 //'
done
kill "$LOGGER" 2>/dev/null

echo "== video check"
tail -c +$((10 * 829440 + 1)) "$RAW" | head -c 829440 > "$SKIP"
ffmpeg -v error -y -f rawvideo -pix_fmt yuyv422 -s 720x576 \
	-i "$SKIP" -frames:v 1 "$PNG"
ls -l "$PNG" 2>&1
python3 - "$SKIP" <<'PY'
import collections, sys
d = open(sys.argv[1], 'rb').read()[:414720]
uv = collections.Counter(d[1::2])
print("U/V distinct=%d, 0x80=%d" % (len(uv), uv.get(0x80, 0)))
PY
echo "== done: $OUT / $PNG"
