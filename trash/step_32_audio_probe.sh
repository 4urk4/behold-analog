#!/bin/bash
# step_32_audio_probe.sh — Phase 5, шаг 41: двигается ли адрес AS2D
#
# Что делает:
#   audio_init=1 + audio_rgu=1, длинный захват (300 кадров ~12 с), и три
#   среза регистров AS2D с интервалом 2 с: текущий адрес (0x1240a0),
#   B_LENGTH/STRIDE/X/Y (0x124028), статус прерываний (0x124fd0).
#   Если 0x1240a0 меняется — данные идут, а сломан наш индексный опрос.
#
# Что меняет: модули; регистры AUDIO/AS2D; RGU_RESET_CTRL1.
# Откат: reload драйвера либо reboot.
# Риск: как step_28 (узкий импульс RGU).

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_audio_probe.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# audio probe $(date -Is)"

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
echo 1 > "$PARAM/avis_adc_ref"

dmesg -w > "$KMSG" &
LOGGER=$!

snap() {	# snap <tag>
	echo "0x1240a0:1" > "$PARAM/dbg_dump"; sleep 0.1
	A=$(grep "bar0 0x1240a0:" "$KMSG" | tail -n 1 | awk '{print $NF}')
	echo "0x124028:8" > "$PARAM/dbg_dump"; sleep 0.1
	G=$(grep "bar0 0x124028:" "$KMSG" | tail -n 1 | cut -d: -f2-)
	echo "0x124fd0:8" > "$PARAM/dbg_dump"; sleep 0.1
	S=$(grep "bar0 0x124fd0:" "$KMSG" | tail -n 1 | cut -d: -f2-)
	echo "-- $1: addr=$A geom=$G"
	echo "            status=$S"
}

( timeout 40 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=300 --stream-to=/dev/null ) >/dev/null 2>&1 &
CAP=$!
sleep 3
snap t0
sleep 2
snap t1
sleep 2
snap t2
wait $CAP
sleep 1
kill "$LOGGER" 2>/dev/null

echo "-- audio buffers: $(grep -c 'saa7231 audio: buf' "$KMSG")"
grep -E "saa7231 audio" "$KMSG" | tail -n 3
echo "== done: $OUT"
