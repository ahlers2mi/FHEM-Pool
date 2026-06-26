# FHEM-Pool

FHEM-Modul **PoolControl** zur Steuerung von Poolfilterung und Poolheizung
(Solarthermie + Wärmepumpe) in einer Instanz.

---

## Inhaltsverzeichnis

- [Übersicht](#übersicht)
- [Funktionsweise](#funktionsweise)
- [Installation](#installation)
- [Define](#define)
- [Set](#set)
- [Get](#get)
- [Attribute](#attribute)
- [Readings](#readings)
- [Beispiel-Setup](#beispiel-setup)
- [Migration aus der bestehenden Automatik](#migration-aus-der-bestehenden-automatik)

---

## Übersicht

`PoolControl` bündelt die bisher über viele `notify`s und `at`-Timer verteilte
Pool-Logik in einem Gerät. Es steuert ausschließlich über frei zuordenbare
Fremdgeräte (Attribute) – es besitzt keine eigene Hardware.

Gesteuert werden:

| Funktion        | Beschreibung |
|-----------------|--------------|
| **Filterung**   | Gewünschte Filterstunden pro Tag. WP-Betrieb zählt mit (läuft auf Filtergeschwindigkeit); Solar zählt **nicht** mit (eigener Kreis). Rest wird nachts nachgefiltert. |
| **Heizung**     | Solltemperatur, geheizt über Solarthermie und Wärmepumpe – beide sonnengesteuert, arbeiten zusammen. |
| **Filter & Solar** | Solar löst keine Filterung aus. Läuft **nur** Solar (ohne WP), bleibt der Filter **aus** → langsame Strömung, großer Temperaturhub. Bei WP-Betrieb läuft der Filter mit, Solar wird dann an einer kleineren Schwelle bewertet. |
| **Auskühlschutz** | Solarpumpe wird abgeschaltet, wenn der nutzbare Solarhub die (flussabhängige) Schwelle unterschreitet; WP-Beitrag wird abgezogen, WP-Anlaufphase ausgespart. |
| **Wärmepumpe**  | Inverter-WP, regelt selbst. Modul gibt sie nur frei (Zeitfenster + ausreichender Solarindex) und teilt die Zieltemperatur mit. Bei WP-Betrieb läuft der Filter mit. |
| **Wasserqualität** | Optionaler Sensor (z. B. BLE-YC01), nur informativ, blockiert die Steuerung nicht. |

---

## Funktionsweise

### Filterung
Über `set <name> filterHours <h>` wird die gewünschte Filterzeit pro Tag
vorgegeben. Das Modul summiert die tatsächliche Filterlaufzeit (`filterRuntimeToday`).
Die Wärmepumpe läuft auf Filtergeschwindigkeit, der Filter läuft bei WP-Betrieb
also ohnehin mit und diese Zeit wird angerechnet. Die **Solarthermie zählt nicht**:
sie hat einen eigenen, langsamen Kreis und läuft bewusst **ohne** Filterpumpe
(s. u.). Fehlt am Tagesende noch Laufzeit, wird im Nachtfenster
(`filterNightStart`–`filterNightEnd`, Default 22:00–06:00) nachgefiltert, bis das
Tagessoll erreicht ist.

> Der **Filtertag** wechselt am Ende des Nachtfensters (`filterNightEnd`,
> Default 06:00) – **nicht** um Mitternacht. So wird das nächtliche Nachfiltern
> über Mitternacht hinweg demselben Tag zugerechnet und das Tagessoll
> zuverlässig erreicht.

> Der Filter wird vom Modul nur dann **ausgeschaltet**, wenn das Modul ihn auch
> selbst eingeschaltet hat – manuelle Schaltungen werden nicht überstimmt.

### Solarthermie (Auskühlschutz)
Bei Heizbedarf (`poolTemp < Soll`) wird die Solarpumpe als Anlaufversuch
eingeschaltet. Nach `solarSettleTime` (Default 180 s, deckt die ~2 min Umlaufzeit
des Solarkreises ab) wird geprüft, ob der **nutzbare Solarhub** des einlaufenden
Wassers (`inflowSensor`) die geforderte Schwelle erreicht. Tut er das nicht, wird
die Pumpe wieder abgeschaltet (Auskühlschutz) und für `solarRetryDelay`
(Default 1800 s) gesperrt.

> **Flussabhängige Schwelle:** Solar erreicht nur bei **langsamer Strömung** einen
> großen Temperaturhub; läuft die Filterpumpe mit, steigt die
> Durchflussgeschwindigkeit und der Hub bricht ein. Daher hängt die geforderte
> Mindest-Übertemperatur vom Filterzustand ab:
> - **Filter aus** (Solar-only, langsam): `solarHysteresis` (Default **0,5 °C**).
> - **Filter an** (schnelle Strömung): `solarHysteresisFilter` (Default **0,1 °C**).
>
> Solar löst selbst **keine** Filterung aus. Läuft nur Solar, bleibt der Filter
> aus (großer Hub). Die WP arbeitet unabhängig; sobald sie filtert, gilt für
> Solar automatisch die kleinere Schwelle.

> **WP-Beitrag & Anlaufphase:** Läuft die WP aktiv (Pool unter `heatpumpTemp`),
> hebt sie das Einlaufwasser um ~`heatpumpOffset` (Default **0,9 °C**); dieser
> Anteil wird abgezogen, damit nur die echte Solarwärme zählt. Die WP braucht
> aber ~3 min bis zur vollen Leistung (`heatpumpRampTime`, Default 180 s) – in
> dieser Zeit bricht das Solarwasser kurz ein, daher wird der Auskühlschutz
> währenddessen ausgesetzt.

**Wann darf Solar überhaupt anlaufen?** Da es keinen Kollektorfühler gibt, weiß
das Modul nicht von selbst, ob Wärme vom Dach kommt. Anlaufversuche lassen sich
daher optional einschränken, damit die Pumpe nachts/ohne Sonne nicht sinnlos
taktet:

- **Zeitfenster** `solarStartTime`/`solarEndTime` (leer = ganztags).
- **Externe Freigabe** `solarEnable` (`<dev>:<reading>`) – z. B. PV-Überschuss
  (`MQTT2_Sonoff_POW_01:pooltrigger`) oder Kollektor-/Heizungstemperatur
  (`mySolvis:S08.Solarkollektortemperatur`). Ist `solarEnableMin` gesetzt, wird
  das Reading numerisch ausgewertet (`>= Min`, z. B. Watt oder °C), sonst gegen
  `solarEnableRegex` (Default `on|ON|1`). Dieselbe Freigabe kann auch ein
  Wetter-Dummy sein, um bei schlechtem Wetter zu sperren.

Beide sind standardmäßig leer (kein Limit). Externe Geräte können zusätzlich per
`set <name> check` eine sofortige Neubewertung anstoßen; das Freigabe-Gerät wird
automatisch in `NOTIFYDEV` aufgenommen.

**Nutzbarer Solarhub:** Bewertet wird `inflowTemp − WP-Anteil − poolTemp` gegen
die flussabhängige Schwelle (s. o.). Der abgezogene WP-Anteil entspricht der
erwarteten WP-Einlauftemperatur über dem Pool (`heatpumpEffective − poolTemp`):

- **Pool deutlich unter `heatpumpTemp`** (WP volle Leistung): voller Hub
  `heatpumpOffset` (~0,9 °C, etwas höher als der reale ~0,8 °C). Zu niedrig
  gewählt würde Solar fälschlich als heizend gelten und die Solarpumpe liefe
  durch den kalten Kollektor weiter (Wärmeverlust).
- **Pool in Sollnähe**: die Inverter-WP regelt zwischen `heatpumpTemp` und
  `heatpumpTemp + heatpumpRegBand` (~0,5 °C) herunter. Der Beitrag schrumpft
  entsprechend – Beispiel Pool 32 °C, `heatpumpTemp` 32: die WP liefert nur noch
  ~32,5 °C, der abgezogene Anteil ist also nur ~0,5 °C statt 0,9 °C.
- **Pool am oberen Rand des Regelbands / WP aus**: kein Abzug; es zählt der reine
  Hub gegen die Schwelle (0,5 °C bei Filter aus bzw. 0,1 °C bei laufendem Filter).

### Wärmepumpe (Inverter)
Die WP ist eine Inverter-Wärmepumpe und **regelt ihre Leistung selbst**. Das
Modul gibt sie daher nur **frei** und überlässt die Temperaturregelung der WP:
- aktuelle Zeit liegt im Fenster `wpStartTime`–`wpEndTime` (Default 09:00–22:00),
- der `solarIndex` reicht aus (genug Stromüberschuss).

WP und Solar sind beide sonnengesteuert und arbeiten zusammen. Bei WP-Betrieb
läuft die Filterpumpe mit (die WP arbeitet auf Filtergeschwindigkeit); die
Solarthermie wird in diesem Fall an der kleineren Schwelle `solarHysteresisFilter`
bewertet.

**Solarindex-Hysterese:** Damit die WP an der Schwelle nicht flattert, wird sie
erst ab `solarIndexOn` freigegeben und erst bei `solarIndexOff` wieder gesperrt;
im Band dazwischen bleibt der Zustand erhalten. Beispiel `solarIndexOn 8` /
`solarIndexOff 3`: ein ab Index 8, aus erst wieder bei Index ≤ 3. Sind die beiden
Attribute nicht gesetzt, gilt der einfache Schwellwert `solarIndexMin`.

Die der WP mitgeteilte Zieltemperatur wird per `set <name> heatpumpTemp <°C>`
gesetzt und kann optional über `heatpumpTempCmd` an das WP-Gerät durchgereicht
werden. Das Reading `heatpumpEffective`
(= `min(poolTemp + heatpumpOffset, heatpumpTemp + heatpumpRegBand)`) zeigt die
erwartete Einlauftemperatur bei laufender WP – in Sollnähe durch die
Eigenregelung der WP gedeckelt. Ein Vergleich mit `inflowTemp` zeigt, ob die WP
wie erwartet liefert. Das Reading ist nur informativ; der gleiche Wert fließt
aber als WP-Anteil in den Auskühlschutz ein.

---

## Installation

### Manuell
```bash
cp FHEM/98_PoolControl.pm /opt/fhem/FHEM/
```
Danach in der FHEM-Konsole:
```
reload 98_PoolControl
```

### Über FHEM Update
```
update add https://raw.githubusercontent.com/ahlers2mi/FHEM-Pool/main/controls_Pool.txt
update
```

---

## Define

```
define <name> PoolControl
```
Alle Ein-/Ausgänge werden über Attribute zugeordnet (siehe Beispiel-Setup).

---

## Set

| Befehl                  | Beschreibung |
|-------------------------|--------------|
| `control on\|off`       | Steuerung aktivieren/deaktivieren (off = Modul fasst nichts an) |
| `mode auto\|forceOn\|forceOff` | Betriebsmodus: `forceOn` = Filter + WP zwangsweise heizen (ohne Zeitfenster/Solarindex; Solar bleibt automatisch mit Auskühlschutz), `forceOff` = Filter/Solar/WP zwangsweise aus, `auto` = zurück zur Automatik |
| `targetTemp <°C>`       | Solltemperatur des Pools (wird von `targetTempSchedule` überschrieben, falls gesetzt) |
| `filterHours <h>`       | gewünschte Filterstunden pro Tag |
| `heatpumpTemp <°C>`     | der Wärmepumpe mitgeteilte Temperatur |
| `resetRuntime`          | Tageslaufzeitzähler zurücksetzen |
| `check`                 | Steuerzyklus sofort ausführen |

---

## Get

| Befehl   | Beschreibung |
|----------|--------------|
| `config` | aktuelle Zuordnungen anzeigen |

---

## Attribute

### Sensoren (Format `<Gerät>:<Reading>`)
| Attribut           | Beschreibung |
|--------------------|--------------|
| `poolSensor`       | Pool-Wassertemperatur |
| `inflowSensor`     | Temperatur des einlaufenden Wassers |
| `solarIndexSensor` | Solarindex (verfügbarer Stromüberschuss) |
| `qualitySensor`    | optionaler Wasserqualitätssensor (nur Gerätename) |

### Filterpumpe
| Attribut             | Default     | Beschreibung |
|----------------------|-------------|--------------|
| `filterSwitch`       | –           | Gerät der Filterpumpe |
| `filterStateReading` | `state`     | Status-Reading |
| `filterOnRegex`      | `on\|ON\|1` | Regex für „an" |
| `filterOnCmd`        | `on`        | Einschaltkommando |
| `filterOffCmd`       | `off`       | Ausschaltkommando |
| `filterNightStart`   | `22:00`     | Beginn Nachtfilterung |
| `filterNightEnd`     | `06:00`     | Ende Nachtfilterung; zugleich Wechsel des Filtertags (Tageszähler-Reset) |

### Umrühren / Durchmischung
Das von der Solarthermie erwärmte Wasser sammelt sich oben im Pool. Damit sich
die Wärme verteilt (und der Pool-Sensor nicht vorzeitig „warm genug" meldet),
zirkuliert der Filter periodisch, **sobald das Soll erreicht ist** (kein
Heizbedarf mehr). Solange der Pool noch unter Soll liegt, wird **nicht** gerührt –
Zirkulieren ohne Wärmezufuhr verteilt nichts und kühlt über den Umwälzverlust
sogar leicht aus. Während ohnehin gefiltert/geheizt wird, ist kein separates
Umrühren nötig.

| Attribut       | Default | Beschreibung |
|----------------|---------|--------------|
| `mixInterval`  | `3600`  | Mindestabstand zwischen Mix-Zyklen ohne Zirkulation (s); `0` = aus |
| `mixDuration`  | `300`   | Dauer eines Mix-Zyklus (s) |

### Solarthermie
| Attribut            | Default     | Beschreibung |
|---------------------|-------------|--------------|
| `solarSwitch`       | –           | Gerät der Solarpumpe |
| `solarStateReading` | `state`     | Status-Reading |
| `solarOnRegex`      | `on\|ON\|1` | Regex für „an" |
| `solarOnCmd`        | `on`        | Einschaltkommando |
| `solarOffCmd`       | `off`       | Ausschaltkommando |
| `solarHysteresis`   | `0.5`       | geforderter Solarhub bei **Filter aus** (langsamer Kreis, °C) |
| `solarHysteresisFilter` | `0.1`   | geforderter Solarhub bei **laufendem Filter** (schnelle Strömung, °C) |
| `solarSettleTime`   | `180`       | Wartezeit nach Anlauf vor Auskühlprüfung (s; ~2 min Umlaufzeit) |
| `solarRetryDelay`   | `1800`      | Sperrzeit nach Abschaltung wegen Auskühlung (s) |
| `solarStartTime`    | – (leer)    | Beginn des Solar-Zeitfensters (HH:MM), leer = ganztags |
| `solarEndTime`      | – (leer)    | Ende des Solar-Zeitfensters (HH:MM), leer = ganztags |
| `solarEnable`       | – (leer)    | externe Freigabe `<dev>:<reading>` (PV-Überschuss, Kollektortemp., Wetter) |
| `solarEnableMin`    | – (leer)    | Mindestwert für numerische Freigabe; leer = Regex-Auswertung |
| `solarEnableRegex`  | `on\|ON\|1` | Regex für boolsche Freigabe (wenn kein `solarEnableMin`) |

### Wärmepumpe
| Attribut               | Default     | Beschreibung |
|------------------------|-------------|--------------|
| `heatpumpSwitch`       | –           | Gerät der Wärmepumpe |
| `heatpumpStateReading` | `state`     | Status-Reading |
| `heatpumpOnRegex`      | `on\|ON\|1` | Regex für „an" |
| `heatpumpOnCmd`        | `on`        | Einschaltkommando |
| `heatpumpOffCmd`       | `off`       | Ausschaltkommando |
| `heatpumpOffset`       | `0.9`       | voller Temperaturhub der WP über der Pooltemperatur (~0,8 °C real, etwas höher wählen); im Auskühlschutz abgezogen, bestimmt `heatpumpEffective` |
| `heatpumpRegBand`      | `0.5`       | Regelband der Inverter-WP über `heatpumpTemp`; deckelt `heatpumpEffective` in Sollnähe (`min(poolTemp + offset, heatpumpTemp + regBand)`) |
| `heatpumpRampTime`     | `180`       | Anlaufzeit der WP bis volle Leistung (s); währenddessen Auskühlschutz ausgesetzt |
| `heatpumpTempCmd`      | –           | set-Kommando zum Durchreichen der WP-Temperatur (z. B. `temperatur`) |
| `wpStartTime`          | `09:00`     | Beginn WP-Zeitfenster |
| `wpEndTime`            | `22:00`     | Ende WP-Zeitfenster |
| `solarIndexMin`        | `1`         | Mindest-Solarindex für WP-Betrieb (Rückfall, wenn `solarIndexOn` ungesetzt) |
| `solarIndexOn`         | –           | Einschaltschwelle der Index-Hysterese (z. B. 8) |
| `solarIndexOff`        | = `On`      | Ausschaltschwelle der Index-Hysterese (z. B. 3) |

### Allgemein
| Attribut   | Default | Beschreibung |
|------------|---------|--------------|
| `targetTempSchedule` | – (leer) | Zeitabhängige Solltemperatur, Liste von `HH:MM Temp`-Paaren (z. B. `00:00 32 16:00 33.5`). Überschreibt `set targetTemp`. Leer = keine Zeitsteuerung |
| `interval` | `60`    | Steuerintervall in Sekunden |
| `disable`  | `0`     | 1 = Modul deaktivieren |

> **Zeitabhängige Solltemperatur:** Es gilt jeweils der zuletzt erreichte
> Eintrag (Umlauf über Mitternacht). Beispiel `00:00 32 16:00 33.5`: bis 16:00
> Soll 32 °C, danach 33,5 °C. Sinnvoll, um tagsüber niedriger zu fahren (die
> Sonne heizt über die Kuppel ohnehin nach) und abends, wenn die Sonne
> nachlässt, höher – so schießt der Pool mittags nicht über.

---

## Readings

| Reading              | Beschreibung |
|----------------------|--------------|
| `state`              | Kurzüberblick (Pool/Soll, Filter, Laufzeit; Präfix `[forceOn]`/`[forceOff]` im Handbetrieb) |
| `controlActive`      | on/off – ist die Steuerung aktiv (`set control`)? |
| `mode`               | Betriebsmodus (`auto`/`forceOn`/`forceOff`) |
| `desiredTemperature` | eingestellte Solltemperatur (`set targetTemp`) |
| `filterHoursTarget`  | gewünschte Filterstunden pro Tag (`set filterHours`) |
| `heatpumpTemp`       | der WP mitgeteilte Zieltemperatur (`set heatpumpTemp`) |
| `poolTemp`           | aktuelle Pooltemperatur |
| `inflowTemp`         | Temperatur des einlaufenden Wassers |
| `targetTemp`         | aktuelle Solltemperatur |
| `solarIndex`         | aktueller Solarindex |
| `heatingNeeded`      | yes/no |
| `filterState`        | gewünschter Filterzustand on/off |
| `filterReason`       | Grund (WP+Solar / WP / Solar / Solar (Anlauf) / Nachtfilterung / Umruehren / Heizbedarf, keine Quelle / kein Bedarf). Bei `Solar` (ohne WP) ist der Filter bewusst **aus**. |
| `filterRuntimeToday` | heutige Filterlaufzeit (Minuten) |
| `filterRemaining`    | heute noch fehlende Filterzeit (Stunden) |
| `mixState`           | idle/active – läuft gerade ein Umrühr-Zyklus? |
| `solarState`         | Zustand/Begründung der Solarthermie |
| `solarHeating`       | yes/no – heizt die Solarthermie real? |
| `heatpumpState`      | on/off |
| `heatpumpEffective`  | erwartete WP-Einlauftemperatur (`min(poolTemp + heatpumpOffset, heatpumpTemp + heatpumpRegBand)`); Vergleich mit `inflowTemp` zeigt, ob die WP liefert |
| `quality`            | optionale Qualitätsinfo (pH/ORP) |
| `lastDecision`       | letzte Entscheidungsbegründung |

---

## Beispiel-Setup

Verdrahtung passend zur bestehenden Main-Instanz:

```
define poolControl PoolControl

# Sensoren
attr poolControl poolSensor       MQTT2_Sonoff_TH10_01:poolTemp
attr poolControl inflowSensor     MQTT2_Sonoff_TH10_01:solarTemp
attr poolControl solarIndexSensor d_solar:index
attr poolControl qualitySensor    BLEYC01

# Filterpumpe (Sonoff: POWER-Reading ist ON/OFF, set on/off)
attr poolControl filterSwitch        MQTT2_Sonoff_TH10_01
attr poolControl filterStateReading  POWER
attr poolControl filterOnRegex       on|ON|1
attr poolControl filterOnCmd         on
attr poolControl filterOffCmd        off
attr poolControl filterNightStart    22:00
attr poolControl filterNightEnd      06:00

# Solarthermie (Dummy d_solarpumpe steuert rp_POOL_SOLAR)
attr poolControl solarSwitch       d_solarpumpe
attr poolControl solarOnCmd        on
attr poolControl solarOffCmd       off
attr poolControl solarHysteresis       0.5
attr poolControl solarHysteresisFilter 0.1
attr poolControl solarSettleTime       180
attr poolControl solarRetryDelay       1800

# Solar nur tagsüber und bei PV-Überschuss freigeben
attr poolControl solarStartTime    09:00
attr poolControl solarEndTime      20:00
attr poolControl solarEnable       MQTT2_Sonoff_POW_01:pooltrigger
# (numerisch: attr poolControl solarEnable mySolvis:S08.Solarkollektortemperatur / solarEnableMin 40)

# Optional: PV-Trigger stößt sofort eine Neubewertung an
# define n_pool_solartrigger notify MQTT2_Sonoff_POW_01:pooltrigger:.* set poolControl check

# Wärmepumpe (Dummy d_pool_wp, Temperatur per Reading "temperatur")
attr poolControl heatpumpSwitch    d_pool_wp
attr poolControl heatpumpOnCmd     on
attr poolControl heatpumpOffCmd    off
attr poolControl heatpumpOffset    0.9
attr poolControl heatpumpRegBand   0.5
attr poolControl heatpumpRampTime  180
attr poolControl heatpumpTempCmd   temperatur
attr poolControl wpStartTime       09:00
attr poolControl wpEndTime         22:00
attr poolControl solarIndexMin     1
# Index-Hysterese: WP an ab Index 8, aus erst bei Index <= 3
attr poolControl solarIndexOn      8
attr poolControl solarIndexOff     3

# Sollwerte
set poolControl targetTemp   30
set poolControl filterHours  5
set poolControl heatpumpTemp 28

# Optional: zeitabhängige Solltemperatur (überschreibt targetTemp)
# bis 16:00 -> 32 °C, danach -> 33,5 °C
attr poolControl targetTempSchedule 00:00 32 16:00 33.5
```

---

## Migration aus der bestehenden Automatik

Das Modul ersetzt funktional folgende bestehenden Objekte. Diese sollten erst
**nach erfolgreichem Test** des Moduls deaktiviert/entfernt werden:

- `n_Sonoff_Basic_Switch_04_DS18B20` – Solarthermie-Regelung mit Auskühlschutz
- `a_Sonoff_Basic_Switch_04_on` / `a_Sonoff_Basic_Switch_04_off` – Filter-Zeiten
- `a_d_pool_wp_on` / `a_d_pool_wp_off` – WP-Zeitfenster
- `n_d_solarpumpe`, `n_Sonoff_POW_01_pooltrigger` – weitere Solarpumpen-Trigger

Der Solarindex (`d_solar:index`, berechnet in `n_d_solar_check`) bleibt als
externe Eingangsgröße bestehen und wird vom Modul nur gelesen.

```
attr n_Sonoff_Basic_Switch_04_DS18B20 disable 1
attr a_Sonoff_Basic_Switch_04_on disable 1
attr a_Sonoff_Basic_Switch_04_off disable 1
attr a_d_pool_wp_on disable 1
attr a_d_pool_wp_off disable 1
```
