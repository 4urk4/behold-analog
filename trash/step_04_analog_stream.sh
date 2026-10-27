#!/bin/bash
# step_04_analog_stream.sh — Phase 4, first capture attempt
#
# Что делает:
#   ставит модули, перезагружает драйвер, включает параметр
#   saa7231_core.dec_init=1 (программирование видеодекодера AVIS по
#   вендорской последовательности), выбирает вход 0 (composite, тип 3)
#   и пытается принять 20 кадров через v4l2-ctl --stream-mmap с таймаутом
#   20 с.  После попытки читает (только читает!) регистры AVIS и
#   VS2D_AVIS через dbg_avis.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko (переустановка);
#   загруженные модули; регистры AVIS/VS2D_AVIS; клоки CGU — всё до
#   reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot.
#
# Риск: ПЕРВАЯ запись в блок AVIS.  Регистры — только внутри окна
#   BAR0 0x200000..0x280000, известная ловушка 0x300000 не затрагивается.
#   Если машина зависнет — только reset кнопкой.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_analog_stream.out
RAW=$PROJ/logs/${STAMP}_frame.raw
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# analog stream $(date -Is)"

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

echo "== enable decoder init"
echo 1 > "$PARAM/dec_init" || exit 1
cat "$PARAM/dec_init"

echo "== stream 20 frames from input 0 (composite), 20s timeout"
timeout 20 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=20 --stream-to="$RAW"
echo "v4l2-ctl exit=$?"
sleep 1

for off in 0x20239c 0x203398 0x20339c 0x2033f4 0x202410 0x202414 \
	   0x120000 0x12000c 0x1200a0 0x1200a4 0x120ff0 0x120ffc; do
	echo "== read $off ($(date +%H:%M:%S))"
	sync
	echo "$off" > "$PARAM/dbg_avis"
	sync
	sleep 1
done

echo "== frame file"
if [ -f "$RAW" ]; then
	ls -l "$RAW"
	echo -n "non-zero bytes in first frame: "
	head -c 829440 "$RAW" | tr -d '\0' | wc -c
else
	echo "no frame file"
fi

echo "== dmesg tail"
dmesg | tail -n 80
echo "== done: $OUT"
