#!/bin/sh
# install.sh - CoreELEC SMB / WiFi tuning. Run on the box from the unpacked package directory:
#
#   sh install.sh smb         Samba signing fix + smb-notrunc (no zero-fill on exFAT)   -> active at once
#   sh install.sh wifi        bcmdhd config.txt override + interrupt pinning              -> active after reboot
#   sh install.sh watchdog    WiFi watchdog + persistent journal                         -> active at once
#   sh install.sh all         everything that applies to this box
#
# Single parts: samba  notrunc  dhd  irq  watchdog.   Undo with uninstall.sh.   Verify with check.sh.
# Everything is stored under /storage/.config (plus one journald setting in /storage/.cache and the
# watchdog logs in /storage/wifi-debug); nothing in the read-only system image is touched. A samba.conf
# or dhd config.txt of your own is saved as <name>.pre-tuning before it is changed.
# Parts that do not fit the box are skipped with a message; FORCE=1 overrides those checks.
# Public domain (CC0), no warranty.

cd "$(dirname "$0")" || exit 1
SELF=$(basename "$0")
F=./files
CFG=/storage/.config
SYSD=$CFG/system.d
STATE=$CFG/smb-wifi-tuning          # remembers what this installer created
REBOOT=""

say()  { echo ">> $*"; }
warn() { echo "!! $*"; }

[ -d "$F" ] || { echo "run this from the unpacked package (files/ not found)"; exit 1; }
if [ ! -d /storage/.config ] || [ ! -x /usr/lib/samba/samba-config ]; then echo "this does not look like CoreELEC - aborting"; exit 1; fi
mkdir -p "$STATE" "$SYSD"

if [ -e /lib/ld-linux-armhf.so.3 ]; then USERSPACE=armhf; elif [ -e /lib/ld-linux-aarch64.so.1 ]; then USERSPACE=aarch64; else USERSPACE=unknown; fi

# cores that are not Cortex-A53 (CPU part 0xd03) on a big.LITTLE SoC, e.g. "2 3 4 5" on S922X/A311D
BIG=$(awk -F: '/^processor/ {p=$2+0} /^CPU part/ {gsub(/[ \t]/, "", $2); part[p]=$2; seen[$2]=1}
  END { n=0; for (k in seen) n++; if (n < 2) exit
        for (i=0; i<64; i++) if ((i in part) && part[i] != "0xd03") printf "%d ", i }' /proc/cpuinfo)

restart_smbd() {
  /usr/lib/samba/samba-config
  if systemctl is-active smbd >/dev/null 2>&1; then systemctl restart smbd; say "smbd restarted (open SMB connections were dropped)"; fi
}

do_samba() {
  if [ "$USERSPACE" != armhf ] && [ -z "$FORCE" ]; then
    warn "samba: userspace is $USERSPACE, not 32-bit ARM. GnuTLS has hardware AES-GCM there, so this is probably not needed. Skipped (FORCE=1 to apply anyway)."; return
  fi
  U=$CFG/samba.conf
  if [ ! -f "$U" ]; then
    cp /etc/samba/smb.conf "$U"; echo created > "$STATE/samba"; say "samba: created $U from the stock configuration"
  elif [ ! -f "$STATE/samba" ]; then
    cp -p "$U" "$U.pre-tuning"; echo existing > "$STATE/samba"
  fi
  # drop any existing setting of the parameter and add ours right after the [global] line
  awk 'tolower($0) ~ /^[ \t]*server smb3 signing algorithms[ \t]*=/ {next}
       {print}
       !done && tolower($0) ~ /^[ \t]*\[global\]/ {print "  server smb3 signing algorithms = AES-128-CMAC, HMAC-SHA256"; done=1}' "$U" > "$U.new" && cat "$U.new" > "$U"
  rm -f "$U.new"
  restart_smbd
  if testparm -s 2>/dev/null | grep -q 'server smb3 signing algorithms = AES-128-CMAC, HMAC-SHA256'; then
    say "samba: signing algorithms set to AES-128-CMAC, HMAC-SHA256"
  else
    warn "samba: the setting is not active. Either $U is ignored (it must contain the line '# samba.conf v4 (do not remove)' of the current samba.conf.sample) or it has no [global] section."
  fi
}

do_notrunc() {
  if [ "$USERSPACE" != armhf ]; then
    warn "notrunc: the prebuilt module is for 32-bit ARM (armhf) only; build files/smb-notrunc.c for $USERSPACE (see its header; untested). Skipped."; return
  fi
  if ! pgrep mount.exfat >/dev/null 2>&1 && [ -z "$FORCE" ]; then
    warn "notrunc: no exfat-fuse disk is mounted - skipped. Plug in the exFAT disk and run 'sh $SELF notrunc' again (FORCE=1 to install anyway; the module also acts on other FUSE mounts such as NTFS, which is untested)."; return
  fi
  cp "$F/smb-notrunc-armhf.so" $CFG/smb-notrunc.so && cp "$F/smb-notrunc.c" $CFG/smb-notrunc.c
  chmod 644 $CFG/smb-notrunc.so $CFG/smb-notrunc.c
  # must load cleanly into the real smbd: a missing symbol version (old glibc) would keep smbd from starting
  err=$(LD_PRELOAD=$CFG/smb-notrunc.so /usr/sbin/smbd -V 2>&1 >/dev/null) || err="${err:-smbd -V failed}"
  if [ -n "$err" ]; then
    warn "notrunc: the module cannot be loaded on this system ($(echo "$err" | head -n 1 | cut -c1-140)). Removed again."
    rm -f $CFG/smb-notrunc.so $CFG/smb-notrunc.c; return
  fi
  mkdir -p $SYSD/smbd.service.d
  cp "$F/smbd-notrunc.conf" $SYSD/smbd.service.d/notrunc.conf
  systemctl daemon-reload
  restart_smbd
  say "notrunc: installed (acts on FUSE-mounted disks; tested with exFAT via exfat-fuse)"
}

do_dhd() {
  if [ ! -d /sys/module/dhd ]; then warn "dhd: Broadcom bcmdhd driver (module 'dhd') is not loaded - skipped"; return; fi
  if ! grep -qi '0x02d0' /sys/bus/sdio/devices/*/vendor 2>/dev/null; then warn "dhd: no Broadcom SDIO WiFi chip found - skipped"; return; fi
  # Only the 100.10.x driver build (AP6275S / BCM43752 and relatives) uses the TX "copy" mode with a
  # 36-packet bundle. The older 1.363.x driver for AP6356S & co. works differently and was not tested.
  if ! grep -q 'Driver: 100\.10\.' /sys/module/dhd/parameters/info_string 2>/dev/null && [ -z "$FORCE" ]; then
    warn "dhd: driver is not bcmdhd 100.10.x ($(tr '\n' ' ' < /sys/module/dhd/parameters/info_string 2>/dev/null | cut -c1-60)) - untested, skipped (FORCE=1 to apply anyway)"; return
  fi
  BASE=/usr/lib/kernel-overlays/base/lib/firmware/brcm/config.txt
  OVR=$CFG/firmware/brcm/config.txt
  [ -f "$BASE" ] || { warn "dhd: $BASE not found - skipped"; return; }
  mkdir -p $CFG/firmware/brcm
  if [ ! -f "$STATE/dhd" ]; then
    # a file that starts with our own first line was made by this guide (by hand), not by the user
    if [ -f "$OVR" ] && [ "$(head -n 1 "$OVR")" != "txglomsize=16" ]; then cp -p "$OVR" "$OVR.pre-tuning"; echo existing > "$STATE/dhd"; else echo created > "$STATE/dhd"; fi
  fi
  SRC=$BASE; [ -f "$OVR" ] && SRC=$OVR      # keep whatever else is in the current override
  set -- $BIG
  {
    echo "txglomsize=16"
    if [ -n "$2" ]; then echo "dpc_cpucore=$1"; echo "rxf_cpucore=$2"; fi
    grep -vE '^(txglomsize|dpc_cpucore|rxf_cpucore)=' "$SRC" || [ $? -eq 1 ]
  } > "$OVR.new" && mv "$OVR.new" "$OVR"
  say "dhd: wrote $OVR ($(grep -E '^(txglomsize|dpc_cpucore|rxf_cpucore)=' "$OVR" | tr '\n' ' '))"
  REBOOT=yes
}

do_irq() {
  if [ -z "$BIG" ]; then warn "irq: no big.LITTLE CPU layout detected - skipped"; return; fi
  if ! awk '/bcmsdh_sdmmc/ || (/meson-aml-mmc/ && /GIC-0 221 /) {f=1} END {exit !f}' /proc/interrupts; then
    warn "irq: no SDIO WiFi interrupt found - skipped"; return
  fi
  cp "$F/wifi-irq-affinity.sh" $CFG/wifi-irq-affinity.sh; chmod 755 $CFG/wifi-irq-affinity.sh
  cp "$F/wifi-irq-affinity.service" $SYSD/wifi-irq-affinity.service
  systemctl daemon-reload
  systemctl enable wifi-irq-affinity.service >/dev/null 2>&1
  systemctl restart wifi-irq-affinity.service
  say "irq: SDIO WiFi interrupts are pinned to cpu$(echo $BIG | cut -d' ' -f1)"
}

do_watchdog() {
  if [ -z "$FORCE" ]; then
    gw=$(ip route 2>/dev/null | awk '$1 == "default" && $2 == "via" && $4 == "dev" && $5 == "wlan0" {print $3; exit}')
    if [ -z "$gw" ] || ! ping -c 2 -W 3 "$gw" >/dev/null 2>&1; then
      warn "watchdog: no default route on wlan0, or its gateway does not answer ping (wired box?) - skipped (FORCE=1 to install anyway)"; return
    fi
  fi
  cp "$F/wifi-watchdog.sh" $CFG/wifi-watchdog.sh; chmod 755 $CFG/wifi-watchdog.sh
  cp "$F/wifi-watchdog.service" $SYSD/wifi-watchdog.service
  if [ ! -f /storage/.cache/journald.conf.d/00_settings.conf ]; then
    mkdir -p /storage/.cache/journald.conf.d
    cp "$F/journald-persistent.conf" /storage/.cache/journald.conf.d/00_settings.conf
    echo created > "$STATE/journal"
    say "watchdog: persistent journal enabled (from the next reboot on)"
  fi
  systemctl daemon-reload
  systemctl enable wifi-watchdog.service >/dev/null 2>&1
  systemctl restart wifi-watchdog.service
  which iw >/dev/null 2>&1 || [ -x /storage/.kodi/addons/virtual.network-tools/bin/iw ] || warn "watchdog: 'iw' not found - install the add-on 'Network Tools' to get frequency/bit rate in the log"
  say "watchdog: running, log in /storage/wifi-debug/watchdog.log (it contains your SSID and addresses - blank them before posting)"
}

if [ $# -eq 0 ]; then sed -n '2,14p' "$SELF" | sed 's/^# \{0,1\}//'; exit 1; fi
for part in "$@"; do
  case "$part" in
    smb)      do_samba; do_notrunc ;;
    wifi)     do_dhd; do_irq ;;
    all)      do_samba; do_notrunc; do_dhd; do_irq; do_watchdog ;;
    samba)    do_samba ;;
    notrunc)  do_notrunc ;;
    dhd)      do_dhd ;;
    irq)      do_irq ;;
    watchdog) do_watchdog ;;
    *) warn "unknown part: $part" ;;
  esac
done
[ -n "$REBOOT" ] && say "Reboot the box to activate the WiFi driver settings."
say "Done. Run 'sh check.sh' to verify."
