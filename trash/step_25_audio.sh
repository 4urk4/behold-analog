#!/bin/bash
# step_25_audio.sh — Phase 5, шаг 35: аналоговый звук (AUDIO + AS2D_LOCAL)
#
# Что делает:
#   ставит модули, перезагружает драйвер, включает audio_init=1 и
#   снимает 25 кадров видео — при старте потока драйвер программирует
#   блок AUDIO (FUN_000260a0) и запускает AS2D_LOCAL рядом с видео.
#   Каждый готовый аудиобуфер считает статистику s16 и пишет в dmesg.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   регистры блока AUDIO (0x280000) — до reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot. audio_init по умолчанию 0 — после ребута аудио-блок
#   драйвер не трогает вообще.
#
# Риск: записи в AUDIO — та же последовательность, что вендор делает при
# старте аналогового захвата. Видео не затрагивает.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_audio.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
RAW=$PROJ/logs/${STAMP}_audio.raw
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# analog audio $(date -Is)"

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
echo 1 > "$PARAM/audio_init"
echo 0 > "$PARAM/audio_input"
echo 0 > "$PARAM/audio_rate"
echo "dec_init=$(cat "$PARAM/dec_init") dcsc_power=$(cat "$PARAM/dcsc_power") audio_init=$(cat "$PARAM/audio_init") input=$(cat "$PARAM/audio_input") rate=$(cat "$PARAM/audio_rate")"

dmesg -w > "$KMSG" &
LOGGER=$!

cap() {	# cap <tag>
	echo "== capture 25 video frames (audio starts with the stream)"
	timeout 20 v4l2-ctl -d /dev/video0 --set-input=0 \
		--stream-mmap --stream-count=25 --stream-to="$RAW"
	echo "v4l2-ctl exit=$?"
	sleep 2
	echo "-- audio lines for $1:"
	grep "saa7231 audio: buf" "$KMSG" | tail -n 4
	NOW=$(grep -c 'saa7231 audio: buf' "$KMSG")
	echo "-- buffers for $1: $((NOW - PREV))"
	PREV=$NOW
}
PREV=0

# три гипотезы за один прогон; каждая — свой код стандарта / индекс входа
try() {	# try <std> <input> <tag>
	echo 0 > "$PARAM/audio_rgu"
	echo "$1" > "$PARAM/audio_std"
	echo "$2" > "$PARAM/audio_input"
	cap "$3 (std=$1 input=$2)"
}

try 0 0 run1	# вендорский дефолт свойства: standard=0 -> 0xc010c
try 3 0 run2	# что писали раньше (0xc0120)
try 0 1 run3	# другой вход АЦП

kill "$LOGGER" 2>/dev/null

echo "== S2D / audio log"
grep -E "saa7231 (s2d|audio|vfl)" "$KMSG" | tail -n 40

echo "== audio verdict"
N=$(grep -c "saa7231 audio: buf" "$KMSG")
echo "audio buffers reported: $N"
grep "saa7231 audio: buf" "$KMSG" | tail -n 8
if [ "$N" -eq 0 ]; then
	echo "VERDICT: NO AUDIO DMA (index never advanced)"
else
	python3 - "$KMSG" <<'PY'
import re, sys
rms = [int(m.group(1)) for m in
       re.finditer(r'saa7231 audio: buf \d+ .* rms=(\d+)', open(sys.argv[1]).read())]
print("rms values:", rms[:12])
print("VERDICT:", "PCM PRESENT" if rms and max(rms) > 30 else "SILENCE / CONSTANT")
PY
fi

echo "== errors"
grep -iE "error|failed|invalid" "$KMSG" | grep saa7231 | tail -n 10

echo "== done: $OUT"
