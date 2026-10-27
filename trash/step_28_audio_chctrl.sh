#!/bin/bash
# step_28_audio_chctrl.sh — Phase 5, шаг 37: сброс AUDIO-блока (RGU) + CHx_CTRL
#
# Что делает:
#   после ребута блок AUDIO читается весь как 0xffffffff (держится в
#   сбросе). Скрипт гоняет аудио-захват так:
#     1) как есть (audio_rgu=0) — контроль, блок должен остаться ff;
#     2) audio_rgu=1 (вендорский импульс RGU_RESET_CTRL1), CHx_CTRL=0x29c;
#     3) audio_rgu=1, CHx_CTRL=0x39c (вендорское значение FUN_00021cec).
#   В каждом прогоне читает 0x280000/0x28000c/0x28001c/0x28003c дважды
#   с интервалом 1 с и считает дельты счётчиков.
#
# Что меняет: модули; регистры AUDIO/AS2D; RGU_RESET_CTRL1 в прогонах 2–3.
# Откат: reload драйвера либо reboot.
# Риск: RGU_RESET_CTRL1 (0x10e104) — тот регистр, на котором ловили
# зависание; импульс узкий (~ACTIVE1, биты 5–7), как у вендора.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_audio_chctrl.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# audio rgu/chctrl $(date -Is)"

install -m 644 "$PROJ/src/saa7231_core.ko" "$DEST/" || exit 1
install -m 644 "$PROJ/src/saa7231_drv.ko" "$DEST/" || exit 1
depmod -a "$KVER"
modprobe -r saa7231_drv 2>/dev/null
modprobe -r saa7231_core 2>/dev/null
modprobe saa7231_core || exit 1
modprobe saa7231_drv || exit 1
sleep 1
echo 1 > "$PARAM/audio_init"
echo 0 > "$PARAM/audio_std"

dmesg -w > "$KMSG" &
LOGGER=$!

rd() {	# rd <offset> -> value of the last dump line
	echo "0x$1:1" > "$PARAM/dbg_dump"
	sleep 0.15
	grep "saa7231 dbg_dump bar0 0x$1:" "$KMSG" | tail -n 1 | awk '{print $NF}'
}

sample() {	# sample <tag>
	echo "-- $1: 0x00000=%s 0x0000c=%s 0x0001c=%s 0x0003c=%s" \
		"$(rd 280000)" "$(rd 28000c)" "$(rd 28001c)" "$(rd 28003c)"
}

run() {	# run <rgu> <chctrl> <tag>
	echo "$1" > "$PARAM/audio_rgu"
	echo "$2" > "$PARAM/audio_chctrl"
	BEFORE=$(grep -c 'saa7231 audio: buf' "$KMSG")
	echo "== $3: audio_rgu=$1 audio_chctrl=$2"
	( timeout 30 v4l2-ctl -d /dev/video0 --set-input=0 \
		--stream-mmap --stream-count=150 --stream-to=/dev/null ) >/dev/null 2>&1 &
	CAP=$!
	sleep 2
	sample t0
	sleep 1
	sample t1
	wait $CAP
	sleep 1
	echo "-- audio buffers: $(( $(grep -c 'saa7231 audio: buf' "$KMSG") - BEFORE ))"
}

echo "== before any stream"
sample idle
run 0 0x29c "run1 rgu=0"
run 1 0x29c "run2 rgu=1"
run 1 0x39c "run3 rgu=1 vendor chctrl"

kill "$LOGGER" 2>/dev/null
echo "== audio report lines"
grep "saa7231 audio: buf" "$KMSG" | tail -n 6
echo "== done: $OUT"
