# CoreELEC 21 (Amlogic-ng): slow Samba copies from Windows 11 24H2 (SMB signing, exFAT zero-fill), and notes on the AP6275S WiFi driver

Copying a file from a Windows 11 PC to an exFAT USB disk on my CoreELEC box went from **27 MB/s to 51–53 MB/s**, and a plain sequential read from 24 to 35 MB/s, without touching the PC. The network was not the limit: raw TCP over the same WiFi link did 54–58 MB/s to the box and 43–49 MB/s from it all along. Two things in the software stack were eating the rest. A third one is a WiFi driver weakness I ran into on the way.

| Step (same box, same AP, same evening) | Write: `Copy-Item` of a 1 GiB file to the exFAT disk | Read: sequential read of 1 GiB the PC had not cached |
|---|---|---|
| CoreELEC 21.3 defaults | 27 MB/s | 24 MB/s |
| A: Samba signing algorithm | 43 MB/s | 34–37 MB/s |
| A + B: `smb-notrunc` (no zero-fill) | 51 MB/s | not measured (the module does not touch reads) |
| A + B + C: WiFi driver settings | 52–53 MB/s | 35 MB/s (one run of three: 27) |
| Raw TCP over the same link, for reference | 54–58 MB/s | 43–49 MB/s |

Row A, read: a first pair of runs (19 and 30 MB/s) fell into a moment when the WiFi link rate had dropped to 216 Mbit/s and was repeated. The next morning the same final setup gave 48–49 MB/s write and 35 MB/s read on a raw link of 52–54 MB/s; the numbers move with the WiFi link.

A whole 2.7 GB movie copied with PowerShell `Copy-Item` (the same copy engine as Explorer, which I did not time itself): 53–54 MB/s write, 43 MB/s read. The 43 is not comparable with the read column above, the copy engine reads faster than a plain sequential read; with part A alone it was 40.7 MB/s, and I have no figure for the defaults with that method. Every whole-file copy was verified with SHA-256: written files on the box, read-back copies on the PC.

Part C does not make anything faster (the differences are within run-to-run noise). It is meant to avoid a memory-allocation failure in the WiFi driver that I saw once and could not reproduce on demand.

This is for people who stay on CoreELEC 21.3, the last release for Amlogic-ng. CoreELEC 22 (Amlogic-no, aarch64 userspace, newer AP6275S driver) should not need parts A and C; part B probably still applies. I have not tested 22.

## Quick start

On the PC, in the folder of this repository, copy the scripts to the box (`ssh` and `scp` are part of Windows 11):

```
ssh root@<box-ip> mkdir -p /storage/coreelec-smb-wifi-tuning
scp -r install.sh uninstall.sh check.sh files tools root@<box-ip>:/storage/coreelec-smb-wifi-tuning/
```

Then on the box, over SSH:

```sh
cd /storage/coreelec-smb-wifi-tuning
sh check.sh               # what applies to this box, what is active
```

Then pick what you need:

```sh
sh install.sh smb         # parts A + B, active at once (restarts smbd: running copies are cut)
sh install.sh wifi        # part C, active after a reboot
sh install.sh watchdog    # part D
sh install.sh all         # everything that applies to this box
```

And to remove it again:

```sh
sh uninstall.sh all       # back to the defaults (reboot afterwards for the WiFi part)
```

Do not edit the scripts with a Windows editor: Windows line endings break shell scripts.

The installer checks what fits the box (userspace, mounted exfat-fuse disk, driver version, CPU layout, WiFi as the default route) and skips the rest with a message. Everything it writes lives in `/storage/.config`, plus one journald setting in `/storage/.cache` and the watchdog logs in `/storage/wifi-debug`, which the uninstaller keeps. A `samba.conf` or driver `config.txt` of your own is kept as `<name>.pre-tuning` and put back by the uninstaller; the file as it was at uninstall time is then kept as `<name>.removed`. Files the package did not create are left alone.

What I ran on my box: uninstall, reboot to the defaults, install part by part with measurements in between, reboot, `check.sh`. Also install and uninstall with a pre-existing `samba.conf` and `config.txt` of my own (restored byte-identical; a later edit was kept in `.removed`), with a foreign `config.txt` (left untouched), after the by-hand steps of this guide, and re-install over an existing install. [tests.md](tests.md) has the list. Not tested: `FORCE=1`, and anything on another box.

## Test setup

- Box: Amlogic S922X (device tree `g12b_s922x_beelink_gt_king`), 4 GB RAM, official CoreELEC 21.3-Omega **Amlogic-ng** (kernel 4.9.269, 32-bit userspace), Samba 4.19.9, fuse-exfat 1.2.8.
- WiFi: AP6275S (BCM43752, SDIO ID `02d0:aae8`), driver `dhd_sdio` 100.10.545.8. Firmware 18.35.387.23.7, which I had installed earlier in `/storage/.config/firmware/brcm` in place of the bundled 18.35.387.11; it is not part of this package and stayed in place for all measurements, including the "defaults" row. WiFi 6 access point, 5 GHz, 80 MHz channel shared with a second access point, link rate 907–1080 Mbit/s, signal -50 to -55 dBm.
- Disk: 10 TB USB 3 hard disk, exFAT.
- PC: Windows 11 Pro 25H2, wired to the access point with 2.5 GbE, SMB signing required (the default), logged in with a Samba user and password.

I measured on this one box only. Where I generalise below, I say what the generalisation rests on.

## Is my box affected?

`sh check.sh` tells you. By hand, on the box:

```sh
ls /lib/ld-linux-armhf.so.3          # exists = 32-bit userspace (Amlogic-ng)             -> part A can apply
ps | grep '[m]ount.exfat'            # a line with your disk = mounted by exfat-fuse      -> part B applies
cat /sys/module/dhd/parameters/info_string   # "Driver: 100.10.545.x" = AP6275S driver    -> part C applies
```

And on the PC, in PowerShell: `Get-SmbClientConfiguration | fl RequireSecuritySignature` (True = the PC signs all SMB traffic).

| Part | Affected | Not affected / unknown |
|---|---|---|
| A: Samba signing | Both must be true: (1) the box has a 32-bit ARM userspace, i.e. **Amlogic-ng** (S905X/D/W, S905X2/Y2, S922X, A311D, S905X3/D3, S905X4), and (2) the PC signs its SMB traffic, which only happens when you log on to the box with a user name and password. Windows 11 24H2 and newer require signing by default on Pro, Enterprise and Education and then refuse guest logons. Checked for CoreELEC 21 only (Samba 4.19.9); the setting and GMAC signing exist from Samba 4.15 on. It is a CPU limit of `smbd`, so I expect it on wired boxes as well (not measured). | Shares used without a password (guest access): never signed, part A changes nothing. Amlogic-ne and Amlogic-no: aarch64 userspace, where GnuTLS has code for the CPU's AES/PMULL instructions; not tested by me. |
| B: `smb-notrunc` | Disks mounted through **exfat-fuse** and written by the Windows copy engine via Samba. That is every exFAT disk on Amlogic-ng (its kernel has no exFAT driver). fuse-exfat is also packaged for Amlogic-ne/-no, so they are probably affected too. | NTFS disks (ntfs-3g) are FUSE mounts as well; I have no evidence that they zero-fill and did not test them. FAT32 has the same root cause but uses the kernel driver, which the module does not touch. ext4 has no such problem. On an aarch64 userspace you have to build the module yourself (untested). |
| C: WiFi driver | CoreELEC 21 Amlogic-ng with the `dhd_sdio` **100.10.545.x** driver: AP6275S / BCM43752 (e.g. the WiFi 6 revisions of Beelink GT-King and GT-King Pro). The CPU pinning only makes sense on big.LITTLE SoCs (S922X, A311D). | Boxes with AP6356S, AP6398S, AP6256 etc. use another driver version with different defaults. CoreELEC 22 ships driver 101.10.591.x, which allocates the buffer in question once at start-up. |
| D: Watchdog | A CoreELEC box whose network connection is WiFi and whose gateway answers ping. The driver reload (last stage) only runs with the 100.10.x Broadcom driver. | Wired boxes: not meant for them, the installer skips it. |

## Part A: Samba signing algorithm

**What happens.** Windows 11 24H2 and newer sign every SMB packet (Pro, Enterprise, Education by default). Windows 11 offers three signing algorithms and lists AES-128-GMAC first. Samba picks by its own preference order, and its default list is `AES-128-GMAC, AES-128-CMAC, HMAC-SHA256`, so GMAC wins. Samba does its crypto through GnuTLS and nettle. In a 32-bit ARM build neither has code for the ARMv8 crypto instructions, so GHASH (the core of GMAC) runs as generic C code. On my box `smbd` sat at 100 % of one core at 27 MB/s. With AES-128-CMAC the same core handles 55 MB/s at 70–75 %.

CMAC is still AES in software. Extrapolating from those figures, one 2.2 GHz A73 core would top out at roughly 75 MB/s and slower cores lower, so on gigabit Ethernet signing would remain the limit, only a higher one. I did not measure that.

**Fix.** Tell Samba to prefer CMAC and drop GMAC:

```
server smb3 signing algorithms = AES-128-CMAC, HMAC-SHA256
```

The connection is still fully signed.

**Do not leave out HMAC-SHA256.** I first set `AES-128-CMAC` alone. That worked for a few hours and then Windows reported "network path not found" (error 53, then 64). In the capture of the failing attempt Windows started with an old-style multi-protocol negotiate. Samba answers that through its SMB 2.1 code path, whose only signing algorithm is HMAC-SHA256, and refuses if that is not in the list (log level 3: `SMB3 signing algorithm[0][HMAC-SHA256] on dialect[SMB2_10] not allowed by 'server smb3 signing algorithms'`). My explanation for the delay, which I did not capture: Windows uses that negotiate only when it has no remembered negotiation with the server (MS-SMB2 note <130>), and negotiates SMB 3.1.1 directly otherwise, which works with CMAC alone. `check.sh` tests both ways.

By hand:

```sh
[ -f /storage/.config/samba.conf ] || cp /etc/samba/smb.conf /storage/.config/samba.conf
sed -i '/^[[:space:]]*server smb3 signing algorithms/d' /storage/.config/samba.conf
sed -i '/^\[global\]/a\  server smb3 signing algorithms = AES-128-CMAC, HMAC-SHA256' /storage/.config/samba.conf
/usr/lib/samba/samba-config && systemctl restart smbd      # drops open SMB connections
testparm -s 2>/dev/null | grep 'signing algorithms'
# must print:  server smb3 signing algorithms = AES-128-CMAC, HMAC-SHA256
# prints nothing: the line was not inserted (your section header is not spelled exactly [global] at the
#   start of a line - add the line below it by hand), or your samba.conf is ignored (it must keep its
#   line "# samba.conf v4 (do not remove)")
# prints another list: your file sets the parameter itself in another spelling - delete that line
smbclient -L 127.0.0.1 -N --option='client min protocol=NT1' --option='client max protocol=SMB2_10' | head -4
# first-contact test: must list the shares. NT_STATUS_INVALID_PARAMETER = HMAC-SHA256 is missing from the list.
# (A line "No compatible protocol selected by server" next to the share list is harmless.)
```

Undo: delete the line from `/storage/.config/samba.conf` (or the whole file if you had none before), then `/usr/lib/samba/samba-config && systemctl restart smbd`.

## Part B: `smb-notrunc`, no zero-fill on exFAT

**What happens.** Before the Windows copy engine (Explorer, `Copy-Item`) writes the first byte of a copy it sets the destination file to its final size. Samba turns that into `ftruncate()`. exfat-fuse can only grow a file by writing zeros over the whole new range. So every file is written twice: zeros first, then the data. With a 1 GiB file the box wrote zeros at about 150 MB/s for 4 seconds before any data arrived, and for some seconds more in parallel with it; `tools/sample.py` shows it second by second. There is no smb.conf switch for this: `strict allocate = no` is already the default and does not avoid the `ftruncate()`. The Samba developers discussed exactly this in December 2020 ([Samba + exFAT: how to avoid pre-allocating when copying big files?](https://lists.samba.org/archive/samba-technical/2020-December/136068.html)) and concluded that the proper fix belongs in the exFAT driver. exfat-fuse still zero-fills in its current version.

**Workaround.** `smb-notrunc.so` is a small `LD_PRELOAD` module for `smbd` (about 40 lines of C). It replaces `ftruncate()`: a call that would only *grow* a regular file on a FUSE filesystem returns success without doing anything. The file then grows with the writes that follow. Shrinking a file, and all other filesystems, are passed through unchanged.

**Side effects, read this.**
- A file that a program only pre-sizes over SMB and never writes stays empty or shorter instead of being padded with zeros. For a normal copy this never shows.
- If the disk runs full, Windows learns it during the copy instead of at its start.
- Writes that arrive out of order still work: exfat-fuse zero-fills the gap when a write lands beyond the current end. I tested that, plus overwriting a larger file with a smaller one, with checksums.
- The Samba developers called faking the file length risky. I accept that for a media disk; decide for yourself.
- It acts on every FUSE mount Samba serves. I only tested exfat-fuse.
- All figures are for copies made by the Windows copy engine, which pre-sizes the file. A program that wrote a file sequentially without pre-sizing it reached only 16.6 MB/s in one test without the module; I did not look into that further.
- If you report a Samba problem on the CoreELEC forum, remove the module first and reproduce without it.

By hand (32-bit userspace, glibc 2.34 or newer, i.e. CoreELEC 21):

```sh
cp files/smb-notrunc-armhf.so /storage/.config/smb-notrunc.so
LD_PRELOAD=/storage/.config/smb-notrunc.so /usr/sbin/smbd -V     # must print only the version, no error
```

Go on only if that printed nothing but the version line. If it prints an error, delete the file again: with a glibc older than 2.34 `smbd` would not start with the module.

```sh
mkdir -p /storage/.config/system.d/smbd.service.d
cp files/smbd-notrunc.conf /storage/.config/system.d/smbd.service.d/notrunc.conf
systemctl daemon-reload && systemctl restart smbd
grep -c smb-notrunc /proc/$(cat /run/samba/smbd.pid)/maps      # greater than 0 = loaded
```

If the file is merely missing or built for another architecture, the loader prints a warning and `smbd` starts without it. Being listed in `/proc/PID/maps` only shows that the module is loaded; `check.sh` also tests that a pre-size is really skipped.

Undo: `rm /storage/.config/system.d/smbd.service.d/notrunc.conf /storage/.config/smb-notrunc.so; systemctl daemon-reload; systemctl restart smbd`.

The binary is built from `files/smb-notrunc.c` (SHA-256 of `smb-notrunc-armhf.so`: `378630e7e7506660183fd1a5411df01cbc1f3a8548f8b0144fa04579342eebac`). To build it yourself, on any PC with zig (0.17.1 reproduces my file byte for byte, so you can compare the checksum):

```sh
zig cc -target arm-linux-gnueabihf.2.34 -mcpu=cortex_a53 -shared -fPIC -O2 -s -o smb-notrunc-armhf.so smb-notrunc.c
```

## Part C: WiFi driver settings (AP6275S, driver 100.10.545.x)

**What I found.** Once, during a 2.7 GB read from the box, the kernel logged seven times

```
dhd_dpc: page allocation failure: order:4, mode:0x24000c0(GFP_KERNEL)
sdioh_request_packet_chain: TX TXGLOM: localbuf malloc FAILED
```

This driver build bundles up to 36 outgoing packets into one SDIO transfer and copies them into a freshly allocated buffer each time, about 58 kB, which the kernel serves as one contiguous 64 kB block. exfat-fuse does all its disk I/O through the block-device page cache ("Buffers" in `/proc/meminfo`). On kernel 4.9 those pages are placed in unmovable memory areas, and compaction can hardly move them. After a few GB of disk I/O the free memory was 400–600 MB but split into 16 and 32 kB pieces, with almost no 64 kB block left (`cat /proc/buddyinfo`). The kernel gives up on an allocation of that size after one reclaim and compaction attempt. The driver then falls back to sending the packets one by one. In my test `echo 1 > /proc/sys/vm/compact_memory` changed nothing, while `echo 1 > /proc/sys/vm/drop_caches` brought the large blocks back.

I cannot show that this causes WiFi drop-outs. The transfer went on, and I found no other report of these log lines. But it is an avoidable failure in the transmit path, and newer versions of the driver (101.10.361 and later, as in CoreELEC 22) allocate that buffer once at start-up.

**Settings.** The driver reads `config.txt` next to its firmware. A file in `/storage/.config/firmware/brcm/` overrides the stock one. By hand:

```sh
D=/storage/.config/firmware/brcm; mkdir -p $D
SRC=/usr/lib/kernel-overlays/base/lib/firmware/brcm/config.txt
# an override of your own (not one written by this block) is saved once and used as the base
[ -f $D/config.txt ] && [ ! -f $D/config.txt.bak ] && ! grep -q '^txglomsize=16$' $D/config.txt && cp -p $D/config.txt $D/config.txt.bak
[ -f $D/config.txt.bak ] && SRC=$D/config.txt.bak
{ echo txglomsize=16
  echo dpc_cpucore=2        # S922X / A311D only (cpu2 and cpu3 are Cortex-A73 cores):
  echo rxf_cpucore=3        # on other SoCs delete these two lines
  grep -vE '^(txglomsize|dpc_cpucore|rxf_cpucore)=' $SRC
} > $D/config.txt
cat $D/config.txt
```

Look at the result before you reboot: it must show the new lines followed by the stock content (`ccode=...`, the `nv_by_chip` table that selects the NVRAM file for your chip). Then reboot, and afterwards `dmesg | grep -E 'txglomsize=|cpucore'` must show `txglomsize=16`. If WiFi does not come back, connect Ethernet (or use the Kodi file manager with hidden files shown), delete `/storage/.config/firmware/brcm/config.txt` and reboot. Undo: if you had a `config.txt` of your own before (the block saved it as `config.txt.bak`), move that back; otherwise delete `config.txt`. Then reboot. `sh uninstall.sh dhd` does the same. To change the values, run the block again.

- `txglomsize=16`: at most 16 packets per bundle, about 26 kB, which fits a 32 kB block. The kernel keeps retrying allocations up to that size, so in practice they do not fail. With 16 I had no failure in two boots (one of them running overnight), several driver reloads and two stress runs (6 GB of page cache, then 2 GiB reads). That is weak proof: I could not provoke the failure again with the stock value 36 either, with memory just as fragmented. The argument for 16 comes from the driver and kernel source, not from a before/after test. Raw throughput with 16 was within noise of 36 (from the box 46.8–48.5 vs 48.4–49.7 MB/s, three runs each; to the box 57–58 MB/s either way).
- `dpc_cpucore` / `rxf_cpucore`: pin the two driver threads to big cores. `files/wifi-irq-affinity.sh` does the same for the SDIO interrupts, which otherwise all land on cpu0, a Cortex-A53. This roughly halved the CPU share of the driver threads (22–25 % of an A53 core each before, 8–14 % of an A73 core each after, at full speed) but did not change throughput beyond noise. Optional.

## Part D: WiFi watchdog

Install it only on a box that is on WiFi and whose gateway answers ping. `files/wifi-watchdog.sh` pings the gateway of the WiFi default route every 30 seconds and writes `/storage/wifi-debug/watchdog.log`: channel changes, a status line every 30 minutes including the number of kernel allocation failures, and outages. After four failed checks (1.5 to 2 minutes) without the gateway it saves a snapshot (link state, scan, memory fragmentation, kernel log) and tries, in this order: reconnect; restart `wpa_supplicant` and `connman`; drop the page cache and switch WiFi off and on; reload the driver (only with the 100.10.x Broadcom driver). It never reboots. It stays idle as long as the gateway has never answered a ping, on a wired connection, and when you switched WiFi off yourself. While your router is off it cannot know that and repeats its stages about every 15 minutes.

`watchdog.log` and the `snap-*.txt` files contain your SSID, MAC/BSSID and IP addresses and the names of neighbouring networks. Blank them out before you post them anywhere.

How I tested it: by blocking pings to the gateway with iptables, four times, lifting the block when stage 3 or stage 4 began; by switching WiFi off by hand (it stays off); and by simulating a watchdog that died between its own WiFi off and on (the next start switches it back on). See [tests.md](tests.md) for the timings. A blocked ping is not a driver hang: these tests show that detection, logging and the stage sequence work, not that any stage cures a real outage.

`install.sh watchdog` also switches on the persistent journal (`/storage/.cache/journald.conf.d/00_settings.conf`, only if that file does not exist yet), so that the kernel log of an outage is still there after the reboot that usually follows it. On my box the journal has kept every boot since that file exists; I have not had a real outage to look up yet.

Undo: `sh uninstall.sh watchdog` (also removes the journal setting if the installer created it), or by hand: `systemctl disable --now wifi-watchdog.service; rm /storage/.config/system.d/wifi-watchdog.service /storage/.config/wifi-watchdog.sh` (the logs stay in `/storage/wifi-debug`).

Whether any of this cures the "WiFi does not come back after a while" problem my box had is not proven. Since the newer firmware, a WiFi 6 access point and parts C and D are in place, the box has not lost WiFi once (status in the [README](../../README.md)). The watchdog keeps logging, so that a next outage, if there is one, shows whether a channel change or an allocation failure came first.

## Measuring it yourself

Measure the raw link first, otherwise you do not know what to expect from Samba. Start the box side first; it waits 30 seconds for the PC.

```sh
# box:  python3 tools/nettest.py sink 5201                     PC:  .\tools\windows\net-test.ps1 -Box <box> -Dir up
# box:  python3 tools/nettest.py source 5201 1073741824        PC:  .\tools\windows\net-test.ps1 -Box <box> -Dir down
# box, while a copy runs:  python3 tools/sample.py 30 wlan0 sda
# PC:   .\tools\windows\smb-test.ps1 -Share \\<box>\<share> -File D:\big.mkv -ReadFile '\\<box>\<share>\some\other-big-file.mkv'
```

If PowerShell answers "running scripts is disabled on this system" (the Windows default), start the scripts like this: `powershell -ExecutionPolicy Bypass -File .\tools\windows\net-test.ps1 -Box <box> -Dir up`.

`sample.py` prints one line per second: network and disk throughput, load per core, and the busiest threads with the core they ran on. That is how the zero-fill phase and the saturated `smbd` showed up. `smb-test.ps1` reads with `Copy-Item`, so its read figure corresponds to the whole-file numbers above, not to the read column of the table.

## Tips and pitfalls

- **I stopped using busybox `nc` for throughput tests.** Earlier in the day it gave 48 MB/s to the box where `nettest.py` later measured 54–58 on the same access point. Not a back-to-back comparison, but I suspect `nc` itself was the limit.
- **Read tests lie easily.** Windows answers from its own cache if it has read or written the file recently. Read a file the PC has not touched.
- **WiFi rates wander.** Single runs were 15–50 % low; in the one case I checked, the link rate had dropped to 216 Mbit/s. Repeat runs and look at `iw dev wlan0 link`.
- **Windows 11 24H2 and guests.** Required signing also switches off guest logons. Set a Samba user and password in the CoreELEC settings instead of weakening Windows.
- **`paste` on CoreELEC uploads.** `/usr/bin/paste` is not the coreutils tool, it posts its input to paste.coreelec.org and prints the link. Handy for logs, bad for anything private.
- **Missing tools.** CoreELEC has no `smbstatus`, `taskset`, `diff`, `cmp`, `base64` or `timeout`. `python3` is there and covers most of it.
- **Two access points on one channel** share the air time. Put them on different channels if you can.
- **WiFi 6 with this chip** depends on the firmware. My box runs 18.35.387.23.7 and reports HE rates; see forum topic 59423 for the bundled firmware being limited to WiFi 5 rates and for newer firmware on CoreELEC 22.
- For moving terabytes, plugging the disk into the PC is still several times faster than any of this.

## References

- Samba `smb.conf(5)`, `server smb3 signing algorithms`; `source3/smbd/smb2_negprot.c` and `libcli/smb/util.c` (`smb311_capabilities_check`) in Samba 4.19.9.
- Microsoft: "Control SMB signing behavior", "SMB security enhancements" (AES-128-GMAC), MS-SMB2 section 3.2.4.2.2 and note <130> (multi-protocol negotiate).
- samba-technical, December 2020: "Samba + exFAT: how to avoid pre-allocating when copying big files?"; Samba bug 6976; relan/exfat issue 45; `exfat_truncate(..., erase=true)` in `fuse/main.c`.
- `bcmsdh_sdmmc.c` (`sdioh_request_packet_chain`) and `dhd_config.c` in CoreELEC/ap6xxx-aml, bcmdhd.100.10.545.x.
- Linux 4.9: `fs/block_dev.c` (`bdget`, `GFP_USER`), `mm/page_alloc.c` (`PAGE_ALLOC_COSTLY_ORDER`).

## Licence and warranty

Scripts and `smb-notrunc.c` are public domain (CC0), see [LICENSE](../../LICENSE). No warranty. This is not an official CoreELEC package; please do not ask the CoreELEC team to support it.
