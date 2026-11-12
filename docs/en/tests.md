# What was measured and tested

Everything here comes from one box. Anything not listed was not measured. MB/s means MiB per second.

## Environment

- Box: Amlogic S922X, device tree `g12b_s922x_beelink_gt_king`, 4 GB RAM, CoreELEC 21.3-Omega Amlogic-ng (kernel 4.9.269, armhf userspace, glibc 2.38), Samba 4.19.9, fuse-exfat 1.2.8, Python 3.11.9.
- CPU: cpu0-1 Cortex-A53 (1.8 GHz), cpu2-5 Cortex-A73 (2.2 GHz), governor `performance`.
- WiFi: AP6275S / BCM43752, SDIO `02d0:aae8`, SDR104 at 200 MHz, driver 100.10.545.8, firmware 18.35.387.23.7 (own override; bundled is 18.35.387.11). Stock driver `config.txt`: `ccode`, `bcn_timeout=20`, `kso_enable=0`, `mimo_bw_cap=1`, `PM=0`, `nv_by_chip` table.
- Access point: WiFi 6, 5 GHz, 80 MHz, channel 108 for all series below; a second access point of another vendor sits on the same channel. Link rate as reported by `iw`: mostly 907–1080 Mbit/s, signal -50 to -55 dBm.
- Disk: 10 TB USB 3 hard disk, exFAT, 89 % full.
- PC: Windows 11 Pro 25H2, 2.5 GbE to the access point, `RequireSecuritySignature = True`, logged in with a Samba user.

## Step-by-step series (one evening, same access point and channel)

Raw TCP: 1 GiB with `tools/nettest.py`. SMB write: PowerShell `Copy-Item` of a 1 GiB file to the exFAT disk. SMB read: sequential .NET `FileStream` read of 1 GiB from a region of a large file the PC had not read before.

| State | Raw to box | Raw from box | SMB write | SMB read |
|---|---|---|---|---|
| Defaults (after `uninstall.sh all`, reboot) | 55.9, 53.5 | 46.0, 43.0 | 27.7, 27.0 | 23.8, 24.0 |
| + `install.sh samba` | 57.4, 57.6 | 49.0, 46.4 | 43.2, 42.8 | 37.3, 34.1 (first pair 18.7, 30.0 while the link rate was 216 Mbit/s; repeated) |
| + `install.sh notrunc` | | | 51.1, 50.8, 50.3 | |
| + `install.sh wifi watchdog`, reboot | 57.5, 57.9 | 45.6, 47.8 | 52.3, 52.2, 53.0 | 34.5, 27.3, 34.9 |
| Same final state, next morning | 53.6, 54.2, 52.2 | 46.8, 46.8, 46.0 | 49.2, 49.0, 48.0, 47.8 | 35.4, 35.1, 25.5, 35.4, 36.0, 35.9 |

## Whole-file copies (PowerShell `Copy-Item`, 2,708,703,477 bytes)

- Final setup, five runs: write 53.2, 53.6, 53.0, 54.4 MB/s in the evening and 49.1 the next morning; read (a different copy of the same file that was already on the disk) 43.6, 43.2, 42.7 MB/s.
- Each written file was hashed with `sha256sum` on the box and matched the source; each read-back copy matched on the PC.
- With part A alone (earlier the same day, same access point): write 38.5, read 40.7 MB/s.

## CPU observations (`tools/sample.py`)

- Default signing (GMAC), writes at 27 MB/s: the `smbd` child at 100 % of one A73 core.
- CMAC, writes at 54–56 MB/s on the wire: `smbd` 70–75 % of one A73 core, `mount.exfat` 12–16 %.
- CMAC, reads at 43 MB/s on the wire: `smbd` 58–67 %.
- `dhd_dpc` / `dhd_rxf` at full raw throughput: 22–25 % each on the A53 cores, 8–14 % each when pinned to A73 cores.
- With busybox `nc` as the box-side endpoint earlier in the day: 48.3 to the box, 43.2 from it (not back to back with `nettest.py`).

## Zero-fill

- 1 GiB `Copy-Item` without the module: about 4 consecutive seconds with 0 MB/s on the network and 141–151 MB/s of disk writes before the first data arrived; disk writes at that rate went on for about 4 more seconds in parallel with the incoming data.
- With the module: data arrives at once at 53–56 MB/s; total disk writes about 1 GiB.
- `ftruncate()` to 200 MiB / 50 MiB under `LD_PRELOAD`, both the 64-bit and the 32-bit variant of the call: skipped on the exFAT disk (size stays 0), passed through on tmpfs and ext4; shrinking works; a gap created by a write beyond the end reads back as zeros.
- Over SMB with the module, verified by SHA-256 on the box: a 64 MiB file pre-sized and then written in shuffled 1 MiB chunks, buffered and unbuffered; a 64 MiB file overwritten by a 3 MiB file; pre-size only (file stays at 0 bytes on the box, Windows shows the intended size for a moment from its own cache); pre-size plus 1 MiB written (1 MiB on the box).
- A sequential .NET `FileStream` write without pre-sizing, without the module: 16.6 MB/s (one run, not investigated).
- The armhf binary is reproducible: zig 0.17.1 builds a byte-identical file from `files/smb-notrunc.c`. The aarch64 branch of the source was only compile-checked.

## Negotiate failure with `AES-128-CMAC` alone

- Some hours after the last successful access Windows reported error 53 / 64. Packet capture: Windows sends a 73-byte SMB1-format negotiate, Samba answers 77 bytes, Windows resets; three attempts.
- Samba log level 3: `Requested protocol [NT LM 0.12] / [SMB 2.002] / [SMB 2.???]`, `Selected protocol SMB2_FF`, `smb2srv_negprot: SMB3 signing algorithm[0][HMAC-SHA256] on dialect[SMB2_10] not allowed by 'server smb3 signing algorithms' - NT_STATUS_INVALID_PARAMETER`.
- Reproduced on the box: `smbclient -L 127.0.0.1 -N --option='client min protocol=NT1' --option='client max protocol=SMB2_10'` fails with NT_STATUS_INVALID_PARAMETER with CMAC alone and lists the shares with `AES-128-CMAC, HMAC-SHA256`; `smbclient -m SMB3` works in both cases.

## Driver allocation failure

- Once, during a 2.7 GB SMB read with the stock `txglomsize=36`: seven times `dhd_dpc: page allocation failure: order:4, mode:0x24000c0(GFP_KERNEL)`, each followed by `sdioh_request_packet_chain: TX TXGLOM: localbuf malloc FAILED`. Free memory at that moment: 411 MB, as `10584*16kB 7556*32kB 0*64kB ...`; 2.88 GB of inactive file cache. The transfer continued and no WiFi outage followed.
- Fragmentation reproduced later: after reading 5 GB from the disk and a 2 GiB SMB read, `/proc/buddyinfo` showed 16 free 64 kB blocks with 611 MB free (Buffers 1311 MB, Cached 1361 MB). `compact_memory` changed nothing; `drop_caches` restored the large blocks (4070 x 64 kB). No allocation failure occurred in these runs with `txglomsize=36` either.
- With `txglomsize=16`: two stress runs (6 GB of cache, then 2 GiB SMB read and 2 GiB raw send), two boots with full test series (one of them running overnight) and several driver reloads: no failure.
- A/B by driver reload (threads pinned in both): 36: from box 49.7, 48.4, 49.3, to box 58.0. 16: from box 46.8, 47.5, 48.5, to box 57.9, 57.1.

## Watchdog

Outage simulated by an iptables rule that drops pings to the gateway; the WiFi link itself stayed up.

| Run | Script revision | Block lifted | Detected after | Result |
|---|---|---|---|---|
| 1 | first revision (German log texts) | 2 s after stage 3 began | 1 min 43 s | stages 1, 2 failed as expected; stage 3 ok 16 s after the block was lifted |
| 2 | second revision | 1 s after stage 3 began | 1 min 35 s | stages 1, 2 failed; stage 3 ok 18 s after the block was lifted |
| 3 | third revision | when stage 4 began | 1 min 41 s | stages 1, 2, 3 failed as expected; stage 4 (driver reload) ok 37 s after the block was lifted; driver settings and interrupt pinning were back afterwards |
| 4 | third revision | (WiFi switched off by hand with `connmanctl disable wifi`) | | after 4 minutes WiFi was still off; one log line "WiFi is switched off in the settings - watchdog stays idle" |
| 5 | revision in this package | when stage 4 began | 1 min 34 s | as run 3; stage 4 ok 34 s after the block was lifted; driver settings were back afterwards |
| 6 | revision in this package | (WiFi switched off by hand) | | as run 4: still off after 4 minutes, one idle log line |
| 7 | revision in this package | (watchdog stopped, WiFi switched off, marker file `.wifi-off` created, watchdog started) | | log line "WiFi was left switched off by an earlier run of the watchdog - switching it on"; WiFi on and link back within 5 s, marker removed |

Not exercised: a real driver hang; stage 3 succeeding in the last revision (its commands are unchanged); the "gateway has never answered" and "wired" idle paths; a failing `modprobe` in stage 4.

## Installer

- `uninstall.sh all`, reboot to the defaults (confirmed by `check.sh`), `install.sh samba`, `install.sh notrunc`, `install.sh wifi watchdog`, reboot, `check.sh` clean.
- With a `samba.conf` of my own (header spelled `[Global]`, own signing line in other capitals): saved as `.pre-tuning`, own line replaced, a line added after the install kept in `.removed`, original restored byte-identical by `uninstall.sh samba`.
- With a driver `config.txt` of my own: saved, merged (own keys kept), re-install idempotent, restored byte-identical. A foreign `config.txt` without an install record: left untouched by `uninstall.sh dhd`.
- State file present but `samba.conf` deleted: `install.sh samba` recreates it.
- The by-hand block of part C produces the same file as `install.sh dhd`. Run twice it does not back up its own file. With a `config.txt` of my own it saved that as `config.txt.bak` and kept my keys; `uninstall.sh dhd` put it back byte-identical.
- By-hand steps first, then the installer, then the uninstaller (parts A and C): nothing of the tuning is left active afterwards.
- A user line added to the generated `config.txt` survives a second `install.sh dhd`; `uninstall.sh dhd` then keeps the file as `config.txt.removed`.
- `install.sh smb` and `install.sh all` (over an existing install) run cleanly.
- `tools/windows/net-test.ps1` and `smb-test.ps1` (with `-Keep` and `-ReadFile`) run in the form shipped here.
- Five reboots in total, the last one with the final revision of all scripts; WiFi, services and driver settings came back each time, the chip interrupt was pinned within a minute of boot.
- The by-hand command blocks for parts A and B were run on the box exactly as printed (part B in a variant that writes the module from embedded base64 text instead of copying `files/smb-notrunc-armhf.so`).
- One night (about 13 hours) without reboot: 25 status lines, no outage, no channel change, no allocation failure.
- Persistent journal: since `/storage/.cache/journald.conf.d/00_settings.conf` exists, `journalctl --list-boots` lists every boot (seven so far). No real outage has occurred since, so the kernel log of one has not been looked up yet.

## Long-run observation

- Watchdog log since it was first started: no outage other than the simulated ones above. Stretches without any test or reboot: one night (about 13 hours, see above) and about 10 hours since the last reboot. Every status line reports 0 allocation failures.
- Kernel log of all seven boots in the persistent journal: `page allocation failure` seven times, all within one minute during the incident with the stock `txglomsize=36` described above, none afterwards.
- `check.sh`: 0 problems, 0 notes.
- Every file of the package on the box, and every copy `install.sh` placed in `/storage/.config`, has the same SHA-256 as the file in this repository. The journald setting in `/storage/.cache` existed before the package and was left alone by the installer, as designed (same settings, without the comment lines).
- `files/smb-notrunc-armhf.so` rebuilt on a Windows PC with zig 0.17.1 (`uv run --no-project --with ziglang==0.17.1 python -m ziglang cc ...`): byte-identical.
- Before these changes the box had been offline most of the time for weeks. The watchdog did not exist then, so that period has no log of this kind.

## Not tested

aarch64 userspace (Amlogic-ne/-no) and CoreELEC 22; any other SoC or WiFi chip; wired Ethernet; NTFS or FAT32 disks; clients other than Windows 11; `FORCE=1`; a glibc older than 2.34.
