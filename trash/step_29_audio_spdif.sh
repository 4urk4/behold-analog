#!/bin/bash
# step_29_audio_spdif.sh — Phase 5, шаг 38: I2S vs SPDIF и статус аудиопорта
#
# Что делает:
#   с audio_rgu=1 (блок AUDIO уже доказанно оживает) гоняет аудио дважды:
#   audio_config=0 (I2S, как было) и 4 (SPDIF). Во время потока читает
#   регистры аудиопорта STREAM (0x12c000+0x110..0x130): lost samples,
#   SPDIF values/counters/chstat/lock — по ним видно, идёт ли поток кадров
#   от АЦП/DSP вообще.
#
# Что меняет: модули; регистры AUDIO/AS2D/STREAM; RGU_RESET_CTRL1.
# Откат: reload драйвера либо reboot.
# Риск: как в step_28 (узкий импульс RGU, вендорский).

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_audio_spdif.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# audio spdif $(date -Is)"

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
echo 0 > "$PARAM/audio_std"

dmesg -w > "$KMSG" &
LOGGER=$!

port() {	# port <tag>: STREAM audio port status
	echo "0x12c110:8" > "$PARAM/dbg_dump"
	sleep 0.15
	echo "-- $1: $(grep "0x12c110:" "$KMSG" | tail -n 1 | cut -d: -f2-)"
}

run() {	# run <config> <tag>
	echo "$1" > "$PARAM/audio_config"
	BEFORE=$(grep -c 'saa7231 audio: buf' "$KMSG")
	echo "== $2: audio_config=$1"
	( timeout 30 v4l2-ctl -d /dev/video0 --set-input=0 \
		--stream-mmap --stream-count=150 --stream-to=/dev/null ) >/dev/null 2>&1 &
	CAP=$!
	sleep 2
	port t0
	sleep 1
	port t1
	wait $CAP
	sleep 1
	echo "-- audio buffers: $(( $(grep -c 'saa7231 audio: buf' "$KMSG") - BEFORE ))"
}

run 0 "run1 I2S"
run 4 "run2 SPDIF"

kill "$LOGGER" 2>/dev/null
echo "== done: $OUT"
