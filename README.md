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
| **Wärmepumpe**  | Inverter-WP, regelt selbst. Modul gibt sie nur frei (Zeitfenster + ausreichender Solarindex + Heizbedarf + Pool unter WP-Sollwert) und teilt die Zieltemperatur mit. Bei WP-Betrieb läuft der Filter mit; ist der Pool warm genug, bleibt beides aus. |
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

Der Zählerstand **übersteht einen FHEM-Neustart**: er wird aus den Readings
`filterRuntimeToday` + `filterRuntimeDay` zurückgeholt (Readings landen im
Statefile, modulinterne Zähler nicht). Ohne das begann die Zählung nach jedem
Neustart wieder bei 0 und der Filter arbeitete das komplette Tagessoll noch
einmal ab. Stammt der gespeicherte Stand von einem anderen Zähltag (Tageswechsel
bei `filterNightEnd`), wird korrekt bei 0 begonnen. Voraussetzung ist ein
geschriebenes Statefile (`save`, `shutdown restart`); nach einem harten Absturz
gilt der letzte gespeicherte Stand.

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
Modul gibt sie daher nur **frei** und überlässt die Temperaturregelung der WP.
Freigabe nur, wenn **alle** Bedingungen erfüllt sind:
- aktuelle Zeit liegt im Fenster `wpStartTime`–`wpEndTime` (Default 09:00–22:00),
- der `solarIndex` reicht aus (genug Stromüberschuss),
- es besteht **Heizbedarf** (`poolTemp < Soll`) **und** der Pool liegt **unter dem
  WP-Sollwert** `heatpumpTemp` (darüber kann die WP ohnehin nicht mehr heizen).

Ist der Pool warm genug, wird die WP **nicht** freigegeben – und damit läuft auch
**die Filterpumpe nicht** „für die WP". Die noch fehlende Filterzeit holt das
Modul im Nachtfenster nach.

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

> **Nicht fernsteuerbare WP:** Hängt die Wärmepumpe an einer Zeitschaltuhr, kann
> das Modul sie nur *anfragen* – physisch heizt sie, sobald Wasser fließt. Die
> **Filterpumpe ist dann faktisch der WP-Schalter.** Mit `heatpumpReadOnly 1`
> schaltet das Modul die WP nie, sondern übernimmt den (von Hand gepflegten)
> gemeldeten Zustand – sonst überschreibt es den Dummy sofort wieder.

### Saisonbetrieb: filtern ohne heizen
Im Herbst soll oft noch gefiltert, aber nicht mehr geheizt werden. Dafür gibt es
`set <name> heating off` (Attribut `heating`):

- Solarthermie und Wärmepumpe bleiben **aus**,
- es wird **nicht umgerührt**,
- die Filterpumpe erfüllt weiter ihr Tagessoll (`filterHours`) – in der Praxis
  also im Nachtfenster.

Der Schalter liegt als **Attribut** vor und übersteht damit Neustarts; ein Reset
auf „heizen" wäre im Herbst genau falsch.

> **Nicht** stattdessen die Solltemperatur künstlich tief setzen: für das Modul
> heißt „Soll erreicht" *Wärme verteilen*, und genau das löst das Umrühren aus –
> mit einer per Zeitschaltuhr laufenden WP heizt der dabei erzeugte Durchfluss
> den Pool dann sogar. Ein manuelles `set targetTemp` wird bei aktivem
> `targetTempSchedule` ohnehin am nächsten Zeitplan-Punkt wieder überschrieben.

Meldet die WP trotz `heating off` „an" (Zeitschaltuhr), setzt das Modul die
**Automatik-Filterung aus**, damit der Durchfluss nicht heizt; `filterReason`
zeigt dann `aus: WP an, soll nicht heizen`. Hand- und Zwangsbetrieb
(`set filter on`, `mode forceOn`) gehen weiter vor – `lastDecision` warnt in
diesem Fall, dass trotzdem geheizt wird.

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
| `heating on\|off`       | Saisonschalter „nur filtern, nicht heizen". `off` = Solar und WP bleiben aus, es wird **nicht umgerührt**, der Filter erfüllt weiter sein Tagessoll → schreibt das **Attribut** `heating` (überlebt Neustarts) |
| `filter on\|off\|auto`  | manueller Filter-Override; wird beim Beginn des Nachtfensters automatisch auf `auto` zurückgesetzt. `mode forceOn/forceOff` hat Vorrang |
| `targetTemp <°C>`       | Solltemperatur des Pools. Bei aktivem `targetTempSchedule` gilt der manuelle Wert als **Override bis zum nächsten Zeitplan-Punkt**, dann übernimmt wieder der Zeitplan |
| `filterHours <h>`       | gewünschte Filterstunden pro Tag → schreibt das **Attribut** `filterHours` (überlebt Neustarts) |
| `heatpumpTemp <°C>`     | der Wärmepumpe mitgeteilte Temperatur → schreibt das **Attribut** `heatpumpTemp` (überlebt Neustarts) |
| `resetRuntime`          | Tageslaufzeitzähler zurücksetzen |
| `check`                 | Steuerzyklus sofort ausführen |

> **Persistenz:** `filterHours` und `heatpumpTemp` sind **Attribute** (in der `fhem.cfg`), damit sie Neustarts sicher überstehen. `control`, `mode`, `filter` und `targetTemp` bleiben Readings und setzen sich bewusst auf sichere Defaults zurück (`filter`/`mode`/`control` nach Neustart bzw. `filter` nachts).

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
| `filterHours`        | `5`         | gewünschte Filterstunden pro Tag (auch per `set filterHours`) |

### Umrühren / Durchmischung
Das von der Solarthermie erwärmte Wasser sammelt sich oben im Pool. Damit sich
die Wärme verteilt (und der Pool-Sensor nicht vorzeitig „warm genug" meldet),
zirkuliert der Filter periodisch, **sobald das Soll erreicht ist** (kein
Heizbedarf mehr). Solange der Pool noch unter Soll liegt, wird **nicht** gerührt –
Zirkulieren ohne Wärmezufuhr verteilt nichts und kühlt über den Umwälzverlust
sogar leicht aus. Während ohnehin gefiltert/geheizt wird, ist kein separates
Umrühren nötig.

Zusätzlich muss seit dem letzten Umrühren **wirklich eine Wärmequelle gelaufen
sein** (Solar heizt bzw. WP an) – sonst gibt es nichts zu verteilen. Ohne diese
Bedingung mischt das Modul auch dann im Stundentakt, wenn überhaupt nicht
geheizt wird (unerreichbar tiefes Soll oder `heating off`): das verteilt nichts,
kostet Pumpenlaufzeit und **heizt bei einer nicht fernsteuerbaren Wärmepumpe
sogar unfreiwillig**, weil der Filter den Durchfluss liefert. Bei
`heating off` wird gar nicht gemischt.

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
| `heatpumpSwitch`       | –           | **Gerätename** der Wärmepumpe (bzw. des Dummys). Leer = WP wird komplett ignoriert (weder geschaltet noch gelesen) |
| `heatpumpStateReading` | `state`     | **Name des Readings** innerhalb von `heatpumpSwitch`, in dem on/off steht – hier gehört *kein* Gerätename hinein |
| `heatpumpReadOnly`     | `0`         | `1` = Modul **beobachtet** die WP nur und schaltet sie nie (WP an der Zeitschaltuhr, nicht fernsteuerbar). Der gemeldete Zustand zählt dann für die Entscheidungen; bei `heating off` + WP „an" setzt das Modul die Automatik-Filterung aus, damit der Durchfluss nicht heizt |
| `heatpumpOnRegex`      | `on\|ON\|1` | Regex für „an" |
| `heatpumpOnCmd`        | `on`        | Einschaltkommando |
| `heatpumpOffCmd`       | `off`       | Ausschaltkommando |
| `heatpumpTemp`         | `28`        | der WP mitgeteilte Zieltemperatur (auch per `set heatpumpTemp`; wird über `heatpumpTempCmd` durchgereicht) |
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
| `heating`  | `on`    | `off` = Saisonbetrieb „nur filtern, nicht heizen" (Solar + WP aus, kein Umrühren; Filter erfüllt sein Tagessoll). Bequem per `set heating on\|off` |
| `interval` | `60`    | Steuerintervall in Sekunden |
| `disable`  | `0`     | 1 = Modul deaktivieren |

> **Zeitabhängige Solltemperatur:** Es gilt jeweils der zuletzt erreichte
> Eintrag (Umlauf über Mitternacht). Beispiel `00:00 32 16:00 33.5`: bis 16:00
> Soll 32 °C, danach 33,5 °C. Sinnvoll, um tagsüber niedriger zu fahren (die
> Sonne heizt über die Kuppel ohnehin nach) und abends, wenn die Sonne
> nachlässt, höher – so schießt der Pool mittags nicht über.
>
> **Manueller Override:** Ein `set targetTemp <°C>` bei aktivem Zeitplan gilt
> **bis zum nächsten Zeitplan-Punkt** (z. B. um 11:00 gesetzt → hält bis 16:00),
> dann übernimmt wieder der Zeitplan. So kann man kurzfristig abweichen, ohne den
> Zeitplan zu ändern.

---

## Readings

| Reading              | Beschreibung |
|----------------------|--------------|
| `state`              | Kurzüberblick (Pool/Soll, Filter, Laufzeit; Präfix `[forceOn]`/`[forceOff]` im Handbetrieb) |
| `controlActive`      | on/off – ist die Steuerung aktiv (`set control`)? |
| `mode`               | Betriebsmodus (`auto`/`forceOn`/`forceOff`) |
| `filter`             | on/off/auto – manueller Filter-Override (`set filter`), nachts auf `auto` zurückgesetzt; heißt wie der set-Befehl, damit `webCmd filter` den Wert anzeigt |
| `heating`            | on/off – Spiegel des Attributs `heating` (Quelle der Wahrheit bleibt das Attribut); macht den Saisonschalter im Dashboard sichtbar |
| `desiredTemperature` | eingestellte Solltemperatur (`set targetTemp`) |
| `poolTemp`           | aktuelle Pooltemperatur |
| `inflowTemp`         | Temperatur des einlaufenden Wassers |
| `targetTemp`         | aktuelle Solltemperatur |
| `solarIndex`         | aktueller Solarindex |
| `heatingNeeded`      | yes/no |
| `filterState`        | gewünschter Filterzustand on/off |
| `filterReason`       | Grund (WP+Solar / WP / Solar / Solar (Anlauf) / Nachtfilterung / Umruehren / Heizbedarf, keine Quelle / kein Bedarf / nur filtern (Heizen aus) / aus: WP an, soll nicht heizen). Bei `Solar` (ohne WP) ist der Filter bewusst **aus**. |
| `filterRuntimeToday` | heutige Filterlaufzeit (Minuten) |
| `filterRuntimeDay`   | Zähltag zu `filterRuntimeToday` (`YYYY-MM-DD`) – damit die Laufzeit einen FHEM-Neustart übersteht |
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
