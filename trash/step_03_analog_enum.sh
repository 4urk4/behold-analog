#!/bin/bash
# step_03_analog_enum.sh — Phase 4, first look at the analog V4L2 device
#
# Что делает:
#   ставит свежесобранные модули (saa7231_core теперь содержит
#   saa7231_xs2dtl + saa7231_vfl), перезагружает драйвер и перечисляет
#   /dev/video* через v4l2-ctl: списки устройств, входов, форматов и
#   текущий формат.  Поток (STREAMON), регистры AVIS и S2D не трогаются.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/{saa7231_core,saa7231_drv}.ko
#   и загруженные модули — до reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо reboot.
#
# Риск: минимальный — при загрузке vfl только регистрирует video_device.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
OUT=$PROJ/logs/$(date +%Y%m%d-%H%M)_analog_enum.out

exec > >(tee -a "$OUT") 2>&1
echo "# analog enum $(date -Is)"

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

echo "== dec_init parameter"
cat /sys/module/saa7231_core/parameters/dec_init 2>&1

echo "== video devices"
ls -l /dev/video* 2>&1
v4l2-ctl --list-devices 2>&1

for dev in /dev/video*; do
	[ -e "$dev" ] || continue
	echo "== $dev"
	v4l2-ctl -d "$dev" --list-inputs 2>&1
	v4l2-ctl -d "$dev" --list-formats 2>&1
	v4l2-ctl -d "$dev" --get-fmt-video 2>&1
done

echo "== dmesg tail"
dmesg | tail -n 60
echo "== done: $OUT"
