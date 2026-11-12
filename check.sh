#!/bin/sh
# check.sh - shows which parts of the CoreELEC SMB / WiFi tuning are active on this box. Public domain (CC0).
# Run on the box:  sh check.sh        (read-only, except for one small temp file per FUSE disk)
PATH=$PATH:/storage/.kodi/addons/virtual.network-tools/bin
FAILS=0
NOTES=0
ok()   { echo "[ OK ] $*"; }
note() { echo "[NOTE] $*"; NOTES=$((NOTES+1)); }
bad()  { echo "[FAIL] $*"; FAILS=$((FAILS+1)); }
info() { echo "[INFO] $*"; }
skip() { echo "[SKIP] $*"; }
CFG=/storage/.config

# ---------------------------------------------------------------- system
. /etc/os-release 2>/dev/null
if [ -e /lib/ld-linux-armhf.so.3 ]; then USERSPACE=armhf; elif [ -e /lib/ld-linux-aarch64.so.1 ]; then USERSPACE=aarch64; else USERSPACE=unknown; fi
info "System: ${PRETTY_NAME:-unknown} (${COREELEC_ARCH:-?}), kernel $(uname -r), userspace $USERSPACE, uptime $(cut -d. -f1 /proc/uptime) s"
info "Device tree: $(tr -d '\0' < /proc/device-tree/coreelec-dt-id 2>/dev/null)"
info "CPU cores by part: $(awk -F: '/^CPU part/ {gsub(/[ \t]/, "", $2); n[$2]++} END {for (k in n) printf "%s x%d  ", k, n[k]}' /proc/cpuinfo)(0xd03=A53 0xd05=A55 0xd09=A73)"

# ---------------------------------------------------------------- Samba signing
echo
if systemctl is-active smbd >/dev/null 2>&1; then
  alg=$(testparm -s 2>/dev/null | sed -n 's/^[[:space:]]*server smb3 signing algorithms = //p')
  if [ -z "$alg" ]; then
    if [ "$USERSPACE" = armhf ]; then note "Samba signing: default list (AES-128-GMAC first) - slow on a 32-bit userspace, see part A"
    else info "Samba signing: default list (fine on a 64-bit userspace)"; fi
  else
    case "$alg" in
      *HMAC-SHA256*)
        case "$alg" in
          AES-128-GMAC*) if [ "$USERSPACE" = armhf ]; then note "Samba signing list starts with GMAC ($alg) - slow on a 32-bit userspace, see part A"; else ok "Samba signing algorithms: $alg"; fi ;;
          *) ok "Samba signing algorithms: $alg" ;;
        esac ;;
      *) bad "Samba signing list lacks HMAC-SHA256 ($alg): Windows' first connection attempt will fail" ;;
    esac
  fi
  if which smbclient >/dev/null 2>&1; then
    if smbclient -L 127.0.0.1 -N -m SMB3 2>&1 | grep -q 'Sharename'; then ok "SMB3 negotiate against localhost works"
    else info "SMB3 share listing against localhost did not work (anonymous listing refused?) - not a negotiate test then"; fi
    # SMB1-format multi-protocol negotiate, the way Windows starts a first connection
    out=$(smbclient -L 127.0.0.1 -N --option='client min protocol=NT1' --option='client max protocol=SMB2_10' 2>&1)
    if echo "$out" | grep -q 'Sharename'; then ok "multi-protocol negotiate (first contact from Windows) works"
    elif echo "$out" | grep -q 'NT_STATUS_INVALID_PARAMETER'; then bad "multi-protocol negotiate refused (NT_STATUS_INVALID_PARAMETER) - Windows will report 'network path not found'"
    else info "multi-protocol negotiate could not be tested: $(echo "$out" | grep -m1 -E 'NT_STATUS|failed' | cut -c1-100)"; fi
  fi
else
  skip "smbd is not running"
fi

# ---------------------------------------------------------------- smb-notrunc
SO=$CFG/smb-notrunc.so
P=$(cat /run/samba/smbd.pid 2>/dev/null)
if [ -f "$SO" ]; then
  if [ -n "$P" ] && grep -q smb-notrunc /proc/$P/maps 2>/dev/null; then ok "smb-notrunc.so is loaded in smbd (pid $P)"
  else bad "smb-notrunc.so exists but is not loaded in smbd (drop-in missing or smbd not restarted)"; fi
fi
# FUSE-mounted disks (one per line; /proc/mounts writes a space as \040) and those served by exfat-fuse
FUSEMNT=$(awk '$3 ~ /^fuse/ && $2 ~ /^\/(var\/)?media\// {gsub(/\\040/, " ", $2); print $2}' /proc/mounts)
EXFATMNT=$(for p in $(pgrep mount.exfat); do tr '\0' '\n' < /proc/$p/cmdline | sed -n '3p'; done)
is_exfat() { echo "$EXFATMNT" | grep -qxF "$1"; }
echo "$FUSEMNT" > /tmp/.check-mounts.$$
while IFS= read -r m; do
  [ -n "$m" ] || continue
  if is_exfat "$m"; then kind="exfat-fuse"; else kind="FUSE, not exfat-fuse: zero-fill behaviour not tested"; fi
  if [ -f "$SO" ]; then
    t="$m/.notrunc-check.$$"
    LD_PRELOAD=$SO dd if=/dev/null of="$t" bs=1M seek=64 2>/dev/null
    s=$(stat -c %s "$t" 2>/dev/null); rm -f "$t"
    if [ -z "$s" ]; then skip "pre-size test on $m ($kind): could not create a test file (read-only mount?)"
    elif [ "$s" = 0 ]; then ok "pre-size on $m ($kind) is skipped (no zero-fill)"
    else bad "pre-size on $m ($kind) was not skipped (size $s)"; fi
  elif is_exfat "$m"; then note "$m is mounted by exfat-fuse and smb-notrunc is not installed: Windows copies to it are zero-filled first, see part B"
  else info "$m is a FUSE mount but not exfat-fuse (e.g. NTFS): part B was not tested for it"; fi
done < /tmp/.check-mounts.$$
rm -f /tmp/.check-mounts.$$
if [ ! -f "$SO" ] && [ -z "$FUSEMNT" ]; then skip "smb-notrunc not installed, no FUSE-mounted disks"; fi

# ---------------------------------------------------------------- bcmdhd driver
echo
if [ -d /sys/module/dhd ]; then
  info "WiFi driver: $(tr '\n' ' ' < /sys/module/dhd/parameters/info_string | sed 's/  */ /g' | cut -c1-150)"
  link=$(readlink -f /usr/lib/firmware/brcm/config.txt 2>/dev/null)
  case "$link" in
    /storage/*) ok "dhd config.txt override in use: $link ($(grep -E '^(txglomsize|dpc_cpucore|rxf_cpucore)=' "$link" | tr '\n' ' '))" ;;
    *) info "dhd config.txt: stock ($link)" ;;
  esac
  g=$(dmesg | sed -n 's/.*txglomsize=\([0-9]*\),.*/\1/p' | tail -1)
  if [ -z "$g" ]; then info "txglomsize: not in the kernel log any more"
  elif [ "$g" -le 20 ]; then ok "txglomsize=$g (TX bundle fits in a 32 KiB allocation)"
  else note "txglomsize=$g (needs a contiguous 64 KiB allocation per TX bundle, see part C)"; fi
  for n in dhd_dpc dhd_rxf; do
    p=$(pgrep -x $n | head -1)
    [ -n "$p" ] && info "$n (pid $p) allowed CPUs: $(awk '/Cpus_allowed_list/ {print $2}' /proc/$p/status)"
  done
  for irq in $(awk '/bcmsdh_sdmmc/ || (/meson-aml-mmc/ && /GIC-0 221 /) {sub(":", "", $1); print $1}' /proc/interrupts); do
    info "irq $irq ($(awk -v i="$irq:" '$1 == i {print $NF}' /proc/interrupts)) -> CPU $(cat /proc/irq/$irq/smp_affinity_list)"
  done
  if [ -f $CFG/wifi-irq-affinity.sh ]; then
    if systemctl is-active wifi-irq-affinity >/dev/null 2>&1; then ok "wifi-irq-affinity service is running"; else bad "wifi-irq-affinity installed but not running"; fi
  fi
else
  skip "bcmdhd driver (module 'dhd') not loaded - the WiFi driver parts do not apply"
fi
if which iw >/dev/null 2>&1; then
  info "WiFi link: $(iw dev wlan0 link 2>/dev/null | awk '/freq:/ {f=$2} /signal:/ {s=$2" "$3} /tx bitrate:/ {b=$3" "$4} END {printf "%s MHz, signal %s, tx %s", f, s, b}')"
fi

# ---------------------------------------------------------------- watchdog / journal / kernel log
echo
if [ -f $CFG/wifi-watchdog.sh ]; then
  if systemctl is-active wifi-watchdog >/dev/null 2>&1; then ok "wifi-watchdog service is running; last entries (the log can contain your SSID and addresses):"; else bad "wifi-watchdog installed but not running"; fi
  tail -n 3 /storage/wifi-debug/watchdog.log 2>/dev/null | sed 's/^/         /'
else
  skip "wifi-watchdog not installed"
fi
boots=$(journalctl --list-boots 2>/dev/null | grep -c '^ *-\?[0-9]')
if [ -f /storage/.cache/journald.conf.d/00_settings.conf ]; then info "persistent journal configured, $boots boot(s) recorded"; else info "journal is volatile (lost at reboot)"; fi
af=$(dmesg | grep -c 'page allocation failure')
if [ "$af" = 0 ]; then ok "no kernel memory-allocation failures since boot"; else bad "$af kernel memory-allocation failure(s) since boot:"; dmesg | grep 'page allocation failure' | tail -n 3 | sed 's/^/         /'; fi
tf=$(dmesg | grep -c 'TXGLOM: localbuf malloc FAILED')
[ "$tf" = 0 ] || bad "$tf x 'TX TXGLOM: localbuf malloc FAILED' from the WiFi driver since boot"
info "free memory blocks 4k..4M: $(awk '{for (i=5;i<=NF;i++) printf "%s ", $i}' /proc/buddyinfo)"

echo
echo "Result: $FAILS problem(s), $NOTES note(s) on untuned stock settings"
exit $FAILS
