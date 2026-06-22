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
| **Filterung**   | Gewünschte Filterstunden pro Tag. Heizbetrieb zählt mit, Rest wird nachts nachgefiltert. |
| **Heizung**     | Solltemperatur, geheizt über Solarthermie (Vorrang, kostenlos) und Wärmepumpe. |
| **Auskühlschutz** | Solarthermie wird abgeschaltet, wenn das einlaufende Wasser kälter ist als der Pool. |
| **Wärmepumpe**  | Inverter-WP, regelt selbst. Modul gibt sie nur frei (Zeitfenster + ausreichender Solarindex) und teilt die Zieltemperatur mit. |
| **Wasserqualität** | Optionaler Sensor (z. B. BLE-YC01), nur informativ, blockiert die Steuerung nicht. |

---

## Funktionsweise

### Filterung
Über `set <name> filterHours <h>` wird die gewünschte Filterzeit pro Tag
vorgegeben. Das Modul summiert die tatsächliche Filterlaufzeit (`filterRuntimeToday`).
Da der Filter beim Heizen (Solar/WP) ohnehin läuft, wird diese Zeit angerechnet.
Fehlt am Tagesende noch Laufzeit, wird im Nachtfenster
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
eingeschaltet. Nach `solarSettleTime` (Default 180 s) wird geprüft, ob das
einlaufende Wasser (`inflowSensor`) um mindestens `solarHysteresis` (Default
0,5 °C) wärmer ist als der Pool. Ist es kälter, wird die Pumpe wieder
abgeschaltet (Auskühlschutz) und für `solarRetryDelay` (Default 1800 s) gesperrt.

### Wärmepumpe (Inverter)
Die WP ist eine Inverter-Wärmepumpe und **regelt ihre Leistung selbst**. Das
Modul gibt sie daher nur **frei** und überlässt die Temperaturregelung der WP:
- aktuelle Zeit liegt im Fenster `wpStartTime`–`wpEndTime` (Default 09:00–22:00),
- `solarIndex >= solarIndexMin` (genug Stromüberschuss für den WP-Betrieb).

Die der WP mitgeteilte Zieltemperatur wird per `set <name> heatpumpTemp <°C>`
gesetzt und kann optional über `heatpumpTempCmd` an das WP-Gerät durchgereicht
werden. Das Reading `heatpumpEffective` (= `heatpumpTemp + heatpumpOffset`) ist
nur informativ und greift **nicht** mehr in die Schaltung ein.

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
| `control on\|off`       | Steuerung aktivieren/deaktivieren |
| `targetTemp <°C>`       | Solltemperatur des Pools |
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
zirkuliert der Filter in Sollnähe periodisch – auch ohne aktiven Heizbetrieb.
Während ohnehin gefiltert/geheizt wird, ist kein separates Umrühren nötig.

| Attribut       | Default | Beschreibung |
|----------------|---------|--------------|
| `mixThreshold` | `2`     | ab `Soll - mixThreshold` °C wird umgerührt |
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
| `solarHysteresis`   | `0.5`       | Mindest-Übertemperatur Einlaufwasser |
| `solarSettleTime`   | `180`       | Wartezeit nach Anlauf vor Auskühlprüfung (s) |
| `solarRetryDelay`   | `1800`      | Sperrzeit nach Abschaltung wegen Auskühlung (s) |

### Wärmepumpe
| Attribut               | Default     | Beschreibung |
|------------------------|-------------|--------------|
| `heatpumpSwitch`       | –           | Gerät der Wärmepumpe |
| `heatpumpStateReading` | `state`     | Status-Reading |
| `heatpumpOnRegex`      | `on\|ON\|1` | Regex für „an" |
| `heatpumpOnCmd`        | `on`        | Einschaltkommando |
| `heatpumpOffCmd`       | `off`       | Ausschaltkommando |
| `heatpumpOffset`       | `0.5`       | nur informativ: Mehrtemperatur der WP, fließt in `heatpumpEffective` ein |
| `heatpumpTempCmd`      | –           | set-Kommando zum Durchreichen der WP-Temperatur (z. B. `temperatur`) |
| `wpStartTime`          | `09:00`     | Beginn WP-Zeitfenster |
| `wpEndTime`            | `22:00`     | Ende WP-Zeitfenster |
| `solarIndexMin`        | `1`         | Mindest-Solarindex für WP-Betrieb |

### Allgemein
| Attribut   | Default | Beschreibung |
|------------|---------|--------------|
| `interval` | `60`    | Steuerintervall in Sekunden |
| `disable`  | `0`     | 1 = Modul deaktivieren |

---

## Readings

| Reading              | Beschreibung |
|----------------------|--------------|
| `state`              | Kurzüberblick (Pool/Soll, Filter, Laufzeit) |
| `poolTemp`           | aktuelle Pooltemperatur |
| `inflowTemp`         | Temperatur des einlaufenden Wassers |
| `targetTemp`         | aktuelle Solltemperatur |
| `solarIndex`         | aktueller Solarindex |
| `heatingNeeded`      | yes/no |
| `filterState`        | gewünschter Filterzustand on/off |
| `filterReason`       | Grund (Solar / WP / Solar+WP / Nachtfilterung / Umruehren / kein Bedarf) |
| `filterRuntimeToday` | heutige Filterlaufzeit (Minuten) |
| `filterRemaining`    | heute noch fehlende Filterzeit (Stunden) |
| `mixState`           | idle/active – läuft gerade ein Umrühr-Zyklus? |
| `solarState`         | Zustand/Begründung der Solarthermie |
| `solarHeating`       | yes/no – heizt die Solarthermie real? |
| `heatpumpState`      | on/off |
| `heatpumpEffective`  | effektive WP-Temperatur (`heatpumpTemp + heatpumpOffset`) |
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
attr poolControl solarHysteresis   0.5
attr poolControl solarSettleTime   180
attr poolControl solarRetryDelay   1800

# Wärmepumpe (Dummy d_pool_wp, Temperatur per Reading "temperatur")
attr poolControl heatpumpSwitch    d_pool_wp
attr poolControl heatpumpOnCmd     on
attr poolControl heatpumpOffCmd    off
attr poolControl heatpumpOffset    0.5
attr poolControl heatpumpTempCmd   temperatur
attr poolControl wpStartTime       09:00
attr poolControl wpEndTime         22:00
attr poolControl solarIndexMin     1

# Sollwerte
set poolControl targetTemp   30
set poolControl filterHours  5
set poolControl heatpumpTemp 28
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
