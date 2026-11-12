# CoreELEC SMB & WLAN-Tuning: Dokumentation

Gemessen und getestet auf einer Box mit Amlogic S922X (Device Tree `g12b_s922x_beelink_gt_king`, 4 GB RAM), CoreELEC 21.3-Omega (Amlogic-ng), WLAN-Chip AP6275S und einer 10-TB-USB-Platte mit exFAT.

Überblick mit Problem, Ursachen und Lösung: [README](../../README.md#deutsch). Die ausführliche englische Anleitung mit allen Schritten von Hand und den Quellen: [guide.md](../en/guide.md). Alle Messwerte: [tests.md](../en/tests.md).

## Ergebnis

Eine 2,7-GB-Filmdatei wird jetzt mit **53–54 MB/s** auf die Platte geschrieben und mit **43 MB/s** gelesen. Am selben WLAN lag der Originalzustand bei 27 MB/s Schreiben und 24 MB/s Lesen (gemessen mit 1 GiB). Davor, noch am WiFi-5-Netz des Routers, waren es 12 MB/s Schreiben und 24 MB/s Lesen; das ist wegen des anderen WLANs nicht direkt vergleichbar. Alle Kopien der 2,7-GB-Datei wurden per SHA-256 geprüft (geschriebene auf der Box, zurückgelesene am PC) und sind bitgenau.

Das reine WLAN schaffte in den Messungen 54–58 MB/s zur Box und 43–49 MB/s zurück. Schreiben liegt damit knapp unter dem, was diese WLAN-Verbindung hergibt. Die Werte schwanken mit dem WLAN: Am Morgen danach waren es 48–49 MB/s Schreiben und 35 MB/s Lesen bei 52–54 MB/s reinem WLAN. Ob ein Kabel mehr bringt, wurde nicht gemessen.

## Stand der WLAN-Abbrüche

Wochenlang war die Box die meiste Zeit offline: Die WLAN-Verbindung brach ab, oft nachts, und kam nicht von selbst wieder. Seit den Änderungen läuft sie stabil:

- Das Wächter-Protokoll zeigt seit Beginn der Aufzeichnung keinen echten Ausfall; alle Ausfälle darin wurden für die Tests simuliert. Die längsten Abschnitte ohne jeden Eingriff dauerten bisher rund 13 Stunden (eine Nacht) und rund 10 Stunden (seit dem letzten Neustart).
- Die einzigen Speicherfehler im Kernel-Protokoll (dauerhaftes Journal, alle sieben Boots seit Beginn der Aufzeichnung) sind die sieben aus einem einzigen Vorfall mit der Original-Treibereinstellung `txglomsize=36`.

Am selben Tag wurden drei Dinge geändert, die das WLAN betreffen: die Firmware, der Access Point und die Treiber-Einstellungen (Baustein C). Welche Änderung die Abbrüche beendet hat, lässt sich nicht trennen. Der Wächter protokolliert weiter; tritt wieder ein Ausfall auf, zeigen Protokoll und Journal, ob ein Kanalwechsel oder ein Speicherfehler vorausging.

## Was das Paket installiert

| Baustein | Dateien auf der Box | Wirkung |
|---|---|---|
| A: Samba-Signatur | `/storage/.config/samba.conf` (Zeile `server smb3 signing algorithms = AES-128-CMAC, HMAC-SHA256`) | Windows signiert jedes SMB-Paket. Das Standardverfahren (GMAC) rechnet die Box ohne Hardware-Hilfe und schafft nur 27 MB/s. CMAC schafft das volle WLAN-Tempo. HMAC-SHA256 muss in der Liste bleiben, sonst scheitert der erste Verbindungsaufbau von Windows. |
| B: Samba-Modul `smb-notrunc` | `/storage/.config/smb-notrunc.so`, `smb-notrunc.c`, `system.d/smbd.service.d/notrunc.conf` | Windows legt die Zieldatei vorab in voller Größe an, und der exFAT-Treiber füllte sie dabei komplett mit Nullen. Das Modul überspringt das. |
| C: WLAN-Treiber | `/storage/.config/firmware/brcm/config.txt` (`txglomsize=16`, `dpc_cpucore=2`, `rxf_cpucore=3`) | Kleinere Sendebündel, damit der Treiber keine zusammenhängenden 64-KB-Speicherblöcke mehr braucht. Das soll den Speicherfehler vermeiden. Die Treiber-Threads laufen auf schnellen Kernen. |
| C: Interrupt-Zuordnung | `/storage/.config/wifi-irq-affinity.sh`, `system.d/wifi-irq-affinity.service` | Legt die Interrupts des WLAN-Chips auf einen schnellen Kern. |
| D: WLAN-Wächter | `/storage/.config/wifi-watchdog.sh`, `system.d/wifi-watchdog.service`, Protokoll in `/storage/wifi-debug/` | Prüft alle 30 s die Verbindung, protokolliert Kanalwechsel und Ausfälle und versucht bei einem Ausfall in vier Stufen die Wiederherstellung. Startet die Box nie neu. Wer das WLAN selbst ausschaltet, dem lässt er es aus. |
| D: Dauerhaftes Systemprotokoll | `/storage/.cache/journald.conf.d/00_settings.conf` | Das Kernel-Protokoll eines Ausfalls übersteht einen Neustart. |

Alles liegt unter `/storage/.config` (dazu eine Einstellung in `/storage/.cache` und die Protokolle in `/storage/wifi-debug`) und übersteht CoreELEC-Updates. Eine eigene `samba.conf` oder Treiber-`config.txt` wird vorher als `<Name>.pre-tuning` gesichert und beim Entfernen zurückgespielt; die Fassung, die bis dahin galt, bleibt als `<Name>.removed` erhalten. Dateien, die das Paket nicht angelegt hat, lässt es in Ruhe.

Die Meldungen im Wächter-Protokoll sind englisch („Status ok“, „OUTAGE detected“, „Stage 3 ok“, „Link back online“). Das Protokoll und die Schnappschüsse (`snap-*.txt`) enthalten Netzwerknamen, MAC- und IP-Adressen; vor dem Weitergeben schwärzen.

**Nicht im Paket**, auf der Testbox aber zur selben Zeit geändert:

- WLAN-Firmware 18.35.387.23.7 als `/storage/.config/firmware/brcm/fw_bcm43752a2_ag.bin` statt der mitgelieferten 18.35.387.11 (Hintergrund: CoreELEC-Forum, Thema 59423). Sie stammt von Broadcom und liegt deshalb nicht bei. Zurück zur mitgelieferten Firmware: die Datei löschen und neu starten.
- Die Box hängt an einem WiFi-6-Access-Point statt am WiFi-5-Netz des Routers.

## Installieren, prüfen, entfernen

Am PC, im Ordner dieses Repositorys:

```
ssh root@<box-ip> mkdir -p /storage/coreelec-smb-wifi-tuning
scp -r install.sh uninstall.sh check.sh files tools root@<box-ip>:/storage/coreelec-smb-wifi-tuning/
```

Auf der Box (per SSH):

```sh
cd /storage/coreelec-smb-wifi-tuning
sh check.sh               # zeigt, was aktiv ist und ob etwas nicht stimmt
sh install.sh smb         # Bausteine A + B (Samba), sofort aktiv
sh install.sh wifi        # Baustein C (WLAN-Treiber), aktiv nach einem Neustart
sh install.sh watchdog    # Baustein D (Wächter)
sh install.sh all         # alles, was zur Box passt
sh uninstall.sh all       # alles entfernen; danach die Box neu starten
sh uninstall.sh notrunc   # nur einen Teil entfernen: samba, notrunc, dhd, irq, watchdog
```

Die Skripte nicht mit einem Windows-Editor bearbeiten: Windows-Zeilenenden machen Shell-Skripte unbrauchbar. `check.sh` gibt die Zahl der gefundenen Probleme als Exit-Code zurück.

## Was getestet wurde

1. **Fünf Neustarts**, der letzte mit der endgültigen Fassung aller Skripte: WLAN, Treiber-Einstellungen, Dienste, Samba und Freigabe kamen jedes Mal von selbst wieder.
2. **Tempo und Datensicherheit:** ganze 2,7-GB-Datei mehrfach geschrieben und gelesen, jeweils mit Prüfsumme.
3. **Fehler mit „nur CMAC“ nachgestellt:** Mit der zu strengen Samba-Einstellung (`AES-128-CMAC` allein) scheitert der Verbindungsaufbau, mit dem Windows den ersten Kontakt aufnimmt; Windows meldet dann „Der Netzwerkpfad wurde nicht gefunden“. Mit der jetzigen Einstellung klappt er. `check.sh` prüft das bei jedem Lauf.
4. **Paket komplett durchgespielt:** deinstalliert, Neustart in den Originalzustand, Bausteine einzeln installiert und jeweils gemessen, Neustart, Prüfung, Abschlusstest. Dazu die Sonderfälle: eigene vorhandene `samba.conf` und Treiber-`config.txt` (werden gesichert und beim Entfernen bitgenau zurückgespielt, spätere Änderungen bleiben als `.removed` erhalten), fremde `config.txt` (bleibt unangetastet).
5. **WLAN-Wächter, sieben Tests:** Viermal simulierter Ausfall (Pings zum Router gesperrt): Ausfall jeweils nach gut anderthalb Minuten erkannt; die Stufen davor liefen erwartungsgemäß ohne Erfolg; nach Aufheben der Sperre war die Verbindung in Stufe 3 nach 16 bzw. 18 s wieder da, in Stufe 4 (Treiber neu laden) nach 37 bzw. 34 s, zuletzt mit der endgültigen Fassung. Zweimal WLAN von Hand ausgeschaltet: Der Wächter blieb untätig und ließ es aus. Einmal einen abgestürzten Wächter nachgestellt, der das WLAN ausgeschaltet hinterlässt: Beim nächsten Start schaltete er es wieder ein. Das zeigt, dass Erkennung, Protokoll und Stufenfolge funktionieren, nicht, dass eine Stufe einen echten Treiber-Hänger behebt.
6. **Samba-Modul:** Einzeltest auf drei Dateisystemen (exFAT, ext4, tmpfs), Schreiben in beliebiger Reihenfolge, Überschreiben einer größeren Datei durch eine kleinere, jeweils mit Prüfsumme. Später überarbeitet (fängt jetzt beide Varianten des Systemaufrufs ab, wichtig für 64-Bit-Systeme) und alle Tests wiederholt. Mit zig 0.17.1 entsteht die Binärdatei bitgleich aus dem Quelltext.
7. **Stresstest Speicher:** Dateicache gefüllt, dann große Lesevorgänge von der Box. Kein Speicherfehler aufgetreten (beim ersten Vorfall waren es sieben). Der Fehler ließ sich aber auch mit der Originaleinstellung nicht mehr auslösen. Dass die neue Einstellung ihn verhindert, folgt aus dem Quellcode von Treiber und Kernel, nicht aus diesem Test.
8. **Schritte von Hand:** Die Befehlsblöcke für die Bausteine A, B und C liefen auf der Box genau so, wie sie dastehen (Baustein B in einer Variante, die das Modul aus eingebettetem Base64-Text schreibt).
9. **Zwei unabhängige Prüfrunden** der Texte und Skripte (Aussagen gegen Messwerte, Skriptfehler, private Daten, Verständlichkeit). Die Befunde sind eingearbeitet.

### Messreihe Schritt für Schritt (gleiches WLAN, an einem Abend)

| Zustand | Schreiben | Lesen |
|---|---|---|
| Originalzustand CoreELEC | 27,7 / 27,0 MB/s | 23,8 / 24,0 MB/s |
| + Samba-Signatur | 43,2 / 42,8 MB/s | 37,3 / 34,1 MB/s |
| + Samba-Modul `smb-notrunc` | 51,1 / 50,8 / 50,3 MB/s | nicht gemessen (das Modul betrifft nur das Schreiben) |
| + WLAN-Treiber-Einstellungen | 52,3 / 52,2 / 53,0 MB/s | 34,5 / 34,9 MB/s (ein Lauf 27,3) |
| Reines WLAN zum Vergleich | 54–58 MB/s | 43–49 MB/s |

Schreiben = Kopieren einer 1-GiB-Datei mit dem Windows-Kopierprogramm (`Copy-Item`), Lesen = fortlaufendes Lesen von 1 GiB. Das Lesen einer ganzen Datei mit dem Windows-Kopierprogramm ist schneller (43 MB/s) und mit dieser Spalte nicht vergleichbar. Bei der Samba-Signatur fiel ein erstes Lese-Paar (19 und 30 MB/s) in einen Einbruch der WLAN-Rate und wurde wiederholt.

Die WLAN-Treiber-Einstellungen bringen kein messbares Tempo; sie sollen den Speicherfehler vermeiden.

## Grenzen und Nebenwirkungen

- **Samba-Modul:** Legt ein Programm über SMB eine Datei nur in fester Größe an, ohne sie zu beschreiben, bleibt sie auf der Platte leer oder kürzer. Ist die Platte voll, merkt Windows das erst während des Kopierens. Die Samba-Entwickler halten solche Eingriffe grundsätzlich für riskant; für eine Filmplatte ist das Risiko vertretbar, entscheiden muss das jeder selbst. Das Modul wirkt auf alle FUSE-Platten, die Samba freigibt; getestet ist nur exfat-fuse. Wer im CoreELEC-Forum ein Samba-Problem meldet, sollte es vorher ohne das Modul nachstellen.
- **WLAN-Abbrüche:** Seit den Änderungen keine mehr (siehe oben); welche Änderung das bewirkt hat, ist offen.
- **Router aus:** Ist der Router länger als zwei Minuten aus, hält der Wächter das für einen Ausfall und wiederholt seine Stufen etwa alle 15 Minuten, bis der Router wieder da ist.
- **Gleicher Funkkanal:** Router und Access Point funken auf demselben 5-GHz-Kanal und teilen sich die Sendezeit. Ein anderer Kanal am Router könnte Schwankungen verringern (nicht gemessen).
- **CoreELEC 22:** Für die Box gibt es CoreELEC 22 (Amlogic-no) als Vorabversion, mit 64-Bit-System und neuerem WLAN-Treiber. Die Samba-Signatur-Einstellung und die Treiber-Einstellung wären dort voraussichtlich überflüssig. CoreELEC 21 wird nicht mehr weiterentwickelt. Ein Umstieg ist eine Überlegung wert, sobald 22 fertig ist; getestet ist das nicht.

## Welche Geräte betroffen sind

- **Samba-Signatur (A):** Boxen mit CoreELEC 21 Amlogic-ng (32-Bit-System: S905X/D/W, S905X2/Y2, S922X, A311D, S905X3/D3, S905X4), wenn man sich von Windows 11 ab 24H2 (Pro, Enterprise, Education) mit Benutzername und Kennwort an der Freigabe anmeldet. Ohne Kennwort (Gastzugang) wird nicht signiert, dann ändert sich nichts. Vermutlich auch per LAN-Kabel; gemessen ist das nicht.
- **Samba-Modul (B):** exFAT-Platten an Amlogic-ng-Boxen, wenn von Windows über die Freigabe geschrieben wird.
- **WLAN-Treiber (C):** Boxen mit AP6275S-Chip und Treiber 100.10.545.x unter CoreELEC 21, zum Beispiel die WiFi-6-Ausführungen von Beelink GT-King und GT-King Pro.
- **Wächter (D):** CoreELEC-Boxen, die per WLAN im Netz hängen und deren Router auf Ping antwortet.

Gemessen wurde nur auf einer Box. Die Aussagen zu anderen Geräten stützen sich auf den Quellcode von Samba, exfat-fuse und dem WLAN-Treiber sowie auf die CoreELEC-Unterlagen; die englische Anleitung nennt die Quellen.
