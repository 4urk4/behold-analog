#!/bin/bash
# step_26_audio_dump.sh — Phase 5, шаг 36: дамп AUDIO/AS2D во время захвата
#
# Что делает:
#   ставит модули, перезагружает драйвер, включает audio_init=1, запускает
#   захват на 4 секунды и во время потока читает окна AUDIO (0x280000) и
#   AS2D_LOCAL (0x124000), плюс те же окна до старта потока.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули.
#   Только чтения регистров — записи те же, что в step_25.
#
# Откат: reload драйвера или reboot (audio_init=0 по умолчанию).
#
# Риск: чтение внутри BAR0 в разрешённых окнах (проверка границ в
# dbg_dump на месте), 0x300000 не трогаем.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_audiodump.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# audio register dump $(date -Is)"

echo "== install modules"
install -m 644 "$PROJ/src/saa7231_core.ko" "$DEST/" || exit 1
install -m 644 "$PROJ/src/saa7231_drv.ko" "$DEST/" || exit 1
depmod -a "$KVER"

modprobe -r saa7231_drv 2>/dev/null
modprobe -r saa7231_core 2>/dev/null
modprobe saa7231_core || exit 1
modprobe saa7231_drv || exit 1
sleep 1

echo 1 > "$PARAM/audio_init"

dmesg -w > "$KMSG" &
LOGGER=$!

dump() {	# dump <tag>
	for r in 0x2801c0:8 0x280fe0:8 0x281000:16 \
		 0x124000:16 0x124010:16 0x124fd0:16; do
		echo "$r" > "$PARAM/dbg_dump" || echo "dump $r rejected"

	done
	sleep 0.3
	echo "-- $1:"
	grep "saa7231 dbg_dump" "$KMSG" | tail -n 25
}

echo "== dumps before stream"
dump idle

echo "== capture 100 frames (~4 s) in background"
( timeout 20 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=100 --stream-to=/dev/null ) &
CAP=$!
sleep 1.5
echo "== dumps during stream (t=1.5s)"
dump streaming
sleep 1
echo "== dumps during stream (t=2.5s)"
dump streaming2
wait $CAP
sleep 1
kill "$LOGGER" 2>/dev/null

echo "== audio lines"
grep "saa7231 audio" "$KMSG" | tail -n 5
echo "count: $(grep -c 'saa7231 audio: buf' "$KMSG")"

echo "== done: $OUT"
