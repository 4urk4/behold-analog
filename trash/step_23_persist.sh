#!/bin/bash
# step_23_persist.sh — Phase 4, шаг 33: аналог по умолчанию, без sysfs
#
# Что делает:
#   ставит модули, кладёт /etc/modprobe.d/saa7231-analog.conf с
#   options saa7231_core dec_init=1 dcsc_power=1, перезагружает драйвер
#   и снимает 25 кадров, НЕ трогая /sys/module/.../parameters вообще.
#   Печатает фактические значения параметров (их должен подставить
#   modprobe) и вердикт по хроме.
#
# Что меняет:
#   /etc/modprobe.d/saa7231-analog.conf (новый файл, старый — в .bak);
#   /lib/modules/$(uname -r)/extra/saa7231/*.ko; загруженные модули.
#
# Откат:
#   sudo rm /etc/modprobe.d/saa7231-analog.conf && sudo depmod -a
#   (или вернуть .bak); reload драйвера или reboot.
#
# Риск: dec_init/dcsc_power — те же вендорские записи, что в step_22
# (проверены). Они срабатывают только при старте видеопотока, DVB-ветку
# не затрагивают. Откат — удалить conf.

set -u
PROJ=/home/otakoi/_hueta/behold-analog
KVER=$(uname -r)
DEST=/lib/modules/$KVER/extra/saa7231
CONF=/etc/modprobe.d/saa7231-analog.conf
STAMP=$(date +%Y%m%d-%H%M)
OUT=$PROJ/logs/${STAMP}_persist.out
KMSG=$PROJ/logs/${STAMP}_kmsg.out
RAW=$PROJ/logs/${STAMP}_persist.raw
SKIP=$PROJ/logs/${STAMP}_frame10.raw
PNG=$PROJ/logs/${STAMP}_frame10.png
PARAM=/sys/module/saa7231_core/parameters

exec > >(tee -a "$OUT") 2>&1
echo "# persist dec_init=1 dcsc_power=1 via modprobe.d $(date -Is)"

echo "== install modules"
install -m 644 "$PROJ/src/saa7231_core.ko" "$DEST/" || exit 1
install -m 644 "$PROJ/src/saa7231_drv.ko" "$DEST/" || exit 1
depmod -a "$KVER"

echo "== write $CONF"
if [ -e "$CONF" ] && [ ! -e "$CONF.bak" ]; then
	cp -a "$CONF" "$CONF.bak"
	echo "backup -> $CONF.bak"
fi
cat > "$CONF" <<'EOF'
# Behold TV H8 (SAA7231): аналоговый захват.
# dec_init/dcsc_power включают программирование AVIS/DCSC при старте
# видеопотока (вендорские последовательности). Только video-ветка.
options saa7231_core dec_init=1 dcsc_power=1
EOF
cat "$CONF"

echo "== reload driver (без записи в sysfs)"
modprobe -r saa7231_drv 2>/dev/null
modprobe -r saa7231_core 2>/dev/null
modprobe saa7231_core || exit 1
modprobe saa7231_drv || exit 1
sleep 1

echo "== params (должны прийти из modprobe.d)"
echo "dec_init=$(cat "$PARAM/dec_init")"
echo "dcsc_power=$(cat "$PARAM/dcsc_power")"
echo "avis_fmt=$(cat "$PARAM/avis_fmt") chctrl=$(cat "$PARAM/video_chctrl") s2d=$(cat "$PARAM/video_s2d_ctrl") packed=$(cat "$PARAM/packed_src")"

dmesg -w > "$KMSG" &
LOGGER=$!

echo "== capture 25 frames via V4L2"
timeout 15 v4l2-ctl -d /dev/video0 --set-input=0 \
	--stream-mmap --stream-count=25 --stream-to="$RAW"
echo "v4l2-ctl exit=$?"
sleep 1
kill "$LOGGER" 2>/dev/null

echo "== skip 10 frames, decode the next one"
tail -c +$((10 * 829440 + 1)) "$RAW" | head -c 829440 > "$SKIP"
ls -l "$RAW" "$SKIP" 2>&1
ffmpeg -v error -y -f rawvideo -pix_fmt yuyv422 -s 720x576 \
	-i "$SKIP" -frames:v 1 "$PNG" 2>&1
ls -l "$PNG" 2>&1

echo "== chroma check (frame 10)"
python3 - "$SKIP" <<'PY'
import collections, sys
d = open(sys.argv[1], 'rb').read()[:414720]
uv = collections.Counter(d[1::2])
tot = sum(uv.values())
gray = uv.get(0x80, 0)
print("U/V distinct=%d, exactly 0x80: %d / %d (%.1f%%)"
      % (len(uv), gray, tot, 100.0 * gray / tot))
print("top U/V:", uv.most_common(5))
print("VERDICT:", "GRAY/NO CHROMA" if len(uv) <= 2 else "COLOR OK")
PY

echo "== driver log"
grep -E "saa7231 (vfl|avis):" "$KMSG" | tail -n 12

echo "== done: $OUT / $PNG"
