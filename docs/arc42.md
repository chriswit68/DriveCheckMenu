# DriveCheckMenu – Software-Design-Beschreibung nach arc42

| Merkmal | Inhalt |
| --- | --- |
| Projekt | DriveCheckMenu |
| Dokumenttyp | Software-Design-Beschreibung (Architektur) |
| Struktur | arc42, Kapitel 1–12 |
| Stand | 15. November 2026 |
| Bezug | macOS-Menüleisten-App zur Überwachung von Massenspeichern und AppleRAID-Verbünden |
| Sprache | Deutsch (Oberfläche und Dokumentation) |

> Dieses Dokument beschreibt die tatsächlich implementierte Architektur. Es ist keine
> vorausschauende Spezifikation: Wo das Verhalten von macOS, `diskutil` oder `smartctl`
> abhängt, wird die konkrete Behandlung im Code benannt.

## Inhaltsverzeichnis

1. [Einführung und Ziele](#1-einführung-und-ziele)
2. [Randbedingungen](#2-randbedingungen)
3. [Kontextabgrenzung](#3-kontextabgrenzung)
4. [Lösungsstrategie](#4-lösungsstrategie)
5. [Bausteinsicht](#5-bausteinsicht)
6. [Laufzeitsicht](#6-laufzeitsicht)
7. [Verteilungssicht](#7-verteilungssicht)
8. [Querschnittskonzepte](#8-querschnittskonzepte)
9. [Architekturentscheidungen](#9-architekturentscheidungen)
10. [Qualitätsanforderungen](#10-qualitätsanforderungen)
11. [Risiken und technische Schulden](#11-risiken-und-technische-schulden)
12. [Glossar](#12-glossar)

---

## 1. Einführung und Ziele

### 1.1 Aufgabenstellung

DriveCheckMenu ist eine native macOS-Menüleisten-App. Sie überwacht die SMART-Gesundheit
physischer interner und externer Massenspeicher sowie konfigurierter AppleRAID-Verbünde.
Zusätzlich zeigt sie die aktuelle Speicherbelegung der eingehängten Dateisysteme an.

Der Benutzer wählt aus, welche Laufwerke und RAID-Sets überwacht werden. Ein Symbol in der
Menüleiste fasst den Gesamtzustand zusammen:

- neutral/ungefärbt: alles in Ordnung, Status unbekannt oder noch keine Auswahl,
- gelb: Warnung (z. B. hohe Temperatur, Verschleiß, Medienfehler, Standby, nicht verbunden,
  laufender RAID-Rebuild),
- rot: Problem (z. B. SMART-Fehler, kritische Warnung, schwebende Sektoren, degradiertes
  oder offline gesetztes RAID).

Linksklick öffnet das Statusmenü, Rechtsklick oder `Ctrl`-Klick öffnet die Einstellungen.
Die App läuft als Menüleisten-Anwendung ohne Dock-Symbol (`LSUIElement`).

### 1.2 Wichtigste Funktionen

| Funktion | Kurzbeschreibung |
| --- | --- |
| Laufwerksinventar | Physische Whole Disks über `diskutil list`/`diskutil info`, virtuelle Geräte werden gefiltert |
| SMART-Auswertung | Bevorzugt `smartctl -a -j`, inklusive Temperatur, Verschleiß, Reserve, Medienfehlern, Sektoren, Fehlerprotokoll |
| SMART-Fallback | Basisstatus aus `diskutil`, wenn `smartctl` fehlt, keine Rechte hat oder keine verwertbaren Daten liefert |
| AppleRAID | Set-Status, Mitgliederstatus und Rebuild-Fortschritt über `diskutil appleRAID` |
| Speicherbelegung | Belegte Bytes und Prozent aus eingehängten Dateisystemen, effizient über `getfsstat` und die vorhandene Plist |
| Auswahl | Stabile Laufwerksidentität (Seriennummer bevorzugt), RAID-Auswahl, „Alle auswählen“ |
| Intervalle | Jede Minute bis täglich; Standard sind fünf Minuten |
| Schwellwerte | Temperatur- und Verschleißwarnungen konfigurierbar |
| SMART-Kurztest | Start pro Laufwerk, optional einmalige Administratorfreigabe |
| Benachrichtigungen | Meldung beim Übergang eines überwachten Geräts in den Problemzustand und zurück |
| Login-Start | `SMAppService.mainApp`, Statusanzeige in den Einstellungen |
| Diagnose | `--dump`, `--smoke` und Simulationsmodi für Fehlerfälle |

### 1.3 Qualitätsziele

Die Reihenfolge drückt die priorisierten Ziele aus.

| Priorität | Ziel | Konkretisierung |
| --- | --- | --- |
| 1 | Korrekte, nachvollziehbare Bewertung | Jede Warnung und jedes Problem wird mit einer Begründung im Menü angezeigt; Schwellwerte sind sichtbar und einstellbar |
| 2 | Geringe Systembelastung | Die Belegungsermittlung startet keinen zusätzlichen Prozess und verursacht keinen Dateisystem-Scan; der Scan läuft nicht auf dem UI-Thread |
| 3 | Robustheit gegenüber Fremdwerkzeugen | Fehlendes `smartctl`, Rechteprobleme, unerwartete Ausgaben und Timeouts führen zu einem definierten Fallback statt zu einem Absturz |
| 4 | Stabile Auswahl über Neustarts | Laufwerke werden über Seriennummer, ersatzweise Modell + Größe, wiedererkannt |
| 5 | Datenschutz und Lokalität | Keine Netzwerkkommunikation, keine Cloud, keine Telemetrie; Einstellungen bleiben lokal |
| 6 | Wartbarkeit | Trennung von Fachlogik (`DriveCheckMenuCore`) und Oberfläche (`DriveCheckMenu`), Parser mit Fixtures getestet |
| 7 | Bedienbarkeit | Deutsche Oberfläche, selbsterklärende Menüstruktur, Statusfarben und Tooltips |

### 1.4 Stakeholder

| Stakeholder | Erwartung |
| --- | --- |
| Benutzer | Schneller Blick auf Laufwerksgesundheit und Belegung, zuverlässige Warnungen |
| Betreiber/Administrator | Keine dauerhaften Root-Dienste, nachvollziehbare Rechteanforderung |
| Entwickler | Klare Modulgrenzen, testbare Parser, dokumentierte Fallbacks |
| Datenschutz/Compliance | Rein lokale Verarbeitung, keine Übertragung von Laufwerksdaten |
| Projektumfeld | Vibe-Code-Experiment; Code dient dem Ausprobieren und Lernen, nicht als zertifiziertes Produkt |

### 1.5 Abgrenzung

Nicht im Scope:

- Überwachung von Software-RAIDs anderer Hersteller (z. B. mdadm, SoftRAID),
- dauerhafte Hintergrundüberwachung ohne laufende App,
- privilegierte Hintergrunddienste, Kernel-Extensions oder System-Extensions,
- Fernüberwachung, zentrale Auswertung oder Benachrichtigungen über das Netz,
- Änderung oder Reparatur von Laufwerken, Dateisystemen oder RAID-Verbünden,
- Smart-Fernabfrage über Netzwerkprotokolle.

---

## 2. Randbedingungen

### 2.1 Technische Randbedingungen

| Randbedingung | Ausprägung im Projekt |
| --- | --- |
| Zielplattform | macOS 14 (Sonoma) oder neuer; `LSMinimumSystemVersion` = `14.0` |
| Architektur | Apple Silicon und Intel; Universal Binary über `make universal` möglich |
| Sprache/Toolchain | Swift 6 Compiler, Sprachmodus Swift 5 (`swiftLanguageModes: [.v5]`) |
| Buildsystem | Swift Package Manager, ergänzt um `Makefile` und `scripts/build-app.sh` |
| UI-Technologie | AppKit für Menüleiste und Fenster, SwiftUI für Einstellungen |
| App-Bundle | Eigener Bundle-Bau; `CFBundleIdentifier` = `de.chriswit.DriveCheckMenu`; `LSUIElement` = `true` |
| Signierung | Apple-Development-Identität, falls im Schlüsselbund verfügbar, sonst Ad-hoc-Signatur |
| Systemwerkzeuge | `/usr/sbin/diskutil`, optional `smartctl` aus smartmontools |
| Kernel-Schnittstelle | `getfsstat`/`statfs` für eingehängte Dateisysteme |
| Persistenz | `UserDefaults` unter dem Schlüssel `DriveCheckMenu.settings.v1`, JSON-kodiert |
| Login-Start | `SMAppService.mainApp` (ServiceManagement) |
| Benachrichtigungen | `UserNotifications` |
| Smartctl-Suchpfade | `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, `/usr/bin` |
| Rechte | Kein dauerhafter Root-Helper; einmaliger `osascript`-Dialog für den SMART-Kurztest möglich |
| Lokalisierung | Feste deutsche Texte; `defaultLocalization: "de"` |

### 2.2 Organisatorische und konzeptionelle Randbedingungen

| Randbedingung | Konsequenz |
| --- | --- |
| Vibe-Code-Experiment | Fokus auf Funktionalität und Nachvollziehbarkeit; keine Produktgarantie |
| Ein Repository, ein ausführbares Produkt | `DriveCheckMenuCore` als Bibliothek, `DriveCheckMenu` als Executable |
| Keine externen Laufzeitabhängigkeiten außer Systemtools | Kein Paketmanager zur Laufzeit, keine eingebetteten Bibliotheken Dritter |
| Datenschutz durch Lokalität | Keine Netzwerk-Sockets, keine Analysedienste |
| Dokumentation auf Deutsch | README und arc42-Dokument in deutscher Sprache; Code-Kommentare teils englisch |
| Manuelle Verifikation auf echter Hardware | Kein CI-System und keine automatisierte Hardware-in-the-Loop-Prüfung im Repository |

### 2.3 Gesetzliche und sicherheitsrelevante Randbedingungen

- Die App liest ausschließlich lokal vorliegende Geräte- und Dateisystemdaten.
- Es werden keine Laufwerksinhalte gelesen oder verändert.
- Administratorrechte werden nur für den expliziten SMART-Kurztest und nur mit
  Benutzerbestätigung angefordert.
- Die App ist derzeit nicht sandboxed und nicht notarisiert; sie ist für den lokalen
  Eigenbetrieb gedacht.

---

## 3. Kontextabgrenzung

### 3.1 Fachlicher Kontext

DriveCheckMenu beobachtet Massenspeicher und RAID-Verbünde und stellt deren Zustand für
einen menschlichen Benutzer dar. Die App trifft keine automatischen Reparaturentscheidungen.

| Nachbar | Beziehung |
| --- | --- |
| Benutzer | Wählt Geräte aus, liest Status, startet SMART-Kurztest, ändert Schwellwerte und Intervalle |
| macOS-Benutzeroberfläche | Menüleiste, Benachrichtigungszentrum, Systemeinstellungen (Login-Start, Menüleistenfreigabe) |
| Massenspeicher | Liefern SMART-Daten, Dateisysteme und RAID-Mitgliedschaften |
| AppleRAID | Vom System verwaltete RAID-Verbünde werden gelesen, nicht verändert |

### 3.2 Technischer Kontext

```text
                         +--------------------------------------+
                         |           DriveCheckMenu             |
                         |  Menüleisten-App (AppKit/SwiftUI)    |
                         +---+------+-------+-------+------+---+
                             |      |       |       |      |
          Process/JSON       |      |       |       |      | UserDefaults
          +------------------+      |       |       |      +------------------+
          |                         |       |       |                         |
          v                         v       v       v                         v
 +-----------------+        +-------------+ +-------------+          +----------------+
 | smartctl        |        | diskutil    | | Kernel      |          | macOS          |
 | (optional)      |        | (System)    | | getfsstat   |          | UserDefaults   |
 +-----------------+        +-------------+ +-------------+          +----------------+
          ^                         ^             ^
          | SMART-Daten             | Plist-Daten | Mount-/Dateisystemdaten
          |                         |             |
     +----+-------------------------+-------------+----+
     |                   Massenspeicher                |
     |          SSD/HDD/NVMe/SATA/USB, APFS/HFS+/exFAT |
     +-------------------------------------------------+
```

Weitere technische Nachbarn:

| Nachbar | Richtung | Schnittstelle | Zweck |
| --- | --- | --- | --- |
| `diskutil` | App → Tool | `list -plist`, `info -plist`, `appleRAID list -plist`, `appleRAID list` | Inventar, Basis-SMART, RAID |
| `smartctl` | App → Tool | `--version`, `-a -j -n standby`, `-t short`, `-l selftest -j` | Detaillierte SMART-Werte und Kurztest |
| Kernel | App → Syscall | `getfsstat`/`statfs` mit `MNT_NOWAIT` | Belegung eingehängter Dateisysteme |
| `osascript` | App → Tool | `do shell script … with administrator privileges` | Einmaliger Start des Kurztests mit Adminrechten |
| `UserNotifications` | App → System | lokale Benachrichtigungen | Problem- und Selbsttestmeldungen |
| `SMAppService` | App → System | `register`/`unregister`/`status` | Login-Start |
| Finder/`open` | Benutzer → App | App-Bundle-Start | Normaler Start der Menüleisten-App |

### 3.3 Schnittstellen- und Datenformatdetails

- `diskutil`-Ausgaben werden als Property List mit `PropertyListSerialization` gelesen.
- `smartctl`-Ausgaben werden als JSON mit `JSONSerialization` gelesen; Textausgaben dienen
  nur als Fehlermeldung oder für den Rebuild-Fortschritt.
- Die Prozessumgebung setzt `LC_ALL=C`, `LANG=en_US.UTF-8` und einen ergänzten `PATH`,
  damit GUI-Starts ohne Login-Shell dieselben Werkzeuge finden und JSON stabil bleibt.
- Es gibt keine eingehenden Netzwerk-Schnittstellen.

---

## 4. Lösungsstrategie

### 4.1 Grundidee

Die App ist ein periodisch arbeitender **Pull-Monitor**: Ein Timer stößt einen Scan an,
der aus den aktuellen Systemdaten einen unveränderlichen `MonitorSnapshot` erzeugt. Die
Oberfläche liest ausschließlich diesen Snapshot. Dadurch sind Datenerhebung, Bewertung
und Darstellung klar getrennt.

```text
 Timer / manueller Refresh
          |
          v
   MonitorService  --->  StatusCollector (Hintergrund-Task)
                              |
        +---------------------+----------------------+
        |                     |                      |
 DiskInventory          SmartctlProbe            RaidProbe
 (diskutil)             (optional smartctl)      (diskutil appleRAID)
        |                     |                      |
        +----------+----------+----------+-----------+
                   |                     |
             HealthEvaluator      StorageUsageProbe
                   |                     |
                   +----------+----------+
                              |
                              v
                     MonitorSnapshot
                              |
                 +------------+-------------+
                 |                          |
         AppState (MainActor)        --dump / --smoke
                 |
      +----------+-----------+
      |                      |
 StatusItemController    Notifier
 (Icon, Menü, Tooltip)  (Problemübergänge)
```

### 4.2 Zentrale Strategien

| Strategie | Umsetzung |
| --- | --- |
| Schichten trennung | `DriveCheckMenuCore` enthält Modelle, Probes, Parser, Bewertung und Persistenz; `DriveCheckMenu` nur UI und App-Lebenszyklus |
| Ein Snapshot pro Scan | Alle Anzeigen arbeiten mit demselben konsistenten Datenstand |
| Hintergrundarbeit | Scan in `Task.detached(priority: .utility)`; UI-Aktualisierung via `MainActor` |
| Werkzeuge kapseln | `Shell.run` kapselt Prozessstart, Ausgabeerfassung, Timeouts und PATH |
| Fallback statt Abbruch | `smartctl` → `diskutil`-Basisstatus; fehlende Belegung → Zeile entfällt; fehlendes RAID → Platzhalter |
| Effiziente Belegung | Zwei `getfsstat`-Aufrufe plus bereits vorhandene `diskutil list`-Plist; kein `df`/`du`, kein zusätzlicher Prozess |
| Stabile Identität | `serial:…`, sonst Modell + Größe; Duplikate werden mit BSD-Namen eindeutig gemacht |
| Bewertung mit Begründung | `HealthEvaluator` liefert `HealthLevel` und eine Liste lesbarer Gründe |
| Konfiguration lokal | `AppSettings` als JSON in `UserDefaults`, tolerant gegenüber fehlenden Feldern |
| Sichere Rechte | Kein Root-Dauerzustand; Admin nur auf expliziten Benutzerwunsch pro Kurztest |
| Diagnose eingebaut | `--dump`, `--smoke`, Simulationsmodi und `NSLog`-Diagnosen |

### 4.3 Architekturstil

Die Architektur ist eine **modulare Monolith-App** mit einer UI-Schicht und einer
Fachbibliothek. Es gibt keine Server-, Plugin- oder Microservice-Struktur. Die
Hauptmuster sind:

- **Ports-and-Adapters** im Kleinen: Probes kapseln Systemwerkzeuge, der Core kennt keine
  AppKit-Typen.
- **Snapshot/Immutable View Model**: `MonitorSnapshot` und die Statusstrukturen sind
  `Sendable`-Werttypen.
- **Observer**: `AppState` ist `ObservableObject`; SwiftUI und der StatusItemController
  abonnieren Änderungen.
- **Template Method für Bewertung**: `HealthEvaluator` sammelt Gründe und hebt den
  Schweregrad monoton an („raise“).

---

## 5. Bausteinsicht

### 5.1 Ebene 1 – Gesamtsystem

```text
+-----------------------------------------------------------------------+
| DriveCheckMenu.app                                                    |
|                                                                       |
|  +---------------------------+      +------------------------------+  |
|  | DriveCheckMenu (Executable)| ---> | DriveCheckMenuCore (Library) |  |
|  | AppKit/SwiftUI, Lifecycle |      | Modelle, Probes, Parser,     |  |
|  | Menü, Einstellungen       |      | Bewertung, Persistenz        |  |
|  +---------------------------+      +------------------------------+  |
|                                                                       |
+-----------------------------------------------------------------------+
             |                                   |
             v                                   v
      Systemwerkzeuge                     macOS-Dienste
      diskutil, smartctl, osascript       UserDefaults, SMAppService,
                                          UserNotifications, Kernel
```

### 5.2 Ebene 2 – Core-Bausteine

| Baustein | Datei | Verantwortung |
| --- | --- | --- |
| Modelle | `Models.swift` | `HealthLevel`, `SmartHealth`, `AtaAttribute`, `StorageUsage`, `DriveInfo`, `StoredDrive`, `DriveStatus`, `RaidMember`, `RaidSetInfo`, `StoredRaid`, `RaidStatus`, `MonitorSnapshot` |
| Einstellungen | `AppSettings.swift` | `HealthThresholds`, `CheckInterval`, `AppSettings`, `SelectionMatcher` |
| Persistenz | `SettingsStore.swift` | Laden/Speichern des JSON-Blobs in `UserDefaults` |
| Shell | `Shell.swift` | Prozessausführung mit Timeout, stdout/stderr, PATH-Ergänzung |
| Laufwerksinventar | `DiskInventory.swift` | Plist-Parsing, Whole-Disk-Filter, stabile IDs, Kombination von Inventar und Belegung |
| Belegungsprobe | `StorageUsageProbe.swift` | `getfsstat`, Mapping Dateisystem → Whole Disk, APFS-Dedupe, Plist-Fallback |
| SMART-Probe | `SmartctlProbe.swift` | Locator, Gerätetyp-Fallbacks, JSON-Parser, Exit-Code-Bits |
| Selbsttest | `SelfTestService.swift` | Start, Admin-Fallback, Polling, Zustände |
| Selbsttest-Parser | `SelfTestParser.swift` | Fortschritt und Ergebnis aus `-l selftest -j` |
| RAID-Probe | `RaidProbe.swift` | AppleRAID-Plist und Textausgabe, Rebuild-Fortschritt |
| Bewertung | `HealthEvaluator.swift` | Schwellwert- und Zustandslogik, Gründe, Formatierung |
| Orchestrierung | `StatusCollector.swift` | Ein Scan: Inventar, SMART, RAID, Belegung, Bewertung, Gesamtstatus, Simulation |
| Monitoring | `MonitorService.swift` | Timer, Intervalländerungen, Scan-Sperre, Hintergrund-Task |
| App-Zustand | `AppState.swift` | Beobachtbarer Zustand, Auswahl, Default-Auswahl, Benachrichtigungen, Login-Status |
| Login-Start | `LoginItem.swift` | `SMAppService`-Kapselung und Statustexte |
| Benachrichtigungen | `Notifier.swift` | Autorisierung und lokale Meldungen |

### 5.3 Ebene 2 – UI-Bausteine

| Baustein | Datei | Verantwortung |
| --- | --- | --- |
| Einstieg | `main.swift` | `--dump`, `--smoke`, normaler App-Start |
| App-Lebenszyklus | `AppDelegate.swift` | Accessory-Policy, Aufbau von `AppState` und StatusItem, Menüleisten-Freigabe |
| StatusItem | `StatusItemController.swift` | Symbol, Tooltip, Klickbehandlung, Einstellungsfenster, Aktionen |
| Menüaufbau | `StatusMenuBuilder.swift` | Statusmenü, Untermenüs, SMART-Details, Belegung, Selbsttesteinträge |
| Einstellungsfenster | `SettingsWindowController.swift` | NSWindow mit SwiftUI-Hosting-Controller |
| Einstellungs-Tabs | `SettingsView.swift` | Allgemein, Laufwerke, RAID, SMART |
| Allgemein | `GeneralSettingsView.swift` | Login-Start, Menüleistenstatus, Intervall, Benachrichtigungen, manuelle Prüfung |
| Laufwerke | `DrivesSettingsView.swift` | Auswahl und Detailzeile inklusive Belegung |
| RAID | `RaidSettingsView.swift` | Auswahl und Detailzeile inklusive Belegung |
| SMART | `SmartSettingsView.swift` | smartctl-Pfad, Schwellwerte, Kurztest |
| Menüleisten-Freigabe | `MenuBarPermission.swift` | Öffnen der macOS-Menüleisten-Einstellungen |
| UI-Hilfen | `UIHelpers.swift` | `StatusDot`, `HealthBadge`, Abschnittsköpfe |

### 5.4 Detaillierte Bausteinsicht – Scan-Pipeline

```text
StatusCollector.collect(settings)
  |
  +-- SmartctlLocator.locate / version
  |
  +-- DiskInventory.inventory()
  |     +-- Shell.run(diskutil list -plist)          (1 Prozess)
  |     +-- für jede Whole Disk: diskutil info -plist (n Prozesse)
  |     +-- StorageUsageProbe.currentMountSamples()   (2 Syscalls: Anzahl + Daten)
  |     +-- StorageUsageProbe.usages(...)             (reine Berechnung)
  |
  +-- pro Laufwerk: SmartctlProbe.probe(...)
  |     +-- bis zu 3 Versuche: ohne -d, -d sat, -d nvme
  |     +-- SmartctlParser.parse(...)
  |     +-- sonst diskutilFallback(...)
  |
  +-- RaidProbe.sets()
  |     +-- diskutil appleRAID list -plist
  |     +-- diskutil appleRAID list
  |
  +-- HealthEvaluator.evaluate(...) pro Laufwerk/RAID
  +-- Usage rebased(toTotal:) pro Laufwerk/RAID
  +-- Platzhalter für nicht verbundene Auswahl
  +-- Sortierung und MonitorSnapshot.recalculateOverall()
```

### 5.5 Detaillierte Bausteinsicht – Belegungsermittlung

```text
StorageUsageProbe
  |
  +-- currentMountSamples()
  |     getfsstat(nil, 0, MNT_NOWAIT)  -> Anzahl
  |     getfsstat(buffer, size, MNT_NOWAIT)
  |     pro Mount: f_mntfromname, f_bsize, f_blocks, f_bfree
  |     total = f_blocks * f_bsize
  |     used  = (f_blocks - f_bfree) * f_bsize
  |
  +-- usages(allDisksAndPartitions, mounts)
        buildMapping()
          +-- APFS-Container: APFSPhysicalStores -> Whole Disks
          |   APFSVolumes -> Container-Kennung, Größe, Mount-Zustand
          +-- Sonst: Partitionen -> Whole Disk
        Mount-Samples zuordnen
          +-- APFS: pro Container nur einmal zählen
          +-- Plain: pro Gerät nur einmal zählen
        Fallback
          +-- nur für laut Plist eingehängte, nicht gemessene APFS-Container
          +-- Summe CapacityInUse ohne Snapshot-Duplikate
        StorageUsage.combined(...) pro Ziel-Whole-Disk
```

Wichtige Invarianten:

- Ein Ziel kann mehrere Dateisysteme/Container enthalten; deren Werte werden addiert.
- Ein APFS-Container wird nie mehrfach gezählt, auch wenn mehrere Volumes gemountet sind.
- Die Anzeige bezieht den Prozentwert auf die Gerätegröße (`rebased(toTotal:)`), nicht auf
  die Dateisystemgröße. Das hält „Belegt … von …“ konsistent zur „Größe“-Zeile.
- Ohne messbares oder plausibles Dateisystem entsteht kein `StorageUsage`; die UI lässt
  die Zeile dann weg.

---

## 6. Laufzeitsicht

### 6.1 Szenario „Periodischer Scan“

```text
Timer (MonitorService)
   |
   | performScan()
   v
isScanning? --ja--> verwerfen
   |
   nein
   v
Task.detached(.utility)
   |
   +--> StatusCollector.collect(settings)
   |       |
   |       +--> Inventar + SMART + RAID + Belegung + Bewertung
   |       |
   |       +--> MonitorSnapshot
   |
   v
MainActor.run
   |
   +--> isScanning = false
   +--> AppState.handle(snapshot)
           |
           +--> Default-Auswahl beim ersten Lauf
           +--> Metadaten der Auswahl abgleichen
           +--> Auswahl anwenden, Simulation anwenden
           +--> Gesamtstatus neu berechnen
           +--> Problemübergänge benachrichtigen
           +--> snapshot veröffentlichen
                   |
                   +--> StatusItemController: Icon + Tooltip
                   +--> SwiftUI: Einstellungen aktualisieren
```

Eigenschaften:

- Ein laufender Scan wird nicht überlappt: Weitere Anstöße werden über `isScanning`
  verworfen, bis der laufende Scan abgeschlossen ist.
- Das Intervall wird auf mindestens 30 Sekunden begrenzt; die Timer-Toleranz beträgt
  höchstens 30 Sekunden bzw. 10 % des Intervalls.
- Intervalländerungen planen den Timer neu; Intervall- oder smartctl-Änderungen lösen
  sofort einen Scan aus.

### 6.2 Szenario „Erster Start und Default-Auswahl“

```text
AppDelegate.applicationDidFinishLaunching
   |
   +--> NSApp.setActivationPolicy(.accessory)
   +--> AppState() lesen (UserDefaults)
   +--> StatusItemController.install()
   +--> AppState.start() -> MonitorService.start()
   |       +--> Timer planen
   |       +--> sofort scannen
   +--> Notifier.requestAuthorization()
   +--> Menüleisten-Sichtbarkeit nach 2 s prüfen
```

Beim ersten erfolgreichen Scan mit verbundenen Geräten und noch nicht angewandter
Default-Auswahl werden alle verbundenen Laufwerke und RAID-Sets ausgewählt und gespeichert.
Danach werden nur noch Metadaten (Name, Modell, Größe, Seriennummer) der gespeicherten
Auswahl aktualisiert. Die Auswahl selbst bleibt benutzerbestimmt.

### 6.3 Szenario „SMART-Kurztest ohne und mit Administratorrechten“

```text
Benutzer: „SMART-Kurztest starten“
   |
   v
SelfTestService.start(bsdName, smartctlPath, key)
   |
   +--> Validierung: bsdName ^disk[0-9]+$
   +--> Shell.run(smartctl -t short <bsd>, timeout 30 s)
           |
           +-- Status 0 --> markStarted() --> Polling
           |
           +-- Fehler mit Rechtehinweis
                   |
                   v
             requiresAdmin = true
                   |
             Menü zeigt „Mit Administratorrechten starten …“
                   |
                   v
             startWithAdministrator()
                   +--> osascript: do shell script "…" with administrator privileges
                   +--> Erfolg --> markStarted() --> Polling
                   +--> Abbruch/Fehler --> Zustand mit Meldung
```

Polling:

- alle 10 Sekunden `smartctl -l selftest -j <bsd>`, Timeout 20 Sekunden,
- maximal 180 Versuche (ca. 30 Minuten),
- Fortschritt und Meldung werden in `TestState` veröffentlicht,
- bei Abschluss wird `onFinished` aufgerufen; `AppState` sendet eine lokale Benachrichtigung,
- ein „finished“ ohne vorher beobachtetes „running“ wird bis zu drei Versuche lang toleriert,
  um nicht sofort ein altes Ergebnis zu melden.

### 6.4 Szenario „Belegungsermittlung während eines Scans“

```text
DiskInventory.inventory()
   |
   +--> diskutil list -plist
   |       |
   |       +--> Whole Disks, Partitionen, APFS-Container, APFS-Volumes
   |
   +--> getfsstat (MNT_NOWAIT)
   |       |
   |       +--> gemountete Geräte mit Gesamt- und Frei-Blöcken
   |
   +--> StorageUsageProbe.usages(...)
           |
           +--> Mount-Gerät -> Container/Whole Disk
           +--> APFS-Container deduplizieren
           +--> Fallback CapacityInUse, falls nötig
           +--> Summen pro Whole Disk
   |
   v
StatusCollector: usage.rebased(toTotal: drive.sizeBytes)
   |
   v
Anzeige „Belegt: <used> von <total> (<ganzzahliger Prozentwert> %)“
```

Es wird kein zusätzlicher Prozess gestartet. `getfsstat` mit `MNT_NOWAIT` liefert die
bereits bekannten Mount-Informationen, ohne auf Platten-I/O zu warten. Dadurch bleibt ein
Laufwerk im Standby, sofern es nicht ohnehin für SMART geweckt wird.

### 6.5 Szenario „Problem erkannt und behoben“

```text
vorheriger Snapshot --+
                      +--> problemKeys(previous) = { … }
aktueller Snapshot ---+--> problemKeys(current)  = { … }
                                |
                                +--> neu:     Benachrichtigung „Laufwerksproblem erkannt“
                                +--> entfallen: „Laufwerksproblem behoben“
```

Benachrichtigt werden nur überwachte Geräte mit `HealthLevel.problem`, sofern die
Benachrichtigungen in den Einstellungen aktiviert sind. Reine Warnungen lösen keine
Benachrichtigung aus. Die Meldung enthält den Gerätenamen und die gesammelten
Begründungen. Ohne App-Bundle (Direktstart der Binärdatei) sind Benachrichtigungen
deaktiviert, weil keine Bundle-ID vorhanden ist.

### 6.6 Szenario „Menüleistensymbol unter macOS 26+ unsichtbar“

```text
AppDelegate
   +--> nach 2 s Sichtbarkeit prüfen
   +--> sichtbar? --> fertig
   +--> sonst: Fehlerzähler erhöhen, nach 5 s erneut prüfen (max. 12 Prüfungen)
   +--> ab 2 Fehlschlägen: einmaliger Hinweisdialog
           +--> „Menüleisten-Einstellungen öffnen“ -> x-apple.systempreferences:…
           +--> „Später“
```

Der Status wird zusätzlich in „Einstellungen → Allgemein → Menüleiste“ angezeigt. Ein
erneuter App-Start bei laufender Instanz öffnet die Einstellungen, damit die App nicht
wirkungslos zu sein scheint.

### 6.7 Diagnose-Szenarien

| Aufruf | Verhalten |
| --- | --- |
| `DriveCheckMenu --dump` | Einmaliger Scan, Textausgabe im Terminal, kein Menü, kein UI-Start |
| `DriveCheckMenu --smoke` | Baut StatusItem und Einstellungen auf, wartet auf Snapshot, gibt Diagnosezeile aus |
| `--simulate=failing` | Markiert ein Laufwerk als Problem |
| `--simulate=degraded` | Markiert ein RAID-Set als degradiert |
| `--simulate=missing` | Markiert ein Laufwerk als nicht verbunden |
| `DCM_SIMULATE=…` | Wie `--simulate`, per Umgebungsvariable |

Simulationen verändern nur den angezeigten Snapshot, nicht die echten Geräte.

---

## 7. Verteilungssicht

### 7.1 Deployment-Einheiten

| Einheit | Inhalt | Erzeugung |
| --- | --- | --- |
| `DriveCheckMenu.app` | Executable, `Info.plist`, `AppIcon.icns`, `PkgInfo`, Code-Signatur | `scripts/build-app.sh` über `make app` |
| `DriveCheckMenuCore` | Statisch gelinkte Swift-Bibliothek im Executable | SwiftPM-Target |
| Test-Bundle | Unit-Tests und Fixtures | `swift test` |
| Dokumentation | README und arc42 | Repository |

### 7.2 Laufzeitverteilung

```text
+--------------------------------------------------------------+
| macOS-Host                                                   |
|                                                              |
|  +---------------------------+        +-------------------+   |
|  | DriveCheckMenu.app        |        | smartctl          |   |
|  |  (ein Prozess, accessory) |        | (Unterprozess)    |   |
|  +-------------+-------------+        +-------------------+   |
|                |                              ^               |
|                | Process                      |               |
|                +------------------------------+               |
|                |                                              |
|                | Process                                      |
|                v                                              |
|         +-------------------+                                 |
|         | diskutil          |                                 |
|         +-------------------+                                 |
|                |                                              |
|                v                                              |
|         +-------------------+        +-------------------+    |
|         | Kernel/getfsstat  |        | launchd/UserAgent |    |
|         +-------------------+        +-------------------+    |
|                                                              |
|  Persistenz: ~/Library/Preferences/de.chriswit.DriveCheckMenu.plist |
+--------------------------------------------------------------+
```

- Es gibt keinen Server, keine Datenbank und keine Netzwerkkomponente.
- Alle Unterprozesse werden synchron mit Timeout gestartet und nach Beendigung
  eingesammelt; es bleiben keine Hintergrundprozesse der App zurück.
- Der Login-Start registriert die App bei `launchd` über `SMAppService.mainApp`.
- Für zuverlässigen Login-Start sollte die App in `/Applications` liegen.

### 7.3 Bundle-Aufbau

```text
DriveCheckMenu.app/
  Contents/
    Info.plist            # LSUIElement=true, Bundle-ID, Mindestversion
    PkgInfo               # APPL????
    MacOS/
      DriveCheckMenu      # ausführbares Binary
    Resources/
      AppIcon.icns
```

### 7.4 Build- und Signaturablauf

```text
make app
  -> scripts/build-app.sh
       -> swift build -c release --product DriveCheckMenu
       -> ggf. Icon erzeugen (swift scripts/make-icns.swift)
       -> Bundle-Verzeichnisse anlegen
       -> Binary, Info.plist, Icon, PkgInfo kopieren
       -> Codesign:
            Apple Development, falls verfügbar
            sonst Ad-hoc (-)
       -> codesign --verify --deep --strict
```

`make universal` setzt `UNIVERSAL=1` und baut zusätzlich `x86_64`.

---

## 8. Querschnittskonzepte

### 8.1 Nebenläufigkeit und Threading

| Bereich | Konzept |
| --- | --- |
| UI | `@MainActor` für `AppState`, `MonitorService`, `SelfTestService`, `StatusItemController`, `AppDelegate` |
| Scan | `Task.detached(priority: .utility)`, Ergebnis Rückgabe über `await MainActor.run` |
| Selbsttest | Start in `Task.detached(.userInitiated)`, Polling als `Task` mit `Task.sleep` |
| Modelle | Werttypen und `Sendable`, damit sie zwischen Tasks wandern können |
| Timer | `Timer` im `RunLoop.main` mit `.common`-Mode und Toleranz |
| Scan-Sperre | `isScanning` verhindert Überlappung |

### 8.2 Prozessausführung und Timeouts

`Shell.run` ist die einzige Stelle, die externe Prozesse startet:

- prüft vorab `isExecutableFile`,
- setzt stdin auf `/dev/null`,
- liest stdout und stderr parallel in `DispatchQueue.global(qos: .utility)`,
- pollt die Laufzeit in 20-ms-Schritten bis zum Deadline,
- beendet bei Timeout mit `terminate()`, nach 200 ms notfalls `SIGKILL`,
- liefert Status, stdout, stderr und `timedOut`,
- ergänzt `PATH` um Homebrew-/MacPorts-Pfade und setzt `LC_ALL=C`.

Standard-Timeout: 20 Sekunden. Spezifische Timeouts: smartctl-Version 5 s,
SMART-Probe 20 s, Selbsttest-Start 30 s, Selbsttest-Abfrage 20 s, `osascript` 120 s.

### 8.3 Fehlerbehandlung und Fallbacks

| Fehlerfall | Reaktion |
| --- | --- |
| `smartctl` nicht gefunden | Inventar und RAID funktionieren weiter; SMART-Basisstatus via `diskutil` |
| `smartctl` ohne Rechte | `unavailableReason`; Bewertung nach dem `diskutil`-Basisstatus (OK/Problem/…), ohne nutzbaren Basisstatus Warnung; Kurztest bietet Adminstart an |
| SMART-Gerät im Standby | Warnung „Laufwerk im Standby – SMART nicht geprüft“ |
| Ungültiges JSON | Parser liefert `nil`; nächster Gerätetyp wird versucht |
| `diskutil`-Plist unlesbar | leeres Inventar; Snapshot bleibt gültig, aber ohne Geräte |
| Keine Belegung messbar | `usage` bleibt `nil`; UI lässt die Zeile weg |
| RAID-Set verschwunden | Platzhalter mit Warnung „RAID-Set nicht verfügbar“ |
| Laufwerk nicht verbunden | Platzhalter mit Warnung „Nicht verbunden“ |
| Prozess-Timeout | Ergebnis mit `timedOut`; Bewertung über fehlende Daten |
| Keine SMART-Daten | Warnung „Keine SMART-Daten verfügbar“ |

### 8.4 Bewertungslogik

`HealthEvaluator` verwendet eine monotone Eskalation: Jeder Befund kann den Schweregrad
nur erhöhen. Die Reihenfolge ist `ok < unknown < warning < problem`.

Laufwerksbewertung (Auszug):

- SMART-Gesamtstatus `false` → Problem,
- kritische Warnung, erschöpfte Reserve, schwebende oder nicht korrigierbare Sektoren,
  fehlschlagendes Prefailure-Attribut → Problem,
- Verschleiß über kritischer Schwelle, Temperatur über kritischer Grenze → Problem,
- Verschleiß über Warnschwelle, Medienfehler, Fehlerprotokoll, wiederzugewiesene Sektoren,
  Temperatur über Warnschwelle, Standby, unbekannter Status → Warnung,
- sonst OK mit Begründung „SMART-Status in Ordnung“.

Die Temperaturgrenzen werden mit den gerätespezifischen Grenzen (`op_limit_max`,
`critical_limit_max`) kombiniert, indem jeweils das Minimum verwendet wird.

RAID-Bewertung:

- `degraded`, `offline`, `failed`, `not online` → Problem,
- Mitglied `missing`/`offline`/`failed`/`degraded` → Problem,
- Mitglied im Rebuild/Resync, laufender Rebuild, unbekannter Status → Warnung,
- keine Mitglieder → Warnung,
- sonst OK mit „RAID <Status>“.

### 8.5 Identität und Auswahl

`StableID.key` erzeugt:

1. `serial:<Seriennummer>`, wenn eine nicht-leere Seriennummer vorliegt,
2. sonst `model:<Modell>|<Größe in Bytes>`.

`StatusCollector` macht Duplikate innerhalb eines Scans eindeutig, indem es `|<bsdName>`
anhängt. `SelectionMatcher` gleicht gespeicherte Auswahl in drei Stufen ab:

1. exakte ID,
2. Seriennummer,
3. eindeutiges Paar aus Modell und Größe.

Dadurch überlebt die Auswahl Neustarts und Umstecken. Nicht verbundene ausgewählte Geräte
bleiben als Warnung sichtbar.

### 8.6 Persistenz und Schema-Evolution

- Ein einziger JSON-Blob unter `DriveCheckMenu.settings.v1`.
- `AppSettings.init(from:)` und `HealthThresholds.init(from:)` verwenden
  `decodeIfPresent` mit Defaults. Fehlende Felder führen daher nicht zu einem
  Dekodierfehler, sondern zu Standardwerten.
- Änderungen an der Auswahl werden sofort gespeichert.
- Es werden keine Konfigurationsdateien außerhalb des App-Containers angelegt.

### 8.7 Formatierung und Lokalisierung

- `Format.bytes` verwendet `ByteCountFormatter` mit `.file` (z. B. `999,86 GB`).
- `Format.number` zeigt ganze Zahlen ohne Nachkommastelle, sonst eine Nachkommastelle.
- Prozente der Belegung werden ganzzahlig mit `%.0f %%` formatiert. Das vermeidet
  uneinheitliche Dezimaltrennzeichen in der deutschen Oberfläche.
- Datums- und Zeitausgaben verwenden `de_DE`.
- Die UI-Texte sind fest im Code hinterlegt; es gibt keine `.strings`-Kataloge.

### 8.8 Sicherheit und Rechte

- Kein dauerhafter Root-Helper, keine privilegierten Daemons.
- `smartctl` läuft normalerweise als angemeldeter Benutzer.
- Der Adminstart erfolgt ausschließlich auf Benutzeraktion über einen einmaligen
  `osascript`-Dialog; der Befehl wird vorher auf Backslashes und Anführungszeichen
  escaped.
- Geräteparameter werden beim Selbsttest auf `^disk[0-9]+$` geprüft; SMART-Proben
  akzeptieren nur BSD-Namen mit Präfix `disk`. Beim Adminstart wird zusätzlich der
  smartctl-Pfad auf `^[A-Za-z0-9/._+-]+$` geprüft.
- Die App liest keine Dateiinhalte von Laufwerken; sie fragt Metadaten und Zähler ab.
- Alle Daten bleiben lokal.

### 8.9 Benachrichtigungen

- Autorisierung wird beim App-Start angefragt.
- Nur Übergänge in oder aus `HealthLevel.problem` werden gemeldet.
- Meldungen zu Problemübergängen tragen eine eindeutige Kennung mit Zeitstempel, damit sie
  nicht dedupliziert werden; die Abschlussmeldung eines Selbsttests verwendet eine feste
  Kennung pro Laufwerk.
- Im Vordergrund werden Banner und Ton angezeigt (`UNUserNotificationCenterDelegate`).
- Ohne Bundle-ID (Direktstart der Binärdatei) werden keine Benachrichtigungen gesendet.

### 8.10 Menüleisten-Lebenszyklus

- `NSStatusItem` mit quadratischem Symbol (`internaldrive`, Template-Bild).
- Bei OK/Unbekannt bleibt das Template-Bild ungefärbt und passt sich der Menüleiste an.
- Warnung = Gelb, Problem = Rot.
- Tooltip enthält Gesamtstatus und alle nicht-OK-Geräte.
- Das Menü wird bei jedem Linksklick neu gebaut und nach dem Schließen wieder entfernt
  (`menuDidClose`), damit Aktionen und Zustände frisch sind.
- Rechtsklick oder `Ctrl`-Klick öffnet die Einstellungen.

### 8.11 Teststrategie

| Testart | Umfang |
| --- | --- |
| Unit-Tests | 23 Tests: SMART-NVMe/ATA-Parsing, Exit-Code-Bits, Schwellwerte, Sektoren, Fallback, Standby, AppleRAID, Rebuild, Selbsttest-Parser, Auswahl, Snapshot-Aggregation, Einstellungen, Belegungsermittlung |
| Fixtures | Echte Ausgaben: `diskutil_list.plist`, `diskutil_info_*.plist`, `appleraid_list.plist`, `smartctl_*.json` |
| UI-Smoke | `--smoke` prüft StatusItem, Icon, Einstellungsfenster, Menüaufbau |
| Manuell | `--dump`, Simulationen, Live-Betrieb mit echten Laufwerken |

Die Belegungstests decken Whole-Disk-Zuordnung, APFS-Dedupe, Plist-Fallback,
HFS+/exFAT-Fall, Formatierung, Rebasing und die Erkennung von Whole-Disk-Namen ab.

### 8.12 Diagnose und Logging

- `NSLog` für Start, Simulationsmodus, Menüleisten-Diagnose und Sichtbarkeitsprüfungen.
- `--dump` für eine vollständige Textaufnahme ohne UI.
- `--smoke` für eine UI-Bauprüfung ohne Bildschirmzugriff.
- `StatusItemController.diagnostics` liefert StatusItem-, Fenster-, Okklusions- und
  Menüinformationen.

---

## 9. Architekturentscheidungen

### ADR-1: Belegung über `getfsstat` und vorhandene `diskutil`-Plist

| Punkt | Inhalt |
| --- | --- |
| Kontext | Die Belegung soll angezeigt werden, ohne die Systemlast spürbar zu erhöhen und ohne Standby-Platten zu wecken |
| Entscheidung | Zwei `getfsstat`-Aufrufe mit `MNT_NOWAIT` (Anzahl, dann Daten) liefern Mount- und Blockdaten; die Partitions-/APFS-Hierarchie kommt aus der ohnehin abgefragten `diskutil list -plist`-Ausgabe |
| Alternativen | `df` (zusätzlicher Prozess), `du` (Dateisystem-Scan, teuer), `URL.resourceValues` (nicht für alle Volumes), eigene IOKit-Abfragen (komplex) |
| Konsequenzen | Kein zusätzlicher Prozess, kein Dateisystem-Scan, keine zusätzlichen Plattenzugriffe; dafür hängen Semantik und Verfügbarkeit von `statfs`/`diskutil` ab |
| Risiko | Nicht eingehängte Dateisysteme haben keine Belegung – gewollt |

### ADR-2: APFS-Container deduplizieren, mehrere Container addieren

| Punkt | Inhalt |
| --- | --- |
| Kontext | Alle Volumes eines APFS-Containers melden denselben containerweiten Speicherverbrauch |
| Entscheidung | Pro Container wird genau ein Mount-Sample gezählt; die Zuordnung erfolgt über `APFSPhysicalStores` und `APFSVolumes`. Mehrere Container auf einer Platte werden summiert |
| Konsequenzen | Keine Mehrfachzählung, realistische Werte für Fusion/Mehrfach-Container |
| Risiko | Die Semantik „belegt“ folgt den Dateisystemen, nicht dem rohen Gerät |

### ADR-3: Prozentwert auf die Gerätegröße beziehen

| Punkt | Inhalt |
| --- | --- |
| Kontext | Dateisystemgröße und angezeigte Gerätegröße können abweichen (z. B. `494,91 GB` vs. `500,28 GB`) |
| Entscheidung | `StorageUsage.rebased(toTotal:)` setzt die Gesamtgröße auf `drive.sizeBytes` bzw. `raid.sizeBytes`; die belegten Bytes bleiben unverändert |
| Konsequenzen | Prozentwert und „Größe“-Zeile passen zusammen; die Anzeige ist in sich konsistent |
| Risiko | Prozentwert weicht von der Dateisystem-Auslastung ab, wenn Reserven/Overhead bestehen |

### ADR-4: `smartctl` bevorzugen, `diskutil` als Fallback

| Punkt | Inhalt |
| --- | --- |
| Kontext | `smartctl` liefert Details, ist aber optional und benötigt teilweise Rechte; `diskutil` liefert nur einen Basisstatus |
| Entscheidung | Zuerst `smartctl -a -j -n standby`, mit Gerätetyp-Fallbacks `-d sat` und `-d nvme`. Ohne verwertbare Daten oder ohne Tool wird der `diskutil`-Status bewertet |
| Konsequenzen | Volle Funktion mit smartmontools, definierte Teilfunktion ohne |
| Risiko | Unterschiedliche Datenqualität je nach Hardware und Rechten |

### ADR-5: Kein dauerhafter Root-Helper

| Punkt | Inhalt |
| --- | --- |
| Kontext | Manche Laufwerke erlauben SMART-Zugriff oder Kurztest nur mit Root |
| Entscheidung | Normalbetrieb ohne Root; Adminstart nur pro Kurztest über `osascript` mit Systemdialog |
| Alternativen | Privilegierter Helper, LaunchDaemon, sudoers-Eintrag |
| Konsequenzen | Einfache Installation, keine dauerhafte Rechteausweitung |
| Risiko | Bei Geräten ohne Benutzer-SMART bleibt nur der Basisstatus |

### ADR-6: Pull-Snapshot statt push-basierter Einzelupdates

| Punkt | Inhalt |
| --- | --- |
| Kontext | Viele Quellen (Laufwerke, RAID, SMART, Belegung) müssen konsistent dargestellt werden |
| Entscheidung | Ein Scan erzeugt einen vollständigen `MonitorSnapshot`; die UI liest nur diesen |
| Konsequenzen | Einfache UI, konsistente Anzeige, leicht testbare Aggregation |
| Risiko | Höhere Latenz als ereignisgetriebene Einzelupdates; für ein Überwachungsintervall unkritisch |

### ADR-7: Stabile Identität über Seriennummer, Fallback Modell + Größe

| Punkt | Inhalt |
| --- | --- |
| Kontext | BSD-Namen können sich nach Neustart/Umstecken ändern |
| Entscheidung | ID = `serial:…`, sonst Modell + Größe; Duplikate werden mit BSD-Name eindeutig gemacht |
| Konsequenzen | Auswahl bleibt stabil; mehrere baugleiche Platten ohne Seriennummer bleiben unterscheidbar |
| Risiko | Seriennummern können bei USB-Bridges fehlen oder sich ändern |

### ADR-8: Einstellungen als toleranter JSON-Blob in `UserDefaults`

| Punkt | Inhalt |
| --- | --- |
| Kontext | Wenige Einstellungen, keine externe Konfiguration nötig |
| Entscheidung | Ein JSON-Blob unter `DriveCheckMenu.settings.v1`; Dekodierung mit Defaults pro Feld |
| Konsequenzen | Einfache Persistenz, Migration durch fehlende Felder möglich |
| Risiko | Kein menschenlesbarer Export; Schemaänderungen benötigen Disziplin |

### ADR-9: AppKit-Menüleiste plus SwiftUI-Einstellungen

| Punkt | Inhalt |
| --- | --- |
| Kontext | Menüleisten-Apps benötigen präzise AppKit-Kontrolle; Formulare profitieren von SwiftUI |
| Entscheidung | `NSStatusItem`/`NSMenu` für die Menüleiste, SwiftUI-Formulare in einem `NSHostingController` für Einstellungen |
| Konsequenzen | Volle Kontrolle über Klickverhalten und Menüaufbau, moderne Formulare |
| Risiko | Zwei UI-Welten; Zustandsbrücke über `ObservableObject` nötig |

### ADR-10: Eigener Bundle-Bau statt Xcode-Projekt

| Punkt | Inhalt |
| --- | --- |
| Kontext | Das Projekt soll schlank und skriptbar bleiben |
| Entscheidung | SwiftPM baut das Binary; ein Shell-Skript erzeugt `DriveCheckMenu.app` und signiert |
| Konsequenzen | Reproduzierbarer Build ohne Xcode-Projektdatei; `make`-Ziele als Fassade |
| Risiko | Bundle-Metadaten, Icon und Signierung müssen manuell gepflegt werden |

---

## 10. Qualitätsanforderungen

### 10.1 Qualitätsbaum

```text
Qualität
  |
  +-- Korrektheit
  |     +-- SMART-Bewertung inkl. Schwellwerte und Exit-Codes
  |     +-- RAID-Bewertung inkl. Mitglieder und Rebuild
  |     +-- Belegung inkl. APFS-Dedupe und Fallback
  |
  +-- Effizienz
  |     +-- kein zusätzlicher Prozess für die Belegung
  |     +-- kein Dateisystem-Scan, kein `du`
  |     +-- Scan außerhalb des UI-Threads
  |
  +-- Robustheit
  |     +-- Fallbacks bei fehlendem smartctl/Rechten
  |     +-- Timeouts für alle Prozesse
  |     +-- Platzhalter für nicht verbundene Geräte
  |
  +-- Benutzbarkeit
  |     +-- deutsche Oberfläche, klare Statusfarben
  |     +-- Begründungen im Menü
  |     +-- Menüleisten-Freigabehilfe unter macOS 26+
  |
  +-- Wartbarkeit
        +-- Core/UI-Trennung
        +-- Fixtures und Unit-Tests
        +-- dokumentierte Architekturentscheidungen
```

### 10.2 Qualitätsszenarien

| ID | Szenario | Erwartetes Verhalten | Prüfung |
| --- | --- | --- | --- |
| Q1 | `smartctl` ist nicht installiert | App läuft weiter, zeigt Basisstatus, keine detaillierten Werte | Manuell, Code-Pfad `diskutilFallback` |
| Q2 | Laufwerk ist im Standby | Warnung, keine blockierende Abfrage | Unit-Test `testStandbyIsWarning` |
| Q3 | RAID ist degradiert | Problem mit Begründung, rotes Symbol | Unit-Test `testDegradedRaidIsProblem` |
| Q4 | RAID rebuildet | Warnung mit Fortschritt | Unit-Test `testRebuildIsWarning` |
| Q5 | APFS-Container mit mehreren Volumes | Belegung wird nur einmal gezählt | Unit-Test `testStorageUsageMappingFromDiskutilList` |
| Q6 | Container gemountet, aber nicht messbar | Plist-Fallback liefert Belegung | Unit-Test `testStorageUsageFallsBackToCapacityInUse` |
| Q7 | HFS+/exFAT-Partition | Belegung wird dem Whole Disk zugeordnet | Unit-Test `testStorageUsagePlainFilesystem` |
| Q8 | Unformatierte Platte | Keine Belegungszeile, kein Fehler | Code-Pfad `usage == nil` |
| Q9 | 500 GB Platte mit 250 GB belegt | Anzeige „Belegt: … (50 %)“ ohne Dezimalpunkt | Unit-Test `testStorageUsageFormattingAndRebasing` |
| Q10 | Benutzer ändert das Intervall | Timer wird neu geplant, sofortiger Scan | Manuell/Codepfad `MonitorService.update` |
| Q11 | Benutzer steckt Laufwerk um | Auswahl bleibt über Seriennummer erhalten | Unit-Test `testSelectionMatcherUsesSerialAndModelFallback` |
| Q12 | App wird ohne Bundle gestartet | `--dump` funktioniert, Benachrichtigungen/Login deaktiviert | Manuell |
| Q13 | Menüleistensymbol bleibt unsichtbar | Hinweis und Link zu den Systemeinstellungen | Manuell unter macOS 26+ |
| Q14 | SMART-Kurztest ohne Rechte | Angebot „Mit Administratorrechten starten …“ | Manuell/Codepfad |
| Q15 | Prozess hängt | Timeout beendet ihn, Snapshot bleibt gültig | Code-Pfad `Shell.run` |

### 10.3 Messbare Kriterien

| Kriterium | Ziel/aktuelle Ausprägung |
| --- | --- |
| Zusätzliche Prozesse für Belegung | 0 |
| Zusätzliche Syscalls für Belegung | 2 `getfsstat` (Anzahl + Daten, plus reine Berechnung) |
| Dateisystem-Scan für Belegung | keiner |
| UI-Blockierung durch Scan | keiner, Scan läuft detached |
| Testabdeckung der Parser/Bewertung | 23 Unit-Tests, 0 Fehler |
| Externe Laufzeitabhängigkeiten | nur optionale Systemtools |
| Netzwerkzugriffe | keine |

---

## 11. Risiken und technische Schulden

### 11.1 Risiken

| Risiko | Auswirkung | Wahrscheinlichkeit | Gegenmaßnahme |
| --- | --- | --- | --- |
| `smartctl` fehlt oder liefert keine Daten | Nur Basisstatus, weniger Details | Mittel | Fallback, klare UI-Hinweise, eigener Pfad konfigurierbar |
| Rechte für SMART/Kurztest fehlen | Warnung statt Details; Test nur mit Admin | Mittel | Einmaliger `osascript`-Dialog, keine Dauerkonfiguration |
| USB-Bridges liefern falsche/fehlende SMART-Daten | Falsche oder keine Bewertung | Mittel | Gerätetyp-Fallbacks, Herstellerhinweise, Nutzerprüfung |
| macOS ändert Menüleistenverhalten | App scheint unsichtbar | Hoch bei neuen Major-Versionen | Sichtbarkeitsprüfung, Hinweisdialog, Einstellungen-Link |
| Ad-hoc-Signatur und Login-Start | Registrierung schlägt fehl oder Freigabe nötig | Mittel | Bevorzugte Apple-Development-Signatur, Statusanzeige, Hinweis auf `/Applications` |
| Formatänderungen bei `diskutil`/`smartctl` | Parser liefert keine Werte | Mittel | Defensive Parsers, Fixtures, Fallbacks |
| Prozessstart pro Laufwerk kostet Zeit | Scan kann bei vielen Laufwerken dauern | Mittel | Hintergrund-Task, Scan-Sperre, Timeouts; Belegung selbst kostet keinen Prozess |
| APFS-/RAID-Semantik wird falsch interpretiert | Belegung wirkt unerwartet | Niedrig–Mittel | Dedupe, Rebasing, dokumentierte Invarianten |
| App läuft nicht dauerhaft | Keine Überwachung ohne laufende App | Hoch | Login-Start, klare Dokumentation |
| Keine Notarisierung/Sandbox | Verteilung eingeschränkt | Mittel | Für Eigenbetrieb dokumentiert; Signatur/Gatekeeper beachten |
| Vibe-Code-Qualität | Unentdeckte Randfälle | Mittel | Tests, manuelle Live-Prüfung, iterative Härtung |

### 11.2 Technische Schulden

- UI-Texte sind hartkodiert; keine Lokalisierungsdateien.
- Es gibt kein CI und keine automatisierten Hardwaretests.
- Der Scan startet pro Whole Disk ein `diskutil info` und pro Laufwerk bis zu drei
  `smartctl`-Prozesse; das ist funktional, aber optimierbar.
- Der `--smoke`-Test prüft den UI-Aufbau, nicht die Interaktion.
- Fehlende Notarisierung und fehlendes Sandboxing sind für den Eigenbetrieb bewusst
  akzeptiert.
- Das RAID-Parsing nutzt zusätzlich die Textausgabe für den Rebuild-Fortschritt, weil die
  Plist nicht in allen macOS-Versionen numerische Werte liefert.
- Die Anzeige der Belegung folgt der Dateisystem-Semantik; sie ist kein Ersatz für eine
  kapazitätsplanerische Analyse (Snapshots, Reserven, Overhead).
- Die Dokumentation muss bei künftigen Schema- oder UI-Änderungen manuell nachgeführt
  werden.

---

## 12. Glossar

| Begriff | Bedeutung |
| --- | --- |
| AppleRAID | Von macOS über `diskutil appleRAID` verwaltete Software-RAID-Verbünde |
| APFS | Apple File System; Container mit mehreren Volumes, die Speicherplatz teilen |
| APFS-Container | Gruppierung von APFS-Volumes mit gemeinsamem Speicherpool |
| BSD-Name | Gerätekennung im Kernel, z. B. `disk0`, `disk4s2` |
| Whole Disk | Gesamte physische oder virtuelle Platte ohne Partition, z. B. `disk8` |
| Partition | Unterteilung einer Whole Disk, z. B. `disk4s2` |
| Volume | Einhängbares Dateisystem; bei APFS Teil eines Containers |
| Mount | Einhängepunkt eines Dateisystems im Verzeichnisbaum |
| `getfsstat` | BSD-Syscall, der die eingehängten Dateisysteme liefert |
| `statfs` | C-Struktur bzw. Syscall mit Block- und Freiinformationen eines Dateisystems |
| `MNT_NOWAIT` | Flag, das keine Aktualisierung durch Platten-I/O erzwingt |
| SMART | Self-Monitoring, Analysis and Reporting Technology für Massenspeicher |
| `smartctl` | Werkzeug aus smartmontools zum Auslesen von SMART-Daten |
| `diskutil` | macOS-Systemwerkzeug für Datenträger, Partitionen und AppleRAID |
| Prefailure-Attribut | SMART-Attribut, dessen Unterschreiten einen bevorstehenden Ausfall anzeigt |
| Schwebender Sektor | Sektor, der nicht gelesen werden konnte und auf Wiederzuweisung wartet |
| Reallocated Sector | Bereits durch einen Ersatzsektor ersetzter Sektor |
| Medienfehler | Vom Laufwerk gemeldeter Fehler beim Lesen/Schreiben von Medien |
| Reserve (Available Spare) | Für SSD-Ersatzblöcke reservierter Anteil |
| Verschleiß (`percentage_used`) | Vom Laufwerk gemeldeter verbrauchter Lebensdaueranteil |
| Rebuild | Wiederherstellung eines RAID-Mitglieds nach Ausfall/Austausch |
| Degraded | RAID-Zustand mit eingeschränkter Redundanz |
| Standby | Laufwerkszustand mit ruhenden Platten; SMART oft nicht abfragbar |
| `HealthLevel` | Bewertungsstufe `ok`, `unknown`, `warning`, `problem` |
| `DriveStatus` | Bewerteter Zustand eines Laufwerks inklusive SMART, Belegung und Gründen |
| `RaidStatus` | Bewerteter Zustand eines RAID-Sets inklusive Belegung und Gründen |
| `StorageUsage` | Belegte und gesamte Bytes eines Dateisystems/Volume-Gruppe plus Prozentwert |
| `MonitorSnapshot` | Unveränderliches Ergebnis eines Scans mit Laufwerken, RAIDs und Gesamtstatus |
| `StableID` | Stabile Laufwerkskennung über Seriennummer oder Modell + Größe |
| Accessory-App | App ohne Dock-Symbol, die nur in der Menüleiste lebt (`LSUIElement`) |
| `SMAppService` | macOS-API zur Registrierung von Login-Items |
| `UNUserNotificationCenter` | macOS-API für lokale Benachrichtigungen |
| `UserDefaults` | Lokaler Einstellungsspeicher von macOS |
| `LSUIElement` | Info.plist-Schlüssel für Menüleisten-Apps ohne Dock-Symbol |
| Codesign | Signaturwerkzeug für macOS-Bundles |
| Ad-hoc-Signatur | Lokale Signatur ohne Entwickleridentität |
| Universal Binary | Binärdatei mit Code für Apple Silicon und Intel |

---

## Anhang: Quellcodeorientierung

| Thema | Einstiegspunkt |
| --- | --- |
| Gesamtscan | `Sources/DriveCheckMenuCore/StatusCollector.swift` |
| Belegung | `Sources/DriveCheckMenuCore/StorageUsageProbe.swift`, `StorageUsage` in `Models.swift` |
| Inventar und IDs | `Sources/DriveCheckMenuCore/DiskInventory.swift` |
| SMART | `Sources/DriveCheckMenuCore/SmartctlProbe.swift` |
| RAID | `Sources/DriveCheckMenuCore/RaidProbe.swift` |
| Bewertung | `Sources/DriveCheckMenuCore/HealthEvaluator.swift` |
| Einstellungen | `Sources/DriveCheckMenuCore/AppSettings.swift`, `SettingsStore.swift` |
| Timer/Scan | `Sources/DriveCheckMenuCore/MonitorService.swift` |
| UI-Zustand | `Sources/DriveCheckMenuCore/AppState.swift` |
| Menü | `Sources/DriveCheckMenu/StatusMenuBuilder.swift` |
| StatusItem | `Sources/DriveCheckMenu/StatusItemController.swift` |
| Einstellungen-UI | `Sources/DriveCheckMenu/SettingsView.swift` und `*SettingsView.swift` |
| Diagnose | `Sources/DriveCheckMenu/main.swift` |
| Tests | `Tests/DriveCheckMenuTests/DriveCheckMenuTests.swift`, `Tests/DriveCheckMenuTests/Fixtures/` |
