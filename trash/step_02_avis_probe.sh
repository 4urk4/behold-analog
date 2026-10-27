#!/bin/bash
# step_02_avis_probe.sh — Phase 3, первый живой контакт с блоком AVIS
#
# Что делает:
#   ставит свежесобранные модули (в них добавлен параметр dbg_avis),
#   перезагружает драйвер с h8_fw_load=0/h8_rgu=0, активирует видеоклок
#   (CGU: VIDEO_CAPTURE / STREAM_PORT_VS2D_AVIS) и читает 4 регистра BAR0:
#     0x120ffc — VS2D_AVIS MODULE_ID
#     0x200ffc — AVIS MODULE_ID
#     0x20239c — AVIS STATUS (бит 0 вендор читает как «есть видео»)
#     0x280ffc — AUDIO MODULE_ID
#   Записей в регистры AVIS нет. Всё пишется в logs/<дата>_avis_probe.out.
#
# Что меняет:
#   /lib/modules/$(uname -r)/extra/saa7231/{saa7231_core,saa7231_drv}.ko;
#   загруженные модули и клоки CGU — до reload/reboot.
#
# Откат:
#   sudo modprobe -r saa7231_drv saa7231_core; sudo modprobe saa7231_core saa7231_drv
#   либо просто reboot (параметры модулей и клоки не сохраняются).
#
# Риск: чтение неизвестного регистра BAR0 теоретически может подвесить машину
#   (известный случай — 0x300000). Если зависнет — только reset кнопкой.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
OUT=$PROJ/logs/$(date +%Y%m%d-%H%M)_avis_probe.out
PARAM=/sys/module/saa7231_core/parameters/dbg_avis

exec > >(tee -a "$OUT") 2>&1
echo "# AVIS probe $(date -Is)"

echo "== install modules"
install -m 644 "$PROJ/src/saa7231_core.ko" "$DEST/" || exit 1
install -m 644 "$PROJ/src/saa7231_drv.ko" "$DEST/" || exit 1
depmod -a "$KVER"

echo "== reload driver (h8_fw_load=0 h8_rgu=0)"
modprobe -r saa7231_drv 2>/dev/null
modprobe -r saa7231_core 2>/dev/null
modprobe saa7231_core || exit 1
modprobe saa7231_drv || exit 1
sleep 1

if [ ! -e "$PARAM" ]; then
	echo "ERROR: $PARAM отсутствует — загрузился старый saa7231_core?" >&2
	exit 1
fi

echo "== activate video clocks"
echo clock > "$PARAM"
sleep 1

for off in 0x120ffc 0x280ffc 0x200ffc 0x20239c; do
	echo "== read $off ($(date +%H:%M:%S))"
	sync
	echo "$off" > "$PARAM"
	sync
	sleep 1
done

echo "== dmesg tail"
dmesg | tail -n 60
echo "== done: $OUT"
