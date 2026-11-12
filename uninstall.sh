#!/bin/sh
# uninstall.sh - removes what install.sh (or the by-hand steps of the guide) set up. Run on the box:
#
#   sh uninstall.sh all                       or single parts:  samba  notrunc  dhd  irq  watchdog
#
# A samba.conf or dhd config.txt that install.sh saved as <name>.pre-tuning is put back; the file as
# it was until then is kept as <name>.removed. Files this package did not create are left alone.
# The watchdog logs in /storage/wifi-debug are kept. A reboot is needed after removing "dhd".
# Public domain (CC0), no warranty.

CFG=/storage/.config
SYSD=$CFG/system.d
STATE=$CFG/smb-wifi-tuning
SELF=$0
REBOOT=""
say() { echo ">> $*"; }

restart_smbd() {
  /usr/lib/samba/samba-config
  if systemctl is-active smbd >/dev/null 2>&1; then systemctl restart smbd; say "smbd restarted"; fi
}

un_samba() {
  U=$CFG/samba.conf
  [ -f "$U" ] || { rm -f "$STATE/samba"; say "samba: nothing to do"; return; }
  OURS='/^[[:space:]]*server smb3 signing algorithms[[:space:]]*=[[:space:]]*AES-128-CMAC,[[:space:]]*HMAC-SHA256[[:space:]]*$/d'
  if [ -f "$U.pre-tuning" ]; then
    mv "$U" "$U.removed"; mv "$U.pre-tuning" "$U"
    sed -i "$OURS" "$U"      # in case the saved file came from the by-hand steps of the guide
    say "samba: restored your previous samba.conf (the file as it was until now is kept as samba.conf.removed)"
  else
    # remove only the exact line this package sets
    sed -i "$OURS" "$U"
    if [ "$(cat "$STATE/samba" 2>/dev/null)" = created ] && [ "$(md5sum < "$U")" = "$(md5sum < /etc/samba/smb.conf)" ]; then
      rm -f "$U"; say "samba: removed samba.conf (back to the stock configuration)"
    else
      say "samba: removed the signing line from samba.conf"
    fi
  fi
  rm -f "$STATE/samba"
  restart_smbd
}

un_notrunc() {
  rm -f $SYSD/smbd.service.d/notrunc.conf $CFG/smb-notrunc.so $CFG/smb-notrunc.c
  rmdir $SYSD/smbd.service.d 2>/dev/null
  systemctl daemon-reload
  restart_smbd
  say "notrunc: removed"
}

un_dhd() {
  OVR=$CFG/firmware/brcm/config.txt
  if [ -f "$OVR.pre-tuning" ]; then
    [ -f "$OVR" ] && mv "$OVR" "$OVR.removed"
    mv "$OVR.pre-tuning" "$OVR"
    say "dhd: restored your previous config.txt (the file as it was until now is kept as config.txt.removed)"
  elif [ ! -f "$OVR" ]; then
    rm -f "$STATE/dhd"; say "dhd: nothing to do"; return
  elif [ -f "$OVR.bak" ] && [ "$(head -n 1 "$OVR")" = "txglomsize=16" ]; then
    mv "$OVR" "$OVR.removed"; mv "$OVR.bak" "$OVR"
    say "dhd: put config.txt.bak (your own override from the by-hand setup) back; the tuned file is kept as config.txt.removed"
  elif [ "$(cat "$STATE/dhd" 2>/dev/null)" = created ] || [ "$(head -n 1 "$OVR")" = "txglomsize=16" ]; then
    # nothing but our three keys and the stock content? then there is nothing of yours to keep
    if [ "$(grep -vE '^(txglomsize|dpc_cpucore|rxf_cpucore)=' "$OVR" | md5sum)" = "$(md5sum < /usr/lib/kernel-overlays/base/lib/firmware/brcm/config.txt)" ]; then
      rm -f "$OVR"; say "dhd: removed the config.txt override"
    else
      mv "$OVR" "$OVR.removed"; say "dhd: removed the config.txt override (it contained changes of your own; kept as config.txt.removed)"
    fi
  else
    say "dhd: $OVR was not written by this package - left untouched"; return
  fi
  rm -f "$STATE/dhd"
  REBOOT=yes
}

un_irq() {
  systemctl disable --now wifi-irq-affinity.service >/dev/null 2>&1
  rm -f $SYSD/wifi-irq-affinity.service $CFG/wifi-irq-affinity.sh
  systemctl daemon-reload
  say "irq: removed (interrupts move back after the next reboot)"
}

un_watchdog() {
  systemctl disable --now wifi-watchdog.service >/dev/null 2>&1
  rm -f $SYSD/wifi-watchdog.service $CFG/wifi-watchdog.sh
  if [ "$(cat "$STATE/journal" 2>/dev/null)" = created ]; then
    rm -f /storage/.cache/journald.conf.d/00_settings.conf "$STATE/journal"
    say "watchdog: persistent journal switched off again (from the next reboot on)"
  fi
  systemctl daemon-reload
  say "watchdog: removed (logs stay in /storage/wifi-debug)"
}

if [ $# -eq 0 ]; then sed -n '2,8p' "$SELF" | sed 's/^# \{0,1\}//'; exit 1; fi
for part in "$@"; do
  case "$part" in
    all)      un_notrunc; un_samba; un_dhd; un_irq; un_watchdog ;;
    smb)      un_notrunc; un_samba ;;
    wifi)     un_dhd; un_irq ;;
    samba)    un_samba ;;
    notrunc)  un_notrunc ;;
    dhd)      un_dhd ;;
    irq)      un_irq ;;
    watchdog) un_watchdog ;;
    *) echo "!! unknown part: $part" ;;
  esac
done
rmdir "$STATE" 2>/dev/null
[ -n "$REBOOT" ] && say "Reboot the box to return to the stock WiFi driver settings."
say "Done."
