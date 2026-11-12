# CoreELEC SMB & WiFi tuning (Amlogic S922X, AP6275S)

Fixes for a Kodi box on CoreELEC 21.3 (Amlogic-ng) that copied files slowly over Samba and kept losing its WiFi connection: scripts that install, check and remove the fixes, and the record of how they were tested.

**English** · [Deutsch](#deutsch)

## English

### The problem

The box is an Amlogic S922X TV box (device tree `g12b_s922x_beelink_gt_king`) running Kodi on CoreELEC 21.3-Omega Amlogic-ng. It is connected by WiFi (AP6275S chip) and shares a 10 TB exFAT USB disk with a Windows 11 PC over Samba.

1. **WiFi drop-outs.** For weeks the box was offline most of the time. Its WiFi connection dropped, often at night, and did not come back by itself.
2. **Slow copies.** Copying from the PC to the disk ran at 27 MB/s and reading at 24 MB/s, although the WiFi link carried 54–58 MB/s to the box and 43–49 MB/s from it.

### The causes

- **Samba signing.** Windows 11 24H2 signs every SMB packet. Samba picks AES-128-GMAC for that, and CoreELEC's 32-bit ARM build computes it in plain C, without the CPU's crypto instructions: at 27 MB/s, `smbd` used 100 % of one core.
- **exFAT zero-fill.** Before copying, Windows sets the destination file to its final size. exfat-fuse can only do that by writing zeros over the whole file, so every file was written twice.
- **WiFi driver memory.** The AP6275S driver (bcmdhd 100.10.545.x) needs one contiguous 64 KB memory block for each bundle of outgoing packets. The disk cache of exfat-fuse fragments the memory until no such block is free; once, during a large transfer, the kernel logged seven failed allocations in the driver. It is not proven that this caused the drop-outs. The other suspect is a channel change of the access point that the old driver and firmware did not follow.

### The fix

| Part | What it does | Effect |
|---|---|---|
| **A** Samba signing | Sets `server smb3 signing algorithms = AES-128-CMAC, HMAC-SHA256`. The connection stays fully signed. | write 27 → 43 MB/s, read 24 → 34–37 MB/s |
| **B** `smb-notrunc` | A small `LD_PRELOAD` module for `smbd` (about 40 lines of C) that skips the zero-fill on FUSE disks | write 43 → 51 MB/s |
| **C** WiFi driver settings | `txglomsize=16`, so that a bundle fits a 32 KB block; driver threads and SDIO interrupts on the fast Cortex-A73 cores | no speed change; meant to prevent the allocation failure |
| **D** WiFi watchdog | Pings the gateway every 30 s, logs channel changes and outages, recovers in four stages and never reboots; keeps the system journal across reboots | diagnosis and self-repair |

Also changed at the same time, outside these scripts: the WiFi firmware was updated to 18.35.387.23.7 (CoreELEC forum topic 59423), and the box moved from the router's WiFi 5 network to a WiFi 6 access point. The firmware belongs to Broadcom and is not included here.

End result: 52–53 MB/s write and 35 MB/s read for 1 GiB. A whole 2.7 GB movie copies to the box at 53–54 MB/s and back at 43 MB/s, SHA-256 verified.

### How it was tested

On this one box. Every number is in [docs/en/tests.md](docs/en/tests.md).

- Reset to the CoreELEC defaults, then each part installed on its own and measured on the same access point, with raw TCP throughput as the reference.
- Whole-file copies checked with SHA-256 on the box and on the PC.
- Five reboots. Install and uninstall, also over an existing `samba.conf` and driver `config.txt`, which come back byte-identical.
- The failure with `AES-128-CMAC` alone (Windows: "network path not found") reproduced; `check.sh` tests for it.
- `smb-notrunc` on three filesystems, with out-of-order writes, overwrites and files that are only pre-sized. The binary rebuilds byte-identical from the source.
- Memory stress runs: no allocation failure with `txglomsize=16`.
- Watchdog: four simulated outages (pings to the gateway blocked), recovered in stage 3 or 4. WiFi switched off by hand stays off. After a watchdog died between its own WiFi off and on, the next start switched WiFi back on.
- Two independent reviews of the scripts and texts.

### Status: stable

Since all of this was put in place, the box has not lost its WiFi connection once. The watchdog log shows no real outage since logging began; every outage in it was simulated for the tests. The longest stretches without any intervention so far lasted about 13 and about 10 hours. The only memory-allocation failures in the kernel log are the seven from a single incident with the stock driver setting. Before, the box had been offline most of the time for weeks.

The observation period is still short, and firmware, access point and driver settings all changed on the same day, so it is open which change ended the drop-outs. The watchdog keeps logging.

### Quick start

Made for CoreELEC 21.3 Amlogic-ng; the installer skips whatever does not fit the box. SSH must be enabled on the box. On the PC, in this folder (Windows 11 includes `ssh` and `scp`):

```
ssh root@<box-ip> mkdir -p /storage/coreelec-smb-wifi-tuning
scp -r install.sh uninstall.sh check.sh files tools root@<box-ip>:/storage/coreelec-smb-wifi-tuning/
```

On the box, over SSH:

```sh
cd /storage/coreelec-smb-wifi-tuning
sh check.sh               # what applies to this box, what is active
sh install.sh smb         # parts A + B, active at once (restarts smbd: running copies are cut)
sh install.sh wifi        # part C, active after a reboot
sh install.sh watchdog    # part D
sh install.sh all         # everything that fits this box
sh uninstall.sh all       # back to the defaults (reboot afterwards for part C)
```

Everything is written to `/storage/.config`, plus one journald setting in `/storage/.cache` and the watchdog logs in `/storage/wifi-debug`; the system image is not touched. Read the [side effects of part B](docs/en/guide.md#part-b-smb-notrunc-no-zero-fill-on-exfat) before you install it. The watchdog logs contain your network name and addresses; blank them out before you share them.

### Repository layout

```
install.sh  uninstall.sh  check.sh   run on the box: install, remove, verify (parts A-D)
files/                               what install.sh puts on the box, incl. smb-notrunc.c and its armhf build
tools/                               measuring tools: nettest.py, sample.py (box), windows/*.ps1 (PC)
docs/en/guide.md                     full guide: who is affected, background, by-hand steps, references
docs/en/tests.md                     every measurement and test
docs/de/dokumentation.md             German documentation
AGENTS.md                            notes for AI coding agents and contributors
```

Public domain (CC0), no warranty, see [LICENSE](LICENSE). This is not an official CoreELEC package; please do not ask the CoreELEC team for support with it.

---

## Deutsch

### Das Problem

Die Box ist eine TV-Box mit Amlogic S922X (Device Tree `g12b_s922x_beelink_gt_king`), auf der Kodi unter CoreELEC 21.3-Omega Amlogic-ng läuft. Sie hängt per WLAN im Netz (Chip AP6275S) und gibt eine 10-TB-USB-Platte mit exFAT per Samba für einen Windows-11-PC frei.

1. **WLAN-Abbrüche.** Wochenlang war die Box die meiste Zeit offline. Die WLAN-Verbindung brach ab, oft nachts, und kam nicht von selbst wieder.
2. **Langsames Kopieren.** Schreiben vom PC auf die Platte lief mit 27 MB/s, Lesen mit 24 MB/s, obwohl die WLAN-Verbindung 54–58 MB/s zur Box und 43–49 MB/s zurück übertrug.

### Die Ursachen

- **Samba-Signatur.** Windows 11 ab 24H2 signiert jedes SMB-Paket. Samba wählt dafür AES-128-GMAC, und CoreELECs 32-Bit-ARM-Build rechnet das in reinem C, ohne die Krypto-Befehle der CPU: Bei 27 MB/s lief `smbd` mit 100 % auf einem Kern.
- **exFAT füllt mit Nullen.** Vor dem Kopieren setzt Windows die Zieldatei auf ihre endgültige Größe. exfat-fuse kann das nur, indem es die ganze Datei mit Nullen beschreibt; jede Datei wurde also zweimal geschrieben.
- **Speicher im WLAN-Treiber.** Der AP6275S-Treiber (bcmdhd 100.10.545.x) braucht für jedes Bündel ausgehender Pakete einen zusammenhängenden 64-KB-Speicherblock. Der Platten-Cache von exfat-fuse zerstückelt den Speicher, bis kein solcher Block mehr frei ist; einmal, während einer großen Übertragung, meldete der Kernel sieben fehlgeschlagene Speicheranforderungen im Treiber. Dass das die Abbrüche verursacht hat, ist nicht bewiesen. Der andere Verdacht ist ein Kanalwechsel des Access Points, dem der alte Treiber mit der alten Firmware nicht folgte.

### Die Lösung

| Baustein | Was er tut | Wirkung |
|---|---|---|
| **A** Samba-Signatur | Setzt `server smb3 signing algorithms = AES-128-CMAC, HMAC-SHA256`. Die Verbindung bleibt voll signiert. | Schreiben 27 → 43 MB/s, Lesen 24 → 34–37 MB/s |
| **B** `smb-notrunc` | Ein kleines `LD_PRELOAD`-Modul für `smbd` (rund 40 Zeilen C), das das Füllen mit Nullen auf FUSE-Platten überspringt | Schreiben 43 → 51 MB/s |
| **C** WLAN-Treiber | `txglomsize=16`, damit ein Bündel in einen 32-KB-Block passt; Treiber-Threads und SDIO-Interrupts auf den schnellen Cortex-A73-Kernen | kein Tempo-Gewinn; soll den Speicherfehler verhindern |
| **D** WLAN-Wächter | Prüft alle 30 s das Gateway, protokolliert Kanalwechsel und Ausfälle, stellt die Verbindung in vier Stufen wieder her und startet nie neu; das Systemprotokoll übersteht Neustarts | Diagnose und Selbstheilung |

Zur selben Zeit ebenfalls geändert, aber nicht Teil der Skripte: Die WLAN-Firmware wurde auf 18.35.387.23.7 aktualisiert (CoreELEC-Forum, Thema 59423), und die Box hängt nicht mehr am WiFi-5-Netz des Routers, sondern an einem WiFi-6-Access-Point. Die Firmware gehört Broadcom und liegt hier nicht bei.

Endergebnis: 52–53 MB/s Schreiben und 35 MB/s Lesen bei 1 GiB. Ein ganzer 2,7-GB-Film wird mit 53–54 MB/s auf die Box kopiert und mit 43 MB/s zurückgelesen, per SHA-256 geprüft.

### Wie getestet wurde

Auf dieser einen Box. Alle Zahlen stehen in [docs/en/tests.md](docs/en/tests.md) (englisch), eine deutsche Zusammenfassung in [docs/de/dokumentation.md](docs/de/dokumentation.md).

- Zurück auf den CoreELEC-Originalzustand, dann jeden Baustein einzeln installiert und am selben Access Point gemessen, mit dem reinen TCP-Durchsatz als Vergleich.
- Ganze Dateien kopiert und per SHA-256 auf der Box und am PC geprüft.
- Fünf Neustarts. Installieren und Entfernen, auch über eine vorhandene `samba.conf` und Treiber-`config.txt`, die bitgenau zurückkommen.
- Den Fehler mit `AES-128-CMAC` allein (Windows: „Der Netzwerkpfad wurde nicht gefunden“) nachgestellt; `check.sh` prüft darauf.
- `smb-notrunc` auf drei Dateisystemen, mit Schreiben in beliebiger Reihenfolge, Überschreiben und nur vorab angelegten Dateien. Die Binärdatei entsteht bitgleich aus dem Quelltext.
- Speicher-Stresstests: mit `txglomsize=16` kein Speicherfehler.
- Wächter: vier simulierte Ausfälle (Pings zum Gateway gesperrt), in Stufe 3 oder 4 behoben. Von Hand ausgeschaltetes WLAN bleibt aus. Nachdem ein Wächter zwischen seinem eigenen Aus- und Einschalten abgestürzt war, schaltete der nächste Start das WLAN wieder ein.
- Zwei unabhängige Prüfrunden der Skripte und Texte.

### Stand: stabil

Seit all das eingerichtet ist, hat die Box die WLAN-Verbindung kein einziges Mal verloren. Das Wächter-Protokoll zeigt seit Beginn der Aufzeichnung keinen echten Ausfall; alle Ausfälle darin wurden für die Tests simuliert. Die längsten Abschnitte ohne jeden Eingriff dauerten bisher rund 13 und rund 10 Stunden. Die einzigen Speicherfehler im Kernel-Protokoll sind die sieben aus einem einzigen Vorfall mit der Original-Treibereinstellung. Vorher war die Box wochenlang die meiste Zeit offline.

Der Beobachtungszeitraum ist noch kurz, und Firmware, Access Point und Treiber-Einstellungen wurden alle am selben Tag geändert. Welche Änderung die Abbrüche beendet hat, ist daher offen. Der Wächter protokolliert weiter.

### Schnellstart

Gemacht für CoreELEC 21.3 Amlogic-ng; das Installationsskript überspringt, was nicht zur Box passt. Auf der Box muss SSH eingeschaltet sein. Am PC, in diesem Ordner (Windows 11 bringt `ssh` und `scp` mit):

```
ssh root@<box-ip> mkdir -p /storage/coreelec-smb-wifi-tuning
scp -r install.sh uninstall.sh check.sh files tools root@<box-ip>:/storage/coreelec-smb-wifi-tuning/
```

Auf der Box, per SSH:

```sh
cd /storage/coreelec-smb-wifi-tuning
sh check.sh               # was auf diese Box zutrifft, was aktiv ist
sh install.sh smb         # Bausteine A + B, sofort aktiv (startet smbd neu: laufende Kopien brechen ab)
sh install.sh wifi        # Baustein C, aktiv nach einem Neustart
sh install.sh watchdog    # Baustein D
sh install.sh all         # alles, was zur Box passt
sh uninstall.sh all       # zurück zum Originalzustand (für Baustein C danach neu starten)
```

Alles wird unter `/storage/.config` abgelegt, dazu eine journald-Einstellung in `/storage/.cache` und die Wächter-Protokolle in `/storage/wifi-debug`; das System-Image bleibt unberührt. Vor dem Installieren die [Nebenwirkungen von Baustein B](docs/de/dokumentation.md#grenzen-und-nebenwirkungen) lesen. Die Wächter-Protokolle enthalten Netzwerkname und Adressen; vor dem Weitergeben schwärzen.

### Aufbau des Repositorys

```
install.sh  uninstall.sh  check.sh   laufen auf der Box: installieren, entfernen, prüfen (Bausteine A-D)
files/                               was install.sh auf die Box legt, auch smb-notrunc.c und seine armhf-Fassung
tools/                               Messwerkzeuge: nettest.py, sample.py (Box), windows/*.ps1 (PC)
docs/en/guide.md                     ausführliche Anleitung (englisch): betroffene Geräte, Hintergrund, Schritte von Hand, Quellen
docs/en/tests.md                     alle Messungen und Tests (englisch)
docs/de/dokumentation.md             deutsche Dokumentation
AGENTS.md                            Hinweise für KI-Coding-Agenten und Mitwirkende
```

Gemeinfrei (CC0), ohne Gewähr, siehe [LICENSE](LICENSE). Das ist kein offizielles CoreELEC-Paket; bitte das CoreELEC-Team nicht um Hilfe dazu bitten.
