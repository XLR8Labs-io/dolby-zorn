#!/system/bin/sh
# dolby-probe.sh - Phase 1 evidence gathering for Dolby on zorn (Redmi K80)
# Run as root: adb shell su -c 'sh /data/local/tmp/dolby-probe.sh'
# Read-only. Makes no changes to the device.

P() { echo; echo "===== $* ====="; }

P DEVICE IDENTITY
for p in ro.product.device ro.product.name ro.product.model ro.board.platform \
         ro.product.vendor.device ro.build.version.release ro.build.version.sdk \
         ro.build.version.incremental ro.build.display.id ro.build.fingerprint \
         ro.vendor.build.fingerprint ro.odm.build.fingerprint ro.product.first_api_level; do
  echo "$p = $(getprop $p)"
done

P ROOT / MODULE MANAGER
echo "whoami = $(id -u) $(id)"
echo "ksud: $(command -v ksud || echo none)"
ksud -V 2>/dev/null || true
echo "magisk: $(command -v magisk || echo none)"
magisk -v 2>/dev/null || true
echo "enforce = $(getenforce)"

P DOLBY RELATED PROPS
getprop | grep -iE 'dolby|dax|dts|atmos|spatial|effect' || echo "(none)"

P PARTITION LAYOUT / SYMLINKS
for d in /odm /vendor/odm /system/vendor /vendor /product /system/product; do
  printf '%-16s ' "$d"
  if [ -L "$d" ]; then echo "SYMLINK -> $(readlink $d)"
  elif [ -d "$d" ]; then echo "dir"
  else echo "MISSING"; fi
done
echo "--- mount (relevant) ---"
mount | grep -E ' /odm | /vendor | /product | /system ' || true
echo "--- overlay mounts ---"
mount | grep -i overlay || echo "(no overlay mounts)"

P DOLBY EFFECT LIBRARIES
for d in /vendor/lib64/soundfx /vendor/lib/soundfx /odm/lib64/soundfx /odm/lib/soundfx \
         /system/lib64/soundfx /system/lib/soundfx /system_ext/lib64/soundfx; do
  echo "--- $d ---"
  ls -lZ "$d" 2>/dev/null || echo "(absent)"
done

P DOLBY HAL / SERVICE BINARIES
ls -lZ /vendor/bin/hw/ 2>/dev/null | grep -i dolby || echo "(no dolby in /vendor/bin/hw)"
ls -lZ /odm/bin/hw/ 2>/dev/null | grep -i dolby || echo "(no dolby in /odm/bin/hw)"
find /vendor/lib64 /vendor/lib /odm/lib64 /odm/lib /system_ext/lib64 -maxdepth 1 \
     \( -iname '*dolby*' -o -iname '*dap*' -o -iname '*dax*' -o -iname '*dms*' \) 2>/dev/null \
     | head -40 || true

P DOLBY CONFIG DIRS
for d in /vendor/etc/dolby /odm/etc/dolby /product/etc/dolby /system/etc/dolby; do
  echo "--- $d ---"
  ls -lZ "$d" 2>/dev/null || echo "(absent)"
done

P AUDIO EFFECTS CONFIG
for f in /vendor/etc/audio_effects.xml /vendor/etc/audio_effects.conf \
         /odm/etc/audio_effects.xml /system/etc/audio_effects.xml \
         /vendor/etc/audio_effects_dolby.xml; do
  echo "--- $f ---"
  if [ -f "$f" ]; then ls -lZ "$f"; grep -iE 'dolby|dax|9d4921da|ds1|dap' "$f" || echo "(no dolby refs)";
  else echo "(absent)"; fi
done

P VINTF / MANIFEST DOLBY ENTRIES
grep -ril dolby /vendor/etc/vintf /odm/etc/vintf /vendor/manifest.xml 2>/dev/null || echo "(none)"

P INIT RC DOLBY ENTRIES
grep -ril dolby /vendor/etc/init /odm/etc/init /system/etc/init 2>/dev/null || echo "(none)"

P INSTALLED DOLBY APPS
pm list packages -f 2>/dev/null | grep -iE 'dolby|atmos|lunaris' || echo "(none installed)"

P RUNNING AUDIO / DOLBY PROCESSES
ps -A 2>/dev/null | grep -iE 'audio|dolby|dms' || true

P AUDIOFLINGER EFFECT DUMP
dumpsys media.audio_flinger 2>/dev/null | sed -n '/Effect/,/^$/p' | head -80 || echo "(dumpsys failed)"

P SPATIALIZER STATE
dumpsys audio 2>/dev/null | grep -iA5 -E 'spatial' | head -40 || echo "(none)"

P KSU MODULES PRESENT
ls -la /data/adb/modules/ 2>/dev/null || echo "(no /data/adb/modules)"
for m in /data/adb/modules/*/module.prop; do
  [ -f "$m" ] && { echo "--- $m ---"; cat "$m"; }
done

P RECENT SELINUX DENIALS
dmesg 2>/dev/null | grep -i avc | tail -40 || echo "(dmesg unavailable)"

P DONE
