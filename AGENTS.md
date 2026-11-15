# AGENTS.md

## Projekt

- Native macOS-Menüleisten-App (macOS 14+, `LSUIElement`) zur Überwachung von SMART-Status, AppleRAID und Speicherbelegung.
- SwiftPM-Projekt ohne Xcode-Projekt: Swift-6-Compiler im Swift-5-Sprachmodus; AppKit-Menüleiste, SwiftUI-Einstellungen.
- Zwei Targets: `DriveCheckMenuCore` (testbare Fachlogik, keine AppKit-Abhängigkeit) und `DriveCheckMenu` (Executable/UI). Tests hängen nur vom Core ab.
- Vor Änderungen an der Architektur `docs/arc42.md` lesen; für Benutzerverhalten und Grenzen `README.md`.

## Befehle

```sh
make test          # swift test
swift test --filter DriveCheckMenuTests.testWholeDiskIdentifier   # einzelner Test
make app           # baut build/DriveCheckMenu.app
make run           # baut und startet das Bundle
make universal     # Universal Binary (arm64 + x86_64)
make icon          # erzeugt Resources/AppIcon.icns neu
make clean         # entfernt .build, build und generierte Icons
```

- `swift build` erzeugt nur das Binary, kein vollständiges `.app`-Bundle. Login-Start, Benachrichtigungen und Menüleistenverhalten daher immer über `make app` bzw. `make run` prüfen.
- `make install` schreibt nach `/Applications`; nur auf ausdrücklichen Wunsch ausführen.
- Es gibt kein Lint-, Format- oder CI-Setup. Verifikation ist `make test`, bei UI-/Bundle-Änderungen zusätzlich `make app` und `--dump`/`--smoke`.
- Diagnose nach `make app`:
  ```sh
  ./build/DriveCheckMenu.app/Contents/MacOS/DriveCheckMenu --dump
  ./build/DriveCheckMenu.app/Contents/MacOS/DriveCheckMenu --smoke
  ```
  `--smoke` prüft nur UI-Aufbau und Menüzustand, keine Interaktion.
- Fehlerfälle simulieren: `--simulate=failing|degraded|missing` oder `DCM_SIMULATE=...`. Die Simulation überschreibt nur die Anzeige.

## Architektur-Einstiegspunkte

- Ein Scan: `Sources/DriveCheckMenuCore/StatusCollector.swift` orchestriert Inventar, SMART, RAID, Belegung und Bewertung zu einem `MonitorSnapshot`.
- Zeitsteuerung: `MonitorService` (Timer, Scan-Sperre, Hintergrund-Task); UI-Zustand: `AppState` (`@MainActor`).
- Probes: `DiskInventory`, `SmartctlProbe`, `RaidProbe`, `StorageUsageProbe`. `Shell.run` ist die einzige Prozessausführung und kapselt Timeouts/PATH.
- Menü: `StatusMenuBuilder`; StatusItem/Icon: `StatusItemController`; Einstellungen: `SettingsView` und `*SettingsView.swift`.
- Der Scan läuft detached mit `.utility`; UI liest ausschließlich den veröffentlichten Snapshot. Core bleibt frei von AppKit/SwiftUI (enthält aber `AppState`, `LoginItem` via ServiceManagement und `Notifier` via UserNotifications).

## Repo-spezifische Constraints

- **Keine dauerhaften Root-Rechte.** Kein sudo-/Helper-/Daemon-Konstrukt ergänzen. Adminrechte nur über den bestehenden einmaligen `osascript`-Flow des SMART-Kurztests.
- **Belegung bleibt billig.** `StorageUsageProbe` nutzt die vorhandene `diskutil list -plist`-Hierarchie und `getfsstat` (`MNT_NOWAIT`). Kein `df`/`du`, keinen zusätzlichen Prozess und keinen Dateisystem-Scan einführen.
- **APFS-Semantik beachten.** Container nur einmal zählen (alle Volumes melden containerweite Werte), mehrere Container auf einer Platte addieren; ohne eingehängtes Dateisystem keine Belegungszeile. Fallback auf `CapacityInUse` nur für eingehängte, nicht messbare Container.
- **Prozentanzeige.** Belegung wird auf die angezeigte Gerätegröße rebasiert und ganzzahlig mit `%.0f %%` formatiert, damit sie zur „Größe“-Zeile und zur deutschen UI passt.
- **Stabile Identität.** Laufwerke über `serial:...`, ersatzweise Modell + Größe identifizieren; BSD-Namen sind nicht persistent. `SelectionMatcher` und Duplikatbehandlung nicht ohne Tests ändern.
- **Fallbacks erhalten.** `smartctl` ist optional; ohne Tool/Rechte/verwertbare Daten muss der `diskutil`-Basisstatus greifen. Parser defensiv halten, da Ausgaben je nach macOS/Hardware variieren.
- **Einstellungen abwärtskompatibel.** JSON-Blob unter `DriveCheckMenu.settings.v1` in `UserDefaults`; neue Felder mit Default via `decodeIfPresent` dekodieren.
- **Sprache.** Benutzeroberfläche und Dokumentation auf Deutsch; Code-Kommentare überwiegend englisch.
- **macOS 26+ Menüleiste.** Ein erzeugtes `NSStatusItem` kann unsichtbar sein, obwohl es existiert. Die bestehende Sichtbarkeitsprüfung und den Hinweis auf „Systemeinstellungen → Menüleiste“ beibehalten; nicht mit `defaults`-/`killall`-Hacks „reparieren“.
- **Doku-Workflow.** `README.md` und `docs/arc42.md` nur auf ausdrücklichen Wunsch ändern.

## Tests und Fixtures

- Fixtures liegen unter `Tests/DriveCheckMenuTests/Fixtures/` und sind echte, mitgeschnittene `diskutil`-/`smartctl`-Ausgaben.
- Parser-/Bewertungsänderungen mit einem passenden Fixture-Test absichern; keine echten Laufwerke in Unit-Tests voraussetzen.
- Nach Core-Änderungen `make test`; nach UI-/Menü-/StatusItem-Änderungen zusätzlich `make app`, `--dump` und `--smoke`.

## Nicht anfassen / generiert

- `build/`, `.build/`, `.swiftpm/` sowie `Resources/AppIcon.iconset/` und `Resources/AppIcon.icns` sind Build-Artefakte (siehe `.gitignore`).
- Das App-Icon wird aus `scripts/make-icns.swift` erzeugt; nicht manuell bearbeiten.
- Das Projekt nutzt bewusst SwiftPM ohne Xcode-Projekt; nicht nebenbei eines anlegen. Bundle-Erzeugung und Signierung laufen über `scripts/build-app.sh` (Apple-Development-Identität, sonst Ad-hoc).
