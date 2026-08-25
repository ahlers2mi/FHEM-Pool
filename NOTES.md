# PoolControl – Projektnotizen, Tuning & offene Punkte

Arbeitsnotizen zur Pool-Steuerung (`FHEM/98_PoolControl.pm`). Hält Kontext fest,
der **nicht** im Code/README steht: Anlagen-Physik, aktueller Tuning-Stand,
getroffene Entscheidungen und geparkte To-dos. Stand: 2026-06-26, Modul v0.10.0.

## Anlage / Physik (wichtig fürs Verständnis der Logik)

- **Solarthermie:** großer Temperaturhub nur bei **langsamer Strömung** (~3 °C);
  läuft die Filterpumpe mit, bricht der Hub auf ~0,1–0,4 °C ein. Daher eigener,
  langsamer Solarkreis, Filter dabei **aus**. Solar heizt **uncapped** (kein
  oberes Limit wie die WP).
- **Wärmepumpe (Inverter):** läuft auf Filtergeschwindigkeit, Hub ~0,8 °C, ~3 min
  Anlaufzeit. Regelt zwischen Sollwert und Sollwert + ~0,5 °C ab.
  - **Heizt nur bei Durchfluss → die Filterpumpe ist faktisch der WP-Schalter.**
  - **Aktuell auf Zeitschaltuhr**, physisch auf 31 °C (max ~31,5 °C), **noch
    nicht fernsteuerbar** (Stand 08/2026 bestätigt) → `d_pool_wp` im Modul ist
    praktisch ein Dummy (`heatpumpState` = Absicht, nicht Realität).
  - Dafür gibt es seit v0.12.0 `heatpumpReadOnly 1`: das Modul schaltet den
    Dummy dann nicht mehr, sondern liest ihn nur. So kann der Dummy von Hand
    (oder später per Zeitschaltuhr-Abbild) die Realität spiegeln, und das Modul
    kann daraus Konsequenzen ziehen – z. B. bei `heating off` die Filterung
    aussetzen, damit der Durchfluss nicht heizt.
- **Kuppel/Abdeckung:** heizt den Pool passiv per Sonne nach (bis ~34,8 °C
  beobachtet). Das Modul kann **nicht kühlen** – Überschuss lässt sich nur durch
  *weniger Zuheizen* begrenzen (→ `targetTempSchedule`).
- **inflowSensor** sitzt im Strömungsknick; bei **Stillstand** zeigt er die
  sonnenbeschienene Schwarzrohr-Temperatur (Artefakt!). Beispiel 25.06.: Ruhe
  36 °C, bei Durchfluss real **27 °C**. → **Als Solar-Potenzialsignal
  unbrauchbar.** Verlässlich nur mit echtem Kollektorfühler.

## Tuning-Stand (Live-Config, ca. 26.06.2026)

> Live-Werte stehen in der laufenden FHEM-Instanz, **nicht** im Repo. Hier nur als Gedächtnisstütze.

| Parameter | Wert | Anmerkung |
|-----------|------|-----------|
| `targetTemp` (desiredTemperature) | ~30–33 | ggf. durch `targetTempSchedule` ersetzt |
| `targetTempSchedule` | optional `00:00 32 16:00 33.5` | tagsüber 32, abends 33,5 |
| `heatpumpTemp` | 31–32 | echte WP steht auf 31 (max ~31,5) |
| `filterHours` | 5–6 | |
| `solarStartTime` / `solarEndTime` | 11:00 / 20:30 | 11:00 ist eher zu früh (kalte Fehlstarts, s. u.) |
| `heatpumpOffset` | 0.9 | voller WP-Hub |
| `heatpumpRegBand` | 0.5 | WP-Eigenregelung über Sollwert |
| `heatpumpRampTime` | 180 | WP-Anlauf, Auskühlschutz ausgesetzt |
| `solarHysteresis` / `solarHysteresisFilter` | 0.5 / 0.1 | Filter aus / Filter an |
| `solarIndexOn` / `solarIndexOff` | 8 / 3 | breite Hysterese, s. To-do |

## Getroffene Entscheidungen (warum das Modul so ist)

- **Filter läuft NICHT für Solar** (eigener langsamer Kreis); Solar-Laufzeit
  zählt **nicht** aufs Filtersoll.
- **WP und Solar arbeiten zusammen** (beide sonnengesteuert) – keine gegenseitige
  Sperre. Bei WP-Betrieb läuft der Filter mit.
- **Flussabhängiger Auskühlschutz:** geforderter Solarhub = `solarHysteresis`
  (Filter aus) bzw. `solarHysteresisFilter` (Filter an). `circulationLoss`
  wurde dadurch ersetzt/entfernt.
- **`heatpumpEffective` = erwartete Einlauftemperatur** der WP
  = `min(poolTemp + heatpumpOffset, heatpumpTemp + heatpumpRegBand)` – **nicht**
  „Soll + Offset". Während WP-Anlauf wird der Auskühlschutz ausgesetzt.
- **`targetTempSchedule`** überschreibt `desiredTemperature` zeitabhängig
  (greift sofort für Solar; für WP voll wirksam, sobald sie smart schaltbar ist).
  Ein manuelles `set targetTemp` gilt bei aktivem Zeitplan als **Override bis zum
  nächsten Zeitplan-Punkt** (`.targetHoldSlot` = Slot beim Setzen).
- **Persistenz der Sollwerte:** `filterHours` und `heatpumpTemp` sind **Attribute**
  (in der `fhem.cfg`, mit `autosave` sofort persistent) → überleben Neustarts
  zuverlässig. `set`-Readings brauchten dagegen ein `save` und gingen bei
  Neustart ohne save auf die Modul-Defaults zurück (28/5) – genau das Problem.
  `control`/`mode`/`filter`/`targetTemp` bleiben Readings (Reset auf sichere
  Defaults ist hier gewollt).
- **Manueller Filter-Override** `set filter on|off|auto`: Vorrang nach
  mode-force; wird beim Beginn des Nachtfensters einmalig auf `auto` zurück-
  gesetzt, damit die Nachtfilterung läuft. Der Zustand liegt im Reading
  **`filter`** (nicht mehr `filterManual`, v0.11.3) – gleicher Name wie der
  set-Befehl, damit ein Default-`webCmd filter` den aktuellen Wert findet
  (sonst zeigte das Dropdown mangels Reading `filter` immer „on"). Migration
  in `PoolControl_migrate` übernimmt den alten `filterManual`-Wert einmalig.
- **Tag-Filterung verteilt:** bewusst NICHT gebaut – Nachtfilterung ist gewollt
  (fängt Tagesschmutz, leise, minimaler Wärmeverlust).

## Offene To-dos / geparkt

1. **WP ins Smart Home** (statt Zeitschaltuhr) – dann schaltet das Modul die WP
   wirklich (heute `d_pool_wp` = Dummy, WP an Zeitschaltuhr).
   - ✅ **WP-Heizbedarf-Gate** ist gebaut (v0.10.1, PR #8): WP wird nur
     freigegeben bei Heizbedarf **und** Pool < `heatpumpTemp`; sonst bleibt mit
     der WP auch der Filter aus. Sicher, weil die WP nur mit Durchfluss heizt.
2. **Eigener (Funk-)Kollektorfühler** (Kollektor liegt weit weg, kein Strom →
   batterie-/funkbasiert). Einhängbar als `solarEnable` (numerisch +
   `solarEnableMin`) oder künftiges Attribut `collectorSensor`. Ermöglicht
   verlässliche Solar-Steuerung bzw. „Solar alleine bei heißem Kollektor".
3. **Solar-Idee des Nutzers** („something else") noch zu konkretisieren –
   basiert sinnvollerweise auf dem echten Kollektorfühler (#2), nicht auf der
   Ruhe-`inflowTemp`.
4. **Index-Hysterese 8/3** ggf. enger (`solarIndexOn` senken) – verursachte am
   24.06. ~1 h Heizpause, weil der Index nach kurzem Einbruch erst wieder 8
   erreichen musste.

### Ideen (bewusst zurückgestellt – Modul nicht verkomplizieren)

- **Nachtkühlung über die Solarthermie:** Bei zu warmem Pool nachts die
  Solarpumpe laufen lassen → der Kollektor strahlt Wärme an den kühlen
  Nachthimmel ab (Umkehrung des Heizfalls). Der jetzige Auskühlschutz
  *verhindert* das bewusst (schaltet ab, wenn Einlauf < Pool); bräuchte also
  einen eigenen „Kühlmodus" mit umgekehrter Logik + oberer Solltemperatur-
  Schwelle. (Idee vom 28.06., als der Pool passiv auf ~35 °C kam.)
- **Filterquote auch tagsüber verteilen:** An heißen Tagen ohne Heizbedarf läuft
  der Filter fast nur nachts (Nachfüllung der Tagesstunden im Block). Optional:
  die Filterstunden über den Tag verteilen (z. B. wenn tagsüber jemand
  schwimmt), statt sie nur über Heizbetrieb + Nachtfenster abzudecken.

## Log-Beobachtungen

- **24.06.:** WP-Heizen ok; ~1 h WP-Pause durch Index-Hysterese (Index fiel auf
  3, brauchte wieder 8); Nachmittag durch 31°-Fehlkonfig (`heatpumpTemp` im
  Modul 32 statt real 31) verfälscht.
- **25.06.:** einziger echter Solar-Alleinlauf um 11:00 → Rücklauf **27 °C**
  (5 °C kälter als Pool) → Auskühlschutz korrekt → **bestätigt das
  Schwarzrohr-Artefakt** des inflowSensors. 11:00 ist als Solarstart zu früh.
- **26.06.:** Pool warm (≥ Soll), `heatpumpState on` trotz `heatingNeeded no`
  (fehlendes WP-Gate). Harmlos, da WP bei ~31,5 °C kappt und die Filterzeit eh
  aufs Tagessoll zählt.
- **27.06. ~11:54:** v0.10.2 live (`heatpumpTemp` real auf 31 gesetzt). WP-Gate
  greift sichtbar: Pool 32,8 > Soll 32 → WP **und** Filter aus (`Filter off
  (kein Bedarf)`), `lastDecision: WP aus: Soll erreicht`. Pool-Max ~35,2 °C.
- **28.06.:** sehr warm, Pool durchgehend ≥ Soll → weder WP noch Solar heizen
  (alles passiv über Sonne/Kuppel, Max ~33–35 °C). Filter lief tagsüber kaum
  (Heizbetrieb fehlt) → Tagesquote landet im Nachtfenster. Steuerung korrekt.

## PR-Historie (Feature-Branch `claude/optimistic-ramanujan-ew7wjc`)

- #1 Modul-Grundgerüst · #2 Solar-Zeitfenster/`solarEnable` · #3 Index-Hysterese
- #4 Attribut-Hilfe + Handbetrieb (`mode`) + Umrühren-Soll-Gate + Filter/Solar-Entkopplung
- #5 Readings in der commandref · #6 WP-Regelband (`heatpumpRegBand`)
- #7 zeitabhängige Solltemperatur (`targetTempSchedule`)
- #8 NOTES.md + WP-Heizbedarf-Gate (WP/Filter aus, wenn Pool warm genug)
- #9 NOTES: Ideen (Nachtkühlung, Tag-Filterung) + Log 27./28.06.
- dazwischen: `set solarCheck` (erzwungene Solar-Neuprüfung), v0.10.3
- v0.11.0: `filterHours`/`heatpumpTemp` als **Attribute** (persistent) +
  manueller Filter-Override `set filter on|off|auto` (nachts Reset)
- v0.11.1: `set solarCheck` übergeht jetzt zusätzlich das **Solarfenster**
  (Zeitfenster `solarStartTime`/`solarEndTime` + Freigabe `solarEnable`) –
  der erzwungene Check läuft also auch **ausserhalb des Solarfensters**.
  Umgesetzt über ein klebriges Flag `.solarForceCheck`, das die folgenden
  Automatik-Zyklen überdauert (sonst würde der nächste Tick vor Ablauf der
  `solarSettleTime` wieder auf `off (ausserhalb Solarfenster)` schalten) und
  erst bei echter Abschaltung (Auskühlschutz / Soll erreicht / forceOff)
  gelöscht wird. Heizbedarf gilt weiterhin.
- v0.11.2: **Kaltstart-Verlängerung der Prüfphase.** Lief die Solarpumpe seit
  mindestens `solarColdStartAfter` (Default 14400 s = 4 h) nicht mehr, ist der
  Solarkreis ausgekühlt; der erste Anlaufversuch danach läuft um
  `solarColdStartExtra` (Default 180 s = 3 min) länger, bevor der Auskühlschutz
  bewertet – warmes Wasser aus dem ausgekühlten Kreis braucht länger bis zum
  `inflowSensor` (Schwarzrohr-Artefakt, s. Physik-Abschnitt). Umgesetzt über
  `.solarLastRunTime` (Zeitstempel des letzten Solarbetriebs) und
  `.solarSettleBonus` (bei jedem echten Anlaufversuch neu bestimmt: `coldExtra`
  bei Idle ≥ `coldAfter`, sonst 0). `solarColdStartExtra 0` deaktiviert.
- v0.12.0: **Saisonbetrieb „filtern ohne heizen"** (`attr`/`set heating on|off`)
  + Umrühr-Gate. Anlass: im Herbst wird die Solltemperatur nie erreicht, der
  Nutzer hatte das Soll deshalb auf 5 °C gestellt – für das Modul heißt das
  „Soll erreicht" und löste damit gerade das **Umrühren** aus (stündlich, rund
  um die Uhr). Weil die WP an der Zeitschaltuhr hängt, **heizte** der dabei
  erzeugte Durchfluss den Pool sogar.
  - `heating off`: Solar + WP aus, kein Umrühren, Filter erfüllt weiter sein
    Tagessoll. Als **Attribut** (persistent) – ein Reset auf „heizen" wäre im
    Herbst genau falsch; als Reading gespiegelt (Dashboard/`webCmd`).
  - **Umrühren nur, wenn seit dem letzten Mix wirklich eine Wärmequelle lief**
    (`.heatSinceMix`, gesetzt bei `solarHeating`/`wpActive`, beim Mixstart
    verbraucht). Vorher genügte „kein Heizbedarf" – das mischte auch dann, wenn
    gar nicht geheizt wird. Sommerverhalten bleibt: Solar heizt → Soll erreicht
    → mischen → Temperatur fällt → Solar heizt wieder.
  - `heatpumpReadOnly 1`: Modul beobachtet die WP nur, schaltet sie nie (WP an
    Zeitschaltuhr, **noch nicht fernsteuerbar**). Sonst überschreibt das Modul
    den von Hand gepflegten Dummy sofort wieder.
  - `heating off` + WP hat Strom → **Automatik-Filterung aus**, damit der
    Durchfluss nicht heizt. „Hat Strom" = WP meldet `on`
    (`filterReason: aus: WP an, soll nicht heizen`) **oder** – nur mit
    `heatpumpReadOnly 1` – die Zeit liegt im Fenster
    `wpStartTime`–`wpEndTime` (`aus: WP-Zeitfenster, soll nicht heizen`).
    Letzteres ist der Praxisfall: bei der Zeitschaltuhr-WP beschreibt das
    Fenster deren Schaltzeit, der Schutz greift also **ohne** dass der Dummy
    von Hand gepflegt werden muss. Hand/Zwang geht vor, `lastDecision` warnt.
  - **Anlagenstand 08/2026:** Zeitschaltuhr der WP = **09:00–19:00**
    (`wpStartTime`/`wpEndTime` entsprechend gesetzt), Nachtfenster 22:00–06:00.
    Überschneidungsfrei → die Nachtfilterung erfüllt das Tagessoll komplett,
    ohne die WP je anzustoßen. Bei Änderung der Uhr die Attribute mitziehen,
    sonst greift der Schutz am falschen Zeitpunkt.
  - Falle beim Basteln: `filterReason` prüft `$wpActive` **vor** allem anderen –
    der neue „soll nicht heizen"-Grund musste vor die Quellen-Zweige, sonst
    stand dort „WP" bzw. „Nachtfilterung", obwohl der Filter aus ist.
  - Merken: **`heatpumpStateReading` ist ein Reading-Name, kein Gerät** – das
    Gerät gehört in `heatpumpSwitch`. Steht dort nichts, ignoriert das Modul die
    WP komplett (weder schalten noch lesen).
- v0.11.4: **Tageslaufzeit übersteht den Neustart.** `.runtimeSec`/`.runtimeDate`
  lagen nur in Internals – die schreibt FHEM **nicht** ins Statefile (Readings
  schon). Nach jedem Neustart begann die Zählung bei 0 → der Filter arbeitete
  das komplette Tagessoll (`filterHours`) erneut ab. Jetzt: neues Reading
  `filterRuntimeDay` (Zähltag) + `PoolControl_restoreState`, das den Stand aus
  `filterRuntimeToday` zurückholt, wenn der Zähltag passt. Läuft aus
  `PoolControl_migrate` **und** aus `PoolControl_Control` (einmalig per
  `.restoreDone`) – ein Sensor-Event kann einen Steuerlauf vor den Timer
  schieben und hätte den Zähler sonst auf 0 initialisiert.
  Zwei Folgefehler mit erledigt:
  - `RemoveInternalTimer($hash)` (ohne Funktion) in Notify/Control/Attr löschte
    **alle** Timer des Geräts – also auch die noch anstehende Migration/
    Wiederherstellung. Jetzt überall funktionsbezogen
    (`RemoveInternalTimer($hash, "PoolControl_Control")`).
  - Define plante den ersten Steuerlauf nur `if ($init_done)` – beim FHEM-Start
    ist der 0, d. h. die Steuerung startete erst mit dem ersten Sensor-Event.
    Jetzt immer (der Timer feuert ohnehin erst nach Config + Statefile).
  - `.filterByModule` ist ebenfalls flüchtig: lief der Filter vom Modul
    geschaltet und FHEM startete neu, galt die Pumpe als Fremdschaltung und
    wurde **nie mehr abgeschaltet**. Wird jetzt aus `filterState on`
    rekonstruiert.
- v0.11.3: Reading **`filterManual` → `filter` umbenannt**. Der Default-
  `webCmd filter` sucht ein gleichnamiges Reading; da es keins gab, zeigte das
  Dropdown immer „on", obwohl der Override auf `auto` stand. Jetzt schreibt
  `set filter` das Reading `filter`; `PoolControl_migrate` übernimmt den alten
  Wert einmalig und löscht `filterManual`.
