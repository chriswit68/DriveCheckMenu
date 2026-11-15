# DriveCheckMenu

Eine native macOS-Menüleisten-App zur Überwachung der SMART-Gesundheit und der aktuellen Speicherbelegung von Massenspeichern und AppleRAID-Verbünden.

> **Hinweis:** DriveCheckMenu ist ein **Vibe-Code-Experiment**. Der Code entstand überwiegend im Dialog mit einer KI und dient vor allem dazu, Ideen und Arbeitsweisen auszuprobieren. Vor einem produktiven Einsatz bitte selbst prüfen, testen und an die eigenen Anforderungen anpassen.

Das Symbol in der Menüleiste zeigt den Gesamtstatus aller ausgewählten Geräte:

| Farbe | Bedeutung |
| --- | --- |
| Neutral (passt sich der Menüleiste an) | Alles in Ordnung, Status unbekannt (oder noch keine Auswahl) |
| Gelb | Warnung, z. B. hohe Temperatur, hoher Verschleiß, Medienfehler, Laufwerk im Standby oder nicht verbunden, RAID-Rebuild |
| Rot | Problem, z. B. SMART-Fehler, kritische Warnung, schwebende Sektoren, degradiertes/offline RAID |

**Linksklick** öffnet das Statusmenü mit Detailinformationen, **Rechtsklick** (oder `Ctrl`-Klick) öffnet direkt die Einstellungen.

## Funktionen

- Überwachung physischer interner und externer Laufwerke (SSD/HDD, NVMe/SATA/USB)
- Detaillierte SMART-Auswertung über `smartctl` (smartmontools), inklusive Temperatur, Verschleiß, Reserveblöcken, Medienfehlern und Fehlerprotokoll
- Fallback auf den Basis-SMART-Status von `diskutil`, wenn `smartctl` nicht verfügbar ist
- AppleRAID-Überwachung inklusive Mitgliedsstatus und Rebuild-Fortschritt
- Anzeige der aktuellen Speicherbelegung (belegte Menge und Prozent) für eingehängte Dateisysteme – ohne zusätzliche Prozesse oder Plattenzugriffe
- Einstellbare Prüfintervalle von jeder Minute bis täglich
- Einstellbare Warn- und Kritisch-Schwellwerte für Temperatur und Verschleiß
- Optionaler SMART-Kurztest pro Laufwerk; bei Bedarf mit Administratorfreigabe über einen einmaligen Systemdialog
- Benachrichtigungen bei neu erkannten oder behobenen Problemen (abschaltbar)
- Optionaler Start beim Anmelden
- Deutsche Oberfläche, Menüleisten-App ohne Dock-Symbol (`LSUIElement`)

## Voraussetzungen

- macOS 14 (Sonoma) oder neuer
- Xcode bzw. die Swift-Command-Line-Tools (Swift 6 Compiler, Swift-5-Sprachmodus)
- Empfohlen: [smartmontools](https://www.smartmontools.org/) für die vollständige SMART-Auswertung

```sh
brew install smartmontools
```

Die App sucht `smartctl` automatisch unter `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` und `/usr/bin`. Ein eigener Pfad lässt sich im SMART-Tab eintragen.

> Ohne `smartctl` funktioniert die App weiter, zeigt dann aber nur den Basisstatus von `diskutil` (keine Temperatur, kein Verschleiß, keine Fehlerzähler).

## Bauen und Starten

```sh
make app        # Baut build/DriveCheckMenu.app
make run        # Baut und startet die App
make test       # Führt die Unit-Tests aus
make install    # Kopiert die App nach /Applications
make universal  # Universal Binary (Apple Silicon + Intel)
make icon       # Erzeugt das App-Icon neu
make clean      # Entfernt Build-Artefakte
```

Das Bundle wird ad-hoc signiert, falls keine passende Entwicklersignatur im Schlüsselbund verfügbar ist.

### Direktstart ohne Bundle

Für Diagnosezwecke kann die Binärdatei auch direkt aufgerufen werden:

```sh
./build/DriveCheckMenu.app/Contents/MacOS/DriveCheckMenu --dump
```

`--dump` gibt den aktuellen Status aller erkannten Laufwerke und RAID-Sets im Terminal aus.

### Simulation

Zur Prüfung der Statusfarben lassen sich Fehlerfälle simulieren:

```sh
./build/DriveCheckMenu.app/Contents/MacOS/DriveCheckMenu --dump --simulate=failing
./build/DriveCheckMenu.app/Contents/MacOS/DriveCheckMenu --dump --simulate=degraded
./build/DriveCheckMenu.app/Contents/MacOS/DriveCheckMenu --dump --simulate=missing
```

Alternativ die Umgebungsvariable `DCM_SIMULATE=failing|degraded|missing` setzen. Für die App selbst:

```sh
open build/DriveCheckMenu.app --args --simulate=degraded
```

Die Simulation überschreibt nur die Anzeige, echte Geräte werden nicht verändert.

## Bedienung

- **Linksklick** auf das Menüleistensymbol: Statusmenü mit allen überwachten Laufwerken und RAID-Sets. Jedes Laufwerk hat ein Untermenü mit SMART-Details, Speicherbelegung und dem Eintrag „SMART-Kurztest starten“.
- **Rechtsklick** auf das Symbol: Einstellungen.
- **Einstellungen → Allgemein**: Start beim Anmelden, Prüfintervall, Benachrichtigungen, manuelle Prüfung.
- **Einstellungen → Laufwerke**: Auswahl der zu überwachenden Laufwerke.
- **Einstellungen → RAID**: Auswahl der zu überwachenden AppleRAID-Sets.
- **Einstellungen → SMART**: smartctl-Pfad, Schwellwerte und SMART-Kurztest.

Nicht verbundene, aber ausgewählte Laufwerke bleiben in der Auswahl und werden als Warnung angezeigt. So fällt ein ausgefallenes externes Laufwerk auf, statt einfach zu verschwinden.

## Speicherbelegung

Für jedes eingehängte Dateisystem zeigt die App die aktuell belegte Kapazität und den prozentualen Anteil an:

```
Belegt: 262,33 GB von 999,86 GB (26 %)
```

Die Zeile erscheint im Untermenü des Laufwerks bzw. RAID-Sets, kompakt in den Einstellungen und in der `--dump`-Ausgabe. Bewusst angezeigt werden nur die belegte Menge und der Prozentwert – keine Angabe des freien Speichers.

- **Bezugsgröße:** Die Prozentangabe bezieht sich auf die angezeigte Gerätegröße. Dadurch passen Prozentwert und „Größe:“-Zeile zusammen.
- **Ermittlung:** Die Belegung wird aus den eingehängten Dateisystemen gelesen. Dafür genügen zwei `getfsstat`-Aufrufe (Anzahl ermitteln, Daten abrufen); die Partitions- und APFS-Hierarchie stammt aus der ohnehin abgefragten `diskutil list -plist`-Ausgabe. Es werden weder `df`/`du` aufgerufen noch zusätzliche Prozesse gestartet oder Dateisysteminhalte durchsucht. Laufwerke im Standby bleiben dadurch im Standby.
- **APFS:** Alle Volumes eines Containers melden dieselben containerweiten Werte. Die App zählt jeden Container daher nur einmal. Mehrere Container auf einer physischen Platte werden addiert.
- **RAID:** Ein RAID-Set zeigt die Belegung seines Dateisystems auf der virtuellen Gesamtplatte (z. B. `disk8`). Mitgliedsplatten ohne eigenes Dateisystem erhalten keine Belegungszeile.
- **Ohne Dateisystem:** Unformatierte, nicht eingehängte oder anderweitig belegte Speicher werden ohne Belegungszeile angezeigt.
- **Fallback:** Ist ein laut `diskutil` eingehängter APFS-Container nicht über `getfsstat` messbar, greift die App ersatzweise auf `CapacityInUse` aus der Plist zurück. Diese Werte können geringfügig von den Live-Werten abweichen.

Die Werte werden mit dem normalen Prüfintervall aktualisiert; „Jetzt aktualisieren“ bzw. „Jetzt prüfen“ erfrischt sie sofort.

## Konfiguration

Die Einstellungen werden über `UserDefaults` unter der Bundle-ID `de.chriswit.DriveCheckMenu` gespeichert. Es werden keine Konfigurationsdateien außerhalb des App-Containers angelegt.

Laufwerke werden über ihre Seriennummer identifiziert (`serial:…`). Nur wenn keine Seriennummer verfügbar ist, wird ersatzweise Modell + Größe verwendet. Dadurch bleibt die Auswahl auch nach einem Neustart oder Umstecken stabil.

## Login-Start

Der Login-Start nutzt `SMAppService.mainApp` und funktioniert am zuverlässigsten, wenn die App in `/Applications` liegt:

```sh
make install
open /Applications/DriveCheckMenu.app
```

Bei ad-hoc signierten Builds oder einem Start außerhalb von `/Applications` kann macOS den Eintrag nicht registrieren oder eine Freigabe in den Systemeinstellungen verlangen. Der Status wird im Allgemein-Tab angezeigt.

## Menüleistensymbol wird nicht angezeigt (macOS 26+)

Seit macOS 26 (Tahoe) verwaltet macOS die Menüleiste restriktiver: Eine App darf ihr Symbol erst anzeigen, nachdem sie einmalig freigegeben wurde. Die App läuft dabei normal weiter – es wirkt nur so, als würde sie nicht starten. Beim ersten Start weist ein Hinweisdialog darauf hin; der Status steht außerdem dauerhaft unter **Einstellungen → Allgemein → Menüleiste**.

1. **Systemeinstellungen → Menüleiste** öffnen – oder in der App **Einstellungen → Allgemein → „Menüleisten-Einstellungen öffnen …“**.
2. DriveCheckMenu unter **„In der Menüleiste erlauben“** aktivieren.
3. Fehlt das Symbol weiterhin: App beenden (`killall DriveCheckMenu`), neu starten und gegebenenfalls einmal ab- und wieder anmelden.

Bekannter macOS-Fehler: Der Schalter bleibt wirkungslos, weil macOS den Sichtbarkeitszustand pro Bundle-ID speichert. Workaround: `CFBundleIdentifier` in `Resources/Info.plist` ändern (z. B. auf `de.chriswit.DriveCheckMenu2`), mit `make app` neu bauen und die App erneut freigeben. Maßnahmen wie `defaults delete`, `lsregister` oder `killall SystemUIServer/ControlCenter` helfen in der Regel nicht.

Wird die App bei bereits laufender Instanz erneut geöffnet, zeigt sie jetzt die Einstellungen an, damit der Zustand sichtbar und prüfbar bleibt.

## Berechtigungen und Grenzen

- **Kein dauerhafter Root-Helper.** `smartctl` wird ohne `sudo` ausgeführt. Bei Laufwerken, die ohne Root keinen SMART-Zugriff erlauben, greift der `diskutil`-Basisstatus.
- **SMART-Kurztest:** Der Test wird normalerweise ohne Root gestartet. Meldet `smartctl` fehlende Rechte, bietet die App den Start mit Administratorfreigabe über einen einmaligen `osascript`-Dialog an. Es wird kein privilegierter Hintergrunddienst installiert.
- **AppleRAID:** Es werden nur mit `diskutil appleRAID` verwaltete Sets erkannt. Software-RAIDs anderer Hersteller (z. B. mdadm, SoftRAID) werden nicht ausgewertet.
- **USB-Bridges:** Manche Gehäuse liefern SMART-Daten nur eingeschränkt oder falsch weiter. Die App versucht automatisch passende `smartctl -d`-Gerätetypen.
- **macOS-Systemlaufwerk:** Das interne Apple-SSD liefert je nach Modell eingeschränkte SMART-Daten. Ein fehlgeschlagenes Lesen des Fehlerprotokolls wird nicht als Laufwerksfehler gewertet, solange der SMART-Gesamtstatus „passed“ meldet.
- **Benachrichtigungen** benötigen die übliche macOS-Freigabe. Beim ersten Start fragt die App danach.
- **Kein Hintergrunddienst:** Die App prüft nur, solange sie läuft. Für dauerhafte Überwachung den Login-Start aktivieren.

## Projektstruktur

```
Sources/
  DriveCheckMenuCore/     Fachlogik, Parser, Probes, Auswahl, Benachrichtigungen
  DriveCheckMenu/         AppKit/SwiftUI-Oberfläche, Menü, Einstellungen
Tests/
  DriveCheckMenuTests/    Unit-Tests mit echten diskutil-/smartctl-Fixtures
Resources/                Info.plist, App-Icon
scripts/                  Build- und Icon-Skripte
docs/                     Software-Design-Beschreibung nach arc42
```

Die Kapazitätsermittlung liegt in `Sources/DriveCheckMenuCore/StorageUsageProbe.swift` (Mount-Samples via `getfsstat`, Zuordnung zu Whole Disks, APFS-Dedupe, Plist-Fallback).

## Tests

```sh
swift test
```

Die Tests verwenden echte, mitgeschnittene Ausgaben von `diskutil` und `smartctl` (NVMe, SATA, AppleRAID) und prüfen Parser, Schwellwerte, RAID-Bewertung, Auswahl-Logik und Einstellungs-Persistenz. Zusätzlich deckt die Suite die Kapazitätsermittlung ab (Whole-Disk-Zuordnung, APFS-Dedupe, Plist-Fallback, HFS+/exFAT-Fall, Formatierung und Prozent-Rebasing). Derzeit laufen 23 Tests.

## Dokumentation

- [README.md](README.md) – Einstieg, Installation, Bedienung und Grenzen
- [docs/arc42.md](docs/arc42.md) – Software-Design-Beschreibung nach arc42: Bausteine, Laufzeitsichten, Architekturentscheidungen, Qualitätsanforderungen und Risiken

## Lizenz

Dieses Projekt steht unter der MIT-Lizenz. Siehe [LICENSE](LICENSE).

Copyright © 2026 Christian Witt
