#!/bin/bash
# step_27_snap_win.sh — Phase 5, шаг 36: эталонный дамп регистров после Windows
#
# Что делает:
#   перезагружает модуль с snap_init=1 и снимает регистры SAA7231 ДО какой-либо
#   инициализации. Запускать сразу после тёплого ребута из Windows, где
#   вендорский драйвер уже работал с аналоговым захватом (composite + звук).
#   Тогда в дампе — вендорское состояние AUDIO/AS2D.
#
# Что меняет: только загруженные модули (reload). Регистры не пишет.
# Откат: sudo modprobe -r saa7231_drv saa7231_core && sudo modprobe saa7231_core && sudo modprobe saa7231_drv
#
# Риск: нет (только чтения в разрешённых окнах BAR0).

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_snapwin.out

exec > >(tee -a "$OUT") 2>&1
echo "# windows reference snapshot $(date -Is)"

echo "== unload"
modprobe -r saa7231_drv 2>/dev/null
modprobe -r saa7231_core 2>/dev/null

echo "== load with snap_init=1 (probe happens in saa7231_drv)"
modprobe saa7231_core snap_init=1 || exit 1
modprobe saa7231_drv || exit 1
sleep 1
dmesg | grep "saa7231 snap" > "$PROJ/logs/${STAMP}_snap.txt"

echo "== AUDIO / AS2D rows"
grep -E "saa7231 snap 0x(28[01]|124)" "$PROJ/logs/${STAMP}_snap.txt"
echo "== AVIS input rows"
grep -E "saa7231 snap 0x2000(00|0[0-9a-f]0)" "$PROJ/logs/${STAMP}_snap.txt" | head -8

echo "== how many rows: $(wc -l < "$PROJ/logs/${STAMP}_snap.txt")"
echo "== done: $OUT / logs/${STAMP}_snap.txt"
