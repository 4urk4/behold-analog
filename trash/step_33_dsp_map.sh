#!/bin/bash
# step_33_dsp_map.sh — Phase 5, шаг 42: карта неисследованного окна AUDIO
#
# Что делает:
#   audio_init=1 + audio_rgu=1, старт аудиозахвата (300 кадров), и во время
#   потока читает (только чтения) регионы, которые ни разу не снимали:
#     AUDIO 0x282000/0x283000/0x284000/0x288000/0x290000/0x298000/
#           0x2a0000/0x2c0000/0x2e0000/0x2fe000/0x2feff0
#     RGU   0x10e100..0x10e15c   (CTRL/STATUS/ACTIVE)
#     CGU   0x180000..0x1800fc
#   Плюс контрольный дамп первых 0x200 байт AUDIO (что регистры живы).
#
# Что меняет: модули; AUDIO/AS2D/STREAM; RGU_RESET_CTRL1 (импульс).
# Откат: reload драйвера либо reboot (все параметры по умолчанию 0).
# Риск: чтения внутри BAR0 ниже 0x300000 (0x300000 не трогаем).

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_dsp_map.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# dsp map $(date -Is)"

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

dmesg -w > "$KMSG" &
LOGGER=$!

dmp() {	# dmp <offset> <words> <tag>
	echo "$1:$2" > "$PARAM/dbg_dump"; sleep 0.1
	echo "-- $3 0x$1"
	grep "bar0 0x$1:" "$KMSG" | tail -n 1 | cut -d: -f2-
}

( timeout 40 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=300 --stream-to=/dev/null ) >/dev/null 2>&1 &
CAP=$!
sleep 3

dmp 0x280000 64 "AUDIO regs (control)"
for off in 0x282000 0x283000 0x284000 0x288000 0x290000 0x298000 \
	   0x2a0000 0x2c0000 0x2e0000 0x2fe000; do
	dmp "$off" 8 "AUDIO uncharted"
done
dmp 0x2feff0 4 "AUDIO top"
dmp 0x10e100 24 "RGU ctrl/status/active"
dmp 0x180000 64 "CGU"

wait $CAP
sleep 1
kill "$LOGGER" 2>/dev/null

echo "-- audio buffers: $(grep -c 'saa7231 audio: buf' "$KMSG")"
echo "== done: $OUT"
