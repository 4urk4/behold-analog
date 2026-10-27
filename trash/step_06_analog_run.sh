#!/bin/bash
# step_06_analog_run.sh — Phase 4: capture after the dev_lock fix
#
# Что делает:
#   ставит модули, перезагружает драйвер, пишет ядерный лог в файл и
#   делает два прогона:
#     1) dec_init=0 — только S2D/MMU, 1 кадр, таймаут 8 с (ожидаем
#        таймаут без кадров: декодер не программировали);
#     2) dec_init=1 — программирование AVIS + 5 кадров, таймаут 15 с.
#   После каждого прогона читает регистры S2D/AVIS (только чтение).
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули;
#   регистры S2D/MMU и AVIS — до reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot (при D-state — только reboot).
#
# Риск: запись в AVIS (только окно 0x200000..0x280000); при зависании
#   процесса — перезагрузка.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_analog_run.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
RAW0=$PROJ/logs/${STAMP}_s2d.raw
RAW1=$PROJ/logs/${STAMP}_avis.raw
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# analog run $(date -Is)"

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

echo "== kernel log to $KMSG"
dmesg -w > "$KMSG" &
LOGGER=$!
sleep 1

read_regs() {
	for off in "$@"; do
		echo "== read $off"
		sync
		echo "$off" > "$PARAM/dbg_avis"
		sync
		sleep 1
	done
}

echo "== stage 1: S2D only (dec_init=0)"
echo 0 > "$PARAM/dec_init"
timeout --kill-after=5 8 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=1 --stream-to="$RAW0"
echo "stage1 exit=$?"
read_regs 0x120000 0x12000c 0x1200a0 0x1200a4

echo "== stage 2: AVIS + S2D (dec_init=1)"
echo 1 > "$PARAM/dec_init"
timeout --kill-after=5 15 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=5 --stream-to="$RAW1"
echo "stage2 exit=$?"
read_regs 0x20239c 0x203398 0x20339c 0x2033f4 0x120000 0x1200a0 0x1200a4

kill "$LOGGER" 2>/dev/null

echo "== marker tail (from kmsg file)"
grep -E "saa7231 (vfl|avis|s2d):" "$KMSG" | tail -n 40

echo "== frame files"
ls -l "$RAW0" "$RAW1" 2>&1
for f in "$RAW0" "$RAW1"; do
	[ -s "$f" ] || continue
	echo -n "$f non-zero bytes: "
	head -c 829440 "$f" | tr -d '\0' | wc -c
done

echo "== dmesg tail"
dmesg | tail -n 40
echo "== done: $OUT"
