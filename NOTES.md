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
    nicht smart schaltbar** → `d_pool_wp` im Modul ist derzeit praktisch ein
    Dummy (`heatpumpState` = Absicht, nicht Realität).
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

## Offene To-dos / geparkt

1. **WP ins Smart Home** (statt Zeitschaltuhr). Danach: **WP-Heizbedarf-Gate** –
   WP/Filter aus, sobald kein Heizbedarf (Pool ≥ Soll). Aktuell bewusst NICHT
   gebaut, weil das Modul die WP noch nicht echt schaltet (würde nur den Filter
   gegen die timer-gesteuerte WP abschalten).
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

## PR-Historie (Feature-Branch `claude/optimistic-ramanujan-ew7wjc`)

- #1 Modul-Grundgerüst · #2 Solar-Zeitfenster/`solarEnable` · #3 Index-Hysterese
- #4 Attribut-Hilfe + Handbetrieb (`mode`) + Umrühren-Soll-Gate + Filter/Solar-Entkopplung
- #5 Readings in der commandref · #6 WP-Regelband (`heatpumpRegBand`)
- #7 zeitabhängige Solltemperatur (`targetTempSchedule`)
