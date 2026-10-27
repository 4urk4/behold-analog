#!/bin/bash
# step_30_audio_vendor.sh — Phase 5, шаг 39: звук по вендорскому эталону
#
# Что делает:
#   ставит модули, включает audio_init=1 (обязательный audio_rgu=1 внутри
#   тоже), гоняет захват 150 кадров и снимает AUDIO/STREAM/AS2D, чтобы
#   сравнить с дампом из Windows (logs/win_audio_run.txt).
#
# Что меняет: модули; регистры AUDIO/AS2D/STREAM; RGU_RESET_CTRL1.
# Откат: reload драйвера либо reboot.
# Риск: тот же узкий импульс RGU, что в step_28/29.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_audio_vendor.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# audio vendor-matched $(date -Is)"

install -m 644 "$PROJ/src/saa7231_core.ko" "$DEST/" || exit 1
install -m 644 "$PROJ/src/saa7231_drv.ko" "$DEST/" || exit 1
depmod -a "$KVER"
modprobe -r saa7231_drv 2>/dev/null
modprobe -r saa7231_core 2>/dev/null
modprobe saa7231_core || exit 1
modprobe saa7231_drv || exit 1
sleep 1
echo 1 > "$PARAM/audio_init"
echo 1 > "$PARAM/audio_rgu"	# без импульса блок AUDIO остаётся в сбросе
echo "audio_init=$(cat "$PARAM/audio_init") rgu=$(cat "$PARAM/audio_rgu") rate=$(cat "$PARAM/audio_rate") config=$(cat "$PARAM/audio_config")"

dmesg -w > "$KMSG" &
LOGGER=$!

dump() {	# dump <off>:<words> <tag>
	echo "$1" > "$PARAM/dbg_dump"
	sleep 0.15
	echo "-- $2:"
	grep "saa7231 dbg_dump bar0 ${1%%:*}" "$KMSG" | sed 's/.*bar0 //'
}

BEFORE=$(grep -c 'saa7231 audio: buf' "$KMSG")
( timeout 30 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=150 --stream-to=/dev/null ) >/dev/null 2>&1 &
CAP=$!
sleep 3
dump 0x280000:16 "AUDIO 0x000-0x03c"
dump 0x280040:16 "AUDIO 0x040-0x07c"
dump 0x280080:16 "AUDIO 0x080-0x0bc"
dump 0x280180:16 "AUDIO 0x180-0x1bc"
dump 0x2801c0:16 "AUDIO 0x1c0-0x1fc"
dump 0x12c100:8 "STREAM port 0x100-0x11c"
dump 0x12c120:4 "STREAM port 0x120-0x12c"
dump 0x124000:16 "AS2D 0x00-0x3c"
dump 0x201000:16 "AVIS audio port 0x1004-0x103c"
wait $CAP
sleep 1
echo "-- audio buffers: $(( $(grep -c 'saa7231 audio: buf' "$KMSG") - BEFORE ))"
echo "-- audio report:"
grep "saa7231 audio: buf" "$KMSG" | tail -n 4

kill "$LOGGER" 2>/dev/null
echo "== done: $OUT"
