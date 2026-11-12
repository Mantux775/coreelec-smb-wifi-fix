#!/bin/sh
# wifi-irq-affinity.sh - move the SDIO WiFi interrupts to a fast CPU core (big.LITTLE SoCs)
# Public domain (CC0), no warranty.
#
# On S922X / A311D the two Cortex-A53 cores are cpu0-1 and the four Cortex-A73 cores are
# cpu2-5. By default all interrupts land on cpu0, i.e. the whole WiFi receive path runs on
# a slow core. This script pins the interrupt of the SDIO controller and the wake-up line
# of the Broadcom chip to the first big core. The driver threads dhd_dpc / dhd_rxf are
# pinned by the driver itself (dpc_cpucore / rxf_cpucore in the dhd config.txt).
#
# The chip interrupt is re-created on every driver start, hence the loop.
#
# Remove:
#   systemctl disable --now wifi-irq-affinity.service
#   rm /storage/.config/system.d/wifi-irq-affinity.service /storage/.config/wifi-irq-affinity.sh

CPU=""          # set a core number to override auto-detection, e.g. CPU=2
INTERVAL=20

# first core that is not a Cortex-A53 (CPU part 0xd03); empty if all cores are the same
detect_big() {
  awk -F: '/^processor/ {p=$2+0} /^CPU part/ {gsub(/[ \t]/, "", $2); part[p]=$2; seen[$2]=1}
    END { n=0; for (k in seen) n++; if (n < 2) exit
          for (i=0; i<64; i++) if ((i in part) && part[i] != "0xd03") { print i; exit } }' /proc/cpuinfo
}

[ -n "$CPU" ] || CPU=$(detect_big)
[ -n "$CPU" ] || { echo "no big.LITTLE layout detected - nothing to do"; exit 0; }
MASK=$(printf '%x' $((1 << CPU)))
echo "pinning SDIO WiFi interrupts to cpu$CPU (mask $MASK)"

while true; do
  # "bcmsdh_sdmmc" = wake-up line of the Broadcom chip, "GIC-0 221" = SDIO controller (sd_emmc_a) on G12A/G12B/SM1
  for irq in $(awk '/bcmsdh_sdmmc/ || (/meson-aml-mmc/ && /GIC-0 221 /) {sub(":", "", $1); print $1}' /proc/interrupts); do
    [ "$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null)" = "$CPU" ] || echo $MASK > /proc/irq/$irq/smp_affinity 2>/dev/null
  done
  sleep $INTERVAL
done
