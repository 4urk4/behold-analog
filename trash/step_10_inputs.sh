#!/bin/bash
# step_10_inputs.sh — Phase 4: try all four analog inputs and compare data
#
# Что делает:
#   ставит модули, перезагружает драйвер, включает dec_init=1 и
#   dcsc_power=1, затем по очереди снимает по 5 кадров с четырёх входов
#   (0=Composite/тип3, 1=S-Video/тип9, 2=YPbPr/тип10, 3=RGB/тип12) и
#   считает статистику первого кадра каждого: сколько ненулевых байт,
#   сколько разных значений, диапазон яркости.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   S2D/AVIS/DCSC — до reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot.
#
# Риск: те же записи в AVIS/S2D/DCSC, что и в step_08/09 (уже проверены).

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_inputs.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# inputs $(date -Is)"

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

echo "== dec_init=1 dcsc_power=1"
echo 1 > "$PARAM/dec_init"
echo 1 > "$PARAM/dcsc_power"
dmesg -w > "$KMSG" &
LOGGER=$!

for i in 0 1 2 3; do
	RAW=$PROJ/logs/${STAMP}_in${i}.raw
	echo "== input $i"
	timeout 10 v4l2-ctl -d /dev/video0 --set-input=$i \
		--stream-mmap --stream-count=5 --stream-to="$RAW"
	echo "exit=$?"
done

sleep 1
kill "$LOGGER" 2>/dev/null

echo "== frame stats"
for i in 0 1 2 3; do
	RAW=$PROJ/logs/${STAMP}_in${i}.raw
	echo "-- input $i ($RAW)"
	python3 - "$RAW" <<'PY'
import sys
try:
    d = open(sys.argv[1], 'rb').read(829440)
except OSError:
    print("no file"); raise SystemExit
if not d:
    print("empty"); raise SystemExit
ys = d[0::2]
print("size", len(d), "nonzero", sum(1 for b in d if b),
      "distinct", len(set(d)), "Y min/max", min(ys), max(ys),
      "Y distinct", len(set(ys)))
PY
done

echo "== driver frame counters"
grep -E "saa7231 vfl: stop" "$KMSG" | tail -n 8

echo "== done: $OUT"
