#!/bin/sh
# wifi-watchdog.sh - WiFi watchdog for CoreELEC (connman). Public domain (CC0), no warranty.
#
# For a box whose network connection is WiFi and whose gateway answers ping.
#  - pings the gateway of the WiFi default route every 30 s
#  - logs channel changes, outages and kernel memory-allocation failures to /storage/wifi-debug/
#  - after 2 minutes without the gateway it saves a diagnostic snapshot and tries to recover:
#      stage 1  rescan and reconnect
#      stage 2  restart wpa_supplicant and connman
#      stage 3  drop the page cache, switch WiFi off and on (power-cycles the chip)
#      stage 4  reload the WiFi driver - only for the Broadcom driver build named in DRV_VERSION
#  - it never reboots the box
#  - it does nothing as long as the gateway has never answered, and it leaves WiFi alone when
#    you switched it off yourself
#
# watchdog.log and the snap-*.txt files contain your SSID, MAC/BSSID and IP addresses and the
# names of neighbouring networks. Blank them out before you post them anywhere.
#
# "iw" (CoreELEC add-on "Network Tools") is optional; without it frequency and bit rate are not logged.
#
# Remove:
#   systemctl disable --now wifi-watchdog.service
#   rm /storage/.config/system.d/wifi-watchdog.service /storage/.config/wifi-watchdog.sh

LOGDIR=/storage/wifi-debug
LOG=$LOGDIR/watchdog.log
IFACE=wlan0
INTERVAL=30
FAIL_LIMIT=4            # 4 x 30 s = 2 min without gateway -> outage
STATUS_EVERY=60         # one status line every 60 checks (30 min)
MAX_SNAPS=60
DRV_MODULE=dhd          # name in /sys/module of the WiFi driver; empty = never reload a driver
DRV_LOAD=dhd_sdio       # name to pass to modprobe
DRV_VERSION='100\.10\.' # stage 4 only if the loaded driver reports this version (bcmdhd for AP6275S)
PATH=$PATH:/storage/.kodi/addons/virtual.network-tools/bin

mkdir -p "$LOGDIR"

log() { [ -d "$LOGDIR" ] || mkdir -p "$LOGDIR"; echo "$(date '+%F %T') $*" >> "$LOG"; }

# gateway of the default route on the WiFi interface (empty if there is none)
wifi_gateway() { ip route 2>/dev/null | awk -v d="$IFACE" '$1 == "default" && $2 == "via" && $4 == "dev" && $5 == d {print $3; exit}'; }

link_ok() {
  g=$(wifi_gateway)
  if [ -n "$g" ]; then
    ping -c 2 -W 3 "$g" >/dev/null 2>&1 || return 1
    [ "$g" = "$(cat "$LOGDIR/.gateway" 2>/dev/null)" ] || echo "$g" > "$LOGDIR/.gateway"   # a gateway that answered
    return 0
  fi
  # no default route on WiFi: try the gateway that answered last
  [ -s "$LOGDIR/.gateway" ] && ping -c 2 -W 3 "$(cat "$LOGDIR/.gateway")" >/dev/null 2>&1
}

link_info() {
  iw dev $IFACE link 2>/dev/null | awk '
    /freq:/ {f=$2} /signal:/ {s=$2" "$3} /tx bitrate:/ {b=$3" "$4}
    END {printf "%s MHz, signal %s, %s", f, s, b}'
}

cur_freq() { iw dev $IFACE link 2>/dev/null | awk '/freq:/ {print $2; exit}'; }

# number of failed kernel memory allocations since boot
memerr() { dmesg | grep -c 'page allocation failure'; }

# remember the WiFi service that is connected (used for the reconnect in stage 1)
remember_service() {
  s=$(connmanctl services 2>/dev/null | awk '$1 ~ /^\*A[OR]/ && $NF ~ /^wifi_/ {print $NF; exit}')
  [ -n "$s" ] && [ "$s" != "$(cat "$LOGDIR/.service" 2>/dev/null)" ] && echo "$s" > "$LOGDIR/.service"
  return 0
}

service_id() {
  if [ -s "$LOGDIR/.service" ]; then cat "$LOGDIR/.service"; return; fi
  connmanctl services 2>/dev/null | awk '$1 ~ /^\*A/ && $NF ~ /^wifi_/ {print $NF; exit}'
}

# WiFi off and on. connman remembers "off" across reboots, so the time in between is marked: in
# WIFI_OFF and, to survive a reboot or a kill, in a marker file. That way a stop of the watchdog
# cannot leave WiFi switched off for good, and we can tell our own "off" from the user's.
OFF_MARK=$LOGDIR/.wifi-off
WIFI_OFF=""; [ -e "$OFF_MARK" ] && WIFI_OFF=1
trap '[ -n "$WIFI_OFF" ] && connmanctl enable wifi >/dev/null 2>&1; exit 0' TERM INT
wifi_powered() {   # $1 = True or False: does connman report this power state for WiFi?
  connmanctl technologies 2>/dev/null | awk -v p="Powered = $1" '/technology\/wifi$/ {w=1; next} /^\// {w=0} w && index($0, p) {f=1} END {exit !f}'
}
wifi_clear() { WIFI_OFF=""; rm -f "$OFF_MARK"; }
wifi_off() { WIFI_OFF=1; : > "$OFF_MARK"; connmanctl disable wifi >/dev/null 2>&1; }
wifi_on()  { connmanctl enable wifi >/dev/null 2>&1; sleep 2; wifi_powered True && wifi_clear; return 0; }

# true if WiFi is switched off in connman and it was not this script that did it
wifi_switched_off_by_user() { [ -z "$WIFI_OFF" ] && wifi_powered False; }

# remember whether the driver that stage 4 may reload is the one this script was written for
DRV_SEEN=""
drv_check() {
  [ -n "$DRV_MODULE" ] && [ -z "$DRV_SEEN" ] && grep -q "Driver: $DRV_VERSION" "/sys/module/$DRV_MODULE/parameters/info_string" 2>/dev/null && DRV_SEEN=1
  return 0
}

snapshot() {
  f="$LOGDIR/snap-$(date +%Y%m%d-%H%M%S)-$1.txt"
  {
    echo "### $1  $(date)"; uptime
    echo "### iw link";  iw dev $IFACE link
    echo "### iwconfig"; iwconfig $IFACE
    echo "### ip";       ip addr show $IFACE; ip route
    echo "### connman";  connmanctl technologies; connmanctl services
    echo "### /proc/net/wireless"; cat /proc/net/wireless
    echo "### scan (BSSID MHz dBm SSID)"
    iw dev $IFACE scan 2>&1 | awk '/^BSS/ {b=substr($2,1,17)} /freq:/ {f=$2} /signal:/ {s=$2} /SSID:/ {print b, f, s, $0}'
    echo "### memory (free blocks 4k..4M)"; cat /proc/buddyinfo; grep -E 'MemFree|^Buffers|^Cached' /proc/meminfo
    echo "### kernel allocation failures since boot: $(memerr)"
    echo "### dmesg";    dmesg | tail -200
    echo "### journal";  journalctl --no-pager -n 150 -u connman -u wpa_supplicant
  } > "$f" 2>&1
  ls -1t "$LOGDIR"/snap-*.txt 2>/dev/null | awk -v m=$MAX_SNAPS 'NR>m' | while read -r old; do rm -f "$old"; done
}

# $1 = seconds; checks every 10 s whether the link is back
wait_ok() {
  n=0
  while [ $n -lt "$1" ]; do
    sleep 10; n=$((n+10))
    link_ok && return 0
  done
  return 1
}

stage_result() {
  if wait_ok "$2"; then log "Stage $1 ok: link is back"; return 0; fi
  log "Stage $1 failed"; snapshot "stage$1-failed"; return 1
}

recover() {
  svc=$(service_id)
  drv_check

  log "Stage 1: rescan and reconnect"
  connmanctl scan wifi >/dev/null 2>&1
  [ -n "$svc" ] && ( connmanctl connect "$svc" >/dev/null 2>&1 ) &
  stage_result 1 60 && return 0

  log "Stage 2: restart wpa_supplicant and connman"
  systemctl restart wpa_supplicant
  systemctl restart connman
  stage_result 2 90 && return 0

  # Dropping the page cache gives the kernel large contiguous memory blocks again. exfat-fuse
  # fills the RAM with block-device cache that the kernel can hardly move, and a WiFi driver
  # may then fail to allocate its buffers when it restarts.
  log "Stage 3: drop page cache, WiFi off/on (connmanctl disable/enable wifi)"
  sync; echo 1 > /proc/sys/vm/drop_caches
  wifi_off; sleep 5
  wifi_on
  stage_result 3 120 && return 0

  if [ -n "$DRV_SEEN" ]; then
    log "Stage 4: reload driver (rmmod $DRV_MODULE, modprobe $DRV_LOAD)"
    wifi_off; sleep 3
    [ -d "/sys/module/$DRV_MODULE" ] && rmmod "$DRV_MODULE" 2>>"$LOG"; sleep 3
    modprobe "$DRV_LOAD" 2>>"$LOG"; sleep 15
    wifi_on
    stage_result 4 120 && return 0
  fi

  log "All stages failed"
  return 1
}

drv_check
log "Watchdog started (interval ${INTERVAL}s, outage after $FAIL_LIMIT failed checks)"
if [ -n "$WIFI_OFF" ]; then log "WiFi was left switched off by an earlier run of the watchdog - switching it on"; wifi_on; fi
fails=0; down_since=""; last_freq=""; count=0; connected=""; idle_note=""

while true; do
  if link_ok; then
    if [ -n "$down_since" ]; then
      log "Link back online (outage since $down_since)"
      down_since=""
    fi
    fails=0; idle_note=""
    f=$(cur_freq)
    if [ -n "$f" ] && [ "$f" != "$last_freq" ]; then
      if [ -n "$last_freq" ]; then log "Channel change: $last_freq MHz -> $f MHz"
      else log "Connected: $(link_info)"; fi
      last_freq=$f
    elif [ -z "$f" ] && [ -z "$connected" ]; then
      log "Connected (install the Network Tools add-on to log frequency and bit rate)"
    fi
    connected=1
    [ -n "$WIFI_OFF" ] && wifi_powered True && wifi_clear
    remember_service
    drv_check
    count=$((count+1))
    if [ $((count % STATUS_EVERY)) -eq 0 ]; then log "Status ok: $(link_info), alloc failures $(memerr)"; fi
  else
    fails=$((fails+1))
    if [ $fails -ge $FAIL_LIMIT ]; then
      gwnow=$(wifi_gateway)
      if [ ! -s "$LOGDIR/.gateway" ] || { [ -n "$gwnow" ] && [ "$gwnow" != "$(cat "$LOGDIR/.gateway")" ]; } ||
         { [ -z "$gwnow" ] && ip route 2>/dev/null | grep -q '^default .* dev eth'; }; then
        # this gateway has never answered a ping (cannot tell an outage from a silent gateway),
        # or the box is on a wired connection
        [ -n "$idle_note" ] || log "The gateway on $IFACE has never answered a ping, or the box is wired - watchdog stays idle"
        idle_note=1; fails=0
      elif wifi_switched_off_by_user; then
        [ -n "$idle_note" ] || log "WiFi is switched off in the settings - watchdog stays idle"
        idle_note=1; fails=0
      else
        if [ -z "$down_since" ]; then
          down_since=$(date '+%F %T')
          log "OUTAGE detected (last on ${last_freq:-?} MHz)"
          snapshot outage
        fi
        if recover; then
          fails=0
        else
          log "Next attempt in 10 minutes"
          sleep 600
        fi
        continue
      fi
    fi
  fi
  sleep $INTERVAL
done
