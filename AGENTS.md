# AGENTS.md

Instructions for AI coding agents and human contributors working in this repository.

## Project

Shell scripts, one small C module and documentation that fix slow Samba copies and WiFi drop-outs on a Kodi box running **CoreELEC 21.3-Omega Amlogic-ng** (Amlogic S922X, AP6275S WiFi, exFAT USB disk, Windows 11 client). The repository is public. Read `README.md` first, then `docs/en/guide.md`; measured facts are in `docs/en/tests.md`.

The repository root is the package: `install.sh`, `uninstall.sh`, `check.sh`, `files/` and `tools/` are copied to `/storage/coreelec-smb-wifi-tuning/` on a box and run there. These files are byte-identical to the ones tested on the box.

## Layout

| Path | Runs on | Role |
|---|---|---|
| `install.sh`, `uninstall.sh` | box | Install / remove. Arguments: `smb` (samba + notrunc), `wifi` (dhd + irq), `watchdog`, `all`, or single parts `samba`, `notrunc`, `dhd`, `irq`, `watchdog`. `FORCE=1` skips the fitness checks (untested). |
| `check.sh` | box | Read-only status report; exit code = number of problems. |
| `files/` | box | What `install.sh` copies to `/storage/.config` (and `journald-persistent.conf` to `/storage/.cache/journald.conf.d/00_settings.conf`). |
| `files/smb-notrunc.c`, `files/smb-notrunc-armhf.so` | box | `LD_PRELOAD` module for `smbd` and its reproducible armhf build. |
| `tools/nettest.py`, `tools/sample.py` | box | Raw TCP endpoint; per-second sampler of network, disk, CPU cores and threads. |
| `tools/windows/*.ps1` | Windows PC | Raw TCP and SMB copy tests (Windows PowerShell 5.1). |
| `docs/en/guide.md` | – | Full technical guide: parts A–D, by-hand steps, side effects, references. |
| `docs/en/tests.md` | – | Record of every measurement and test, with dates. |
| `docs/de/dokumentation.md` | – | German documentation. |

Parts: **A** `samba` (signing algorithms in `samba.conf`), **B** `notrunc` (`smb-notrunc.so`), **C** `dhd` (driver `config.txt`) + `irq` (interrupt pinning), **D** `watchdog` (+ persistent journal). `install.sh` records what it created in `/storage/.config/smb-wifi-tuning/`; a user's own `samba.conf` or `config.txt` is saved as `<name>.pre-tuning` and restored by `uninstall.sh`.

## Target system

- CoreELEC 21.3-Omega Amlogic-ng: kernel 4.9.269, 32-bit armhf userspace, glibc 2.38, busybox `sh`, systemd, connman, Samba 4.19.9, fuse-exfat 1.2.8, Python 3.11. The system image is read-only; persistent changes only under `/storage`.
- Missing on the box: `smbstatus`, `taskset`, `timeout`, `diff`, `cmp`, `base64`, `truncate`, `strings`. Available: `python3`, `nano`, `awk`, `sed`, `sha256sum`, `md5sum`.
- **Never run `paste` on CoreELEC.** It is pastebinit and uploads its input publicly to paste.coreelec.org, with no way to delete it.
- WiFi driver: bcmdhd 100.10.545.x, module name `dhd`, loaded with `modprobe dhd_sdio`; it reads `config.txt` next to its firmware.

## Rules

1. Box scripts are POSIX `sh` for busybox ash (no bash-isms), with LF line endings. `.gitattributes` enforces LF; never write these files with a tool that produces CRLF.
2. Keep install, uninstall and check symmetric: every change `install.sh` makes needs a matching removal in `uninstall.sh` and a check in `check.sh`. Never modify or delete files the package did not create.
3. Do not change tested scripts without testing the change on a box. Record new results in `docs/en/tests.md` with date and numbers; never invent measurements or round them differently.
4. Reflect a behaviour change in `docs/en/guide.md`, `docs/de/dokumentation.md` and both language sections of `README.md` (English first, then German).
5. `files/smb-notrunc-armhf.so` must be the zig 0.17.1 build of `files/smb-notrunc.c`. If the source changes, rebuild it (command below) and update the SHA-256 in `docs/en/guide.md`.
6. **No private data, the repository is public**: no SSIDs, BSSIDs or MAC addresses, no IP addresses or host names of a real network, no passwords, PSKs, user names or e-mail addresses, no `watchdog.log` or `snap-*.txt`, no connman `*.config`, `samba.conf` or `smbpasswd` from a box. Use placeholders such as `<box-ip>` and `\\<box>\<share>`. Run the privacy scan below before every commit; `.gitignore` blocks the usual file types as a second line of defence.
7. Do not add the Broadcom WiFi firmware (`fw_bcm43752a2_ag.bin`) or other third-party binaries.
8. Commit with a GitHub noreply address (`<id>+<user>@users.noreply.github.com`), never with a private e-mail address; check `git config user.email` first.

## Commands

Run from the repository root (Git Bash on Windows works).

```sh
# syntax check of all shell scripts
for f in *.sh files/*.sh; do sh -n "$f" || echo "FAIL $f"; done

# privacy scan; expected output: only the example address 192.168.1.50 in tools/windows/net-test.ps1
grep -rnIiE --exclude-dir=.git --exclude=AGENTS.md '(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}|([0-9a-f]{2}[:-]){5}[0-9a-f]{2}|psk|passphrase|password *=|[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}' .

# rebuild the module; expected SHA-256 378630e7e7506660183fd1a5411df01cbc1f3a8548f8b0144fa04579342eebac
uv run --no-project --with ziglang==0.17.1 python -m ziglang cc -target arm-linux-gnueabihf.2.34 -mcpu=cortex_a53 -shared -fPIC -O2 -s -o files/smb-notrunc-armhf.so files/smb-notrunc.c
sha256sum files/smb-notrunc-armhf.so

# copy to a box, then run the check there
ssh root@<box-ip> mkdir -p /storage/coreelec-smb-wifi-tuning
scp -r install.sh uninstall.sh check.sh files tools root@<box-ip>:/storage/coreelec-smb-wifi-tuning/
ssh root@<box-ip> sh /storage/coreelec-smb-wifi-tuning/check.sh

# release archive whose top folder has the name the docs use on the box
git archive --format=zip --prefix=coreelec-smb-wifi-tuning/ -o coreelec-smb-wifi-tuning.zip HEAD
```

- Multi-line commands on the box from Windows: use Git Bash with a quoted heredoc, `ssh root@<box-ip> sh <<'EOF' ... EOF`. Windows PowerShell 5.1 strips embedded double quotes from arguments passed to `ssh`.
- Throughput tests: use `tools/nettest.py`, not busybox `nc` (it becomes the bottleneck itself). Read tests need a file the PC has not cached.
- On a PC only the syntax check, the privacy scan and the module build can run. Behaviour must be tested on a CoreELEC 21 Amlogic-ng box.
