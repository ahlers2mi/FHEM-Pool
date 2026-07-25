##############################################################################
# 98_PoolControl.pm
#
# FHEM-Modul zur Steuerung von Poolfilterung und Poolheizung.
#
# Funktionen:
#   * Filterung: Vorgabe der gewünschten Filterstunden pro Tag. Die WP läuft
#     auf Filtergeschwindigkeit, ihr Betrieb zirkuliert das Wasser also ohnehin
#     und wird auf das Tagessoll angerechnet. Solar dagegen läuft (sofern die WP
#     nicht ohnehin filtert) über einen eigenen, langsamen Kreis OHNE Filter und
#     zählt NICHT auf das Filtersoll. Fehlt am Tagesende noch Laufzeit, wird in
#     einem konfigurierbaren Nachtfenster nachgefiltert. Der Filtertag wechselt
#     am Ende des Nachtfensters (filterNightEnd), damit das Nachfiltern über
#     Mitternacht hinweg demselben Tag zugerechnet wird.
#   * Solltemperatur (desiredTemperature) einstellbar.
#   * Solarthermie mit flussabhängigem Auskühlschutz: Solar erwärmt das Wasser
#     nur bei langsamer Strömung stark; läuft die Filterpumpe mit, sackt der Hub
#     ab. Daher löst Solar selbst keine Filterung aus (Solar-only -> Filter aus,
#     großer Hub), läuft aber gemeinsam mit der WP, wenn diese filtert. Der
#     Auskühlschutz fordert je nach Strömung eine andere Mindest-Übertemperatur
#     des Einlaufwassers (inflowSensor) über dem Pool: Filter aus ->
#     solarHysteresis (~0,5°), Filter an -> solarHysteresisFilter (~0,1°). Läuft
#     die WP aktiv, wird ihr Beitrag (~heatpumpOffset) abgezogen. Nach dem
#     WP-Anlauf (heatpumpRampTime) ist der Beitrag erst voll da; in dieser Zeit
#     wird der Auskühlschutz ausgesetzt. Reicht der Hub nicht, wird die
#     Solarpumpe abgeschaltet und für solarRetryDelay gesperrt. Anlaufversuche
#     lassen sich optional auf ein Zeitfenster (solarStartTime/solarEndTime) und
#     eine externe Freigabe (solarEnable, z. B. PV-Überschuss oder Kollektor-
#     temperatur) einschränken, damit die Pumpe nachts/ohne Sonne nicht taktet.
#   * Wärmepumpe (Inverter, regelt selbst): Das Modul gibt die WP nur frei
#     (Zeitfenster wpStartTime/wpEndTime, ausreichender Solarindex, Heizbedarf
#     und Pool unter WP-Sollwert) und teilt ihr die Zieltemperatur mit. Ist der
#     Pool warm genug, wird die WP – und damit die Filterpumpe – nicht „für die
#     WP" eingeschaltet. WP und Solar sind beide sonnengesteuert und
#     arbeiten zusammen; bei WP-Betrieb läuft die Filterpumpe mit. Der Solarindex
#     (verfügbarer Stromüberschuss) wirkt mit Hysterese: Freigabe ab
#     solarIndexOn, Sperre bei solarIndexOff, dazwischen Zustand halten. Die
#     Leistungsregelung übernimmt die WP selbst.
#   * Optionaler Wasserqualitätssensor (z. B. BLEYC01). Da dieser instabil
#     laufen kann, ist er optional und blockiert die Steuerung nicht.
#
# Das Modul steuert ausschließlich über konfigurierbare Fremdgeräte (per
# Attribut) und hält keine eigene Hardware. Alle Ein-/Ausgänge sind über
# Attribute frei zuordenbar.
#
# Autor:    ahlers2mi
# Version:  v0.11.2
# Lizenz:   GPL v2 oder höher (wie FHEM)
##############################################################################

package main;

use strict;
use warnings;

use POSIX qw(strftime);

# Von fhem.pl bereitgestellte Globals.
use vars qw($init_done %defs $readingFnAttributes);

# ----------------------------------------------------------------------------
# PoolControl_Initialize
#   Registriert die Callback-Funktionen und die Attributliste.
# ----------------------------------------------------------------------------
sub PoolControl_Initialize {
    my ($hash) = @_;

    $hash->{DefFn}    = \&PoolControl_Define;
    $hash->{UndefFn}  = \&PoolControl_Undef;
    $hash->{SetFn}    = \&PoolControl_Set;
    $hash->{GetFn}    = \&PoolControl_Get;
    $hash->{AttrFn}   = \&PoolControl_Attr;
    $hash->{NotifyFn} = \&PoolControl_Notify;

    $hash->{AttrList} =
          "disable:0,1 "
        . "interval:textField "
        . "targetTempSchedule:textField "
        # --- Sensoren (Format: <Gerät>:<Reading>) ---
        . "poolSensor:textField "
        . "inflowSensor:textField "
        . "solarIndexSensor:textField "
        . "qualitySensor:textField "
        # --- Filterpumpe ---
        . "filterSwitch:textField "
        . "filterStateReading:textField "
        . "filterOnRegex:textField "
        . "filterOnCmd:textField "
        . "filterOffCmd:textField "
        . "filterNightStart:textField "
        . "filterNightEnd:textField "
        . "filterHours:slider,0,0.5,24 "
        # --- Umrühren / Durchmischung ---
        . "mixInterval:slider,0,60,7200 "
        . "mixDuration:slider,0,30,1800 "
        # --- Solarthermie ---
        . "solarSwitch:textField "
        . "solarStateReading:textField "
        . "solarOnRegex:textField "
        . "solarOnCmd:textField "
        . "solarOffCmd:textField "
        . "solarHysteresis:slider,0,0.1,5 "
        . "solarHysteresisFilter:slider,0,0.1,5 "
        . "solarSettleTime:slider,0,30,1800 "
        . "solarRetryDelay:slider,0,60,7200 "
        . "solarColdStartAfter:slider,0,600,86400 "
        . "solarColdStartExtra:slider,0,30,1800 "
        . "solarStartTime:textField "
        . "solarEndTime:textField "
        . "solarEnable:textField "
        . "solarEnableRegex:textField "
        . "solarEnableMin:textField "
        # --- Wärmepumpe ---
        . "heatpumpSwitch:textField "
        . "heatpumpStateReading:textField "
        . "heatpumpOnRegex:textField "
        . "heatpumpOnCmd:textField "
        . "heatpumpOffCmd:textField "
        . "heatpumpTemp:slider,10,0.5,40 "
        . "heatpumpOffset:slider,0,0.1,5 "
        . "heatpumpRegBand:slider,0,0.1,5 "
        . "heatpumpRampTime:slider,0,30,1800 "
        . "heatpumpTempCmd:textField "
        . "wpStartTime:textField "
        . "wpEndTime:textField "
        . "solarIndexMin:textField "
        . "solarIndexOn:textField "
        . "solarIndexOff:textField "
        . $readingFnAttributes;
}

# ----------------------------------------------------------------------------
# PoolControl_Define
#   define <name> PoolControl
# ----------------------------------------------------------------------------
sub PoolControl_Define {
    my ($hash, $def) = @_;
    my @a = split('[ \t][ \t]*', $def);

    return "Usage: define <name> PoolControl" if (@a != 2);

    my $name = $a[0];
    $hash->{NAME}    = $name;
    $hash->{VERSION} = "0.11.2";

    # Operative Zustände als Readings anlegen (nur falls fehlend). Diese setzen
    # sich nach einem Neustart bewusst auf sichere Defaults zurück:
    # controlActive=on, mode=auto (ein haengengebliebenes forceOff will man nicht),
    # desiredTemperature=30 (wird i. d. R. eh vom targetTempSchedule ueberschrieben).
    # Die Sollwerte filterHours und heatpumpTemp sind dagegen ATTRIBUTE (s.
    # AttrList) und ueberleben Neustarts zuverlaessig ueber die Config.
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "controlActive",
        ReadingsVal($name, "controlActive", "on"));
    readingsBulkUpdate($hash, "mode",
        ReadingsVal($name, "mode", "auto"));
    readingsBulkUpdate($hash, "filterManual",
        ReadingsVal($name, "filterManual", "auto"));
    readingsBulkUpdate($hash, "desiredTemperature",
        ReadingsVal($name, "desiredTemperature", 30));
    readingsEndUpdate($hash, 0);

    PoolControl_setNotifyDev($hash);

    RemoveInternalTimer($hash);
    # Einmalige Migration alter Readings -> Attribute; laeuft nach dem Laden des
    # Statefiles (deshalb per Timer, nicht inline in Define).
    InternalTimer(gettimeofday() + 3, "PoolControl_migrate", $hash, 0);
    # Erste Steuerung kurz nach dem Start (Geräte müssen geladen sein).
    InternalTimer(gettimeofday() + 5, "PoolControl_Control", $hash, 0)
        if ($init_done);

    return undef;
}

# ----------------------------------------------------------------------------
# PoolControl_migrate
#   Einmalige Übernahme früherer Readings in die jetzt genutzten Attribute
#   (Upgrade-Pfad) und Entfernen der veralteten Readings. Idempotent.
# ----------------------------------------------------------------------------
sub PoolControl_migrate {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    # [Attribut, altes Reading]
    for my $p (["filterHours", "filterHoursTarget"], ["heatpumpTemp", "heatpumpTemp"]) {
        my ($attrName, $oldReading) = @$p;
        my $old = ReadingsVal($name, $oldReading, undef);
        if (!defined AttrVal($name, $attrName, undef)
            && defined $old && $old ne "") {
            CommandAttr(undef, "$name $attrName $old");
        }
        readingsDelete($hash, $oldReading) if (defined $hash->{READINGS}{$oldReading});
    }
    return undef;
}

# ----------------------------------------------------------------------------
# PoolControl_Undef
# ----------------------------------------------------------------------------
sub PoolControl_Undef {
    my ($hash, $name) = @_;
    RemoveInternalTimer($hash);
    return undef;
}

# ----------------------------------------------------------------------------
# PoolControl_Set
# ----------------------------------------------------------------------------
sub PoolControl_Set {
    my ($hash, $name, $cmd, @args) = @_;

    my $list =
          "control:on,off "
        . "mode:auto,forceOn,forceOff "
        . "filter:on,off,auto "
        . "targetTemp:slider,10,0.5,40 "
        . "filterHours:slider,0,0.5,24 "
        . "heatpumpTemp:slider,10,0.5,40 "
        . "resetRuntime:noArg "
        . "solarCheck:noArg "
        . "check:noArg";

    if ($cmd eq "control") {
        my $v = $args[0] // "";
        return "control needs on|off" if ($v ne "on" && $v ne "off");
        readingsSingleUpdate($hash, "controlActive", $v, 1);
        PoolControl_Control($hash);
        return undef;
    }
    elsif ($cmd eq "mode") {
        my $v = $args[0] // "";
        return "mode needs auto|forceOn|forceOff"
            if ($v !~ /^(auto|forceOn|forceOff)$/);
        readingsSingleUpdate($hash, "mode", $v, 1);
        PoolControl_Control($hash);
        return undef;
    }
    elsif ($cmd eq "filter") {
        # Manueller Filter-Override (an/aus), unabhängig von der Automatik.
        # Wird nachts (Beginn Nachtfenster) automatisch auf "auto" zurückgesetzt,
        # damit die Nachtfilterung normal läuft; "set filter auto" hebt ihn
        # sofort auf. mode forceOn/forceOff hat weiterhin Vorrang.
        my $v = $args[0] // "";
        return "filter needs on|off|auto" if ($v !~ /^(on|off|auto)$/);
        readingsSingleUpdate($hash, "filterManual", $v, 1);
        PoolControl_Control($hash);
        return undef;
    }
    elsif ($cmd eq "targetTemp") {
        return "targetTemp needs a number" if (!defined $args[0] || $args[0] !~ /^[\d.]+$/);
        readingsSingleUpdate($hash, "desiredTemperature", $args[0] + 0, 1);
        PoolControl_Control($hash);
        return undef;
    }
    elsif ($cmd eq "filterHours") {
        return "filterHours needs a number" if (!defined $args[0] || $args[0] !~ /^[\d.]+$/);
        # Als Attribut ablegen -> überlebt Neustarts (mit autosave) zuverlässig.
        # Control-Neuberechnung + WP-Durchreichung erledigt PoolControl_Attr.
        CommandAttr(undef, "$name filterHours " . ($args[0] + 0));
        return undef;
    }
    elsif ($cmd eq "heatpumpTemp") {
        return "heatpumpTemp needs a number" if (!defined $args[0] || $args[0] !~ /^[\d.]+$/);
        CommandAttr(undef, "$name heatpumpTemp " . ($args[0] + 0));
        return undef;
    }
    elsif ($cmd eq "resetRuntime") {
        $hash->{".runtimeSec"}  = 0;
        $hash->{".runtimeDate"} = PoolControl_dayKey($hash);
        readingsSingleUpdate($hash, "filterRuntimeToday", 0, 1);
        return undef;
    }
    elsif ($cmd eq "solarCheck") {
        # Erzwungene, sofortige Solar-Neuprüfung – egal, was die Automatik zuvor
        # entschieden hat. "set check" respektiert weiterhin die Auskühl-Sperre
        # (solarRetryDelay): wurde Solar wegen zu kleinem Hub abgeschaltet, läuft
        # es erst nach Ablauf der Sperrzeit wieder an. "solarCheck" hebt genau
        # diese Sperre auf, verwirft den Prüfphasen-Timer und startet dann sofort
        # einen Steuerzyklus, sodass Solar garantiert einen frischen
        # Anlaufversuch macht (nützlich, wenn die Sonne offensichtlich wieder auf
        # den Platten steht).
        #
        # Zusätzlich wird das Solarfenster (Zeitfenster solarStartTime/
        # solarEndTime + externe Freigabe solarEnable) für diesen erzwungenen
        # Lauf übergangen: der Check läuft also auch AUSSERHALB des Solarfensters.
        # Das Flag ist "klebrig" – es überdauert die nachfolgenden Automatik-
        # Zyklen, damit der Auskühlschutz die volle Settle-Zeit (solarSettleTime)
        # Zeit zum Messen hat und nicht schon beim nächsten Tick wieder als
        # "off (ausserhalb Solarfenster)" abgeschaltet wird. Es wird erst
        # aufgehoben, wenn Solar aus einem echten Grund abschaltet
        # (Auskühlschutz, Soll erreicht, forceOff) – siehe PoolControl_Control.
        delete $hash->{".solarOffColdTime"};   # Auskühl-Sperre aufheben
        delete $hash->{".solarOnTime"};        # Prüfphasen-/Settle-Timer verwerfen
        $hash->{".solarForceCheck"} = 1;       # Solarfenster für diesen Lauf übergehen
        PoolControl_Control($hash);
        return undef;
    }
    elsif ($cmd eq "check") {
        PoolControl_Control($hash);
        return undef;
    }

    return "Unknown argument $cmd, choose one of $list";
}

# ----------------------------------------------------------------------------
# PoolControl_Get
# ----------------------------------------------------------------------------
sub PoolControl_Get {
    my ($hash, $name, $cmd, @args) = @_;

    my $list = "config:noArg";

    if ($cmd eq "config") {
        return PoolControl_dumpConfig($hash);
    }

    return "Unknown argument $cmd, choose one of $list";
}

# ----------------------------------------------------------------------------
# PoolControl_Attr
#   Aktualisiert bei Änderung der Quellgeräte die NOTIFYDEV-Liste.
# ----------------------------------------------------------------------------
sub PoolControl_Attr {
    my ($cmd, $name, $attrName, $attrVal) = @_;
    my $hash = $defs{$name};

    if ($attrName eq "disable") {
        if ($cmd eq "set" && $attrVal) {
            RemoveInternalTimer($hash);
        }
        elsif ($init_done) {
            RemoveInternalTimer($hash);
            InternalTimer(gettimeofday() + 2, "PoolControl_Control", $hash, 0);
        }
    }

    # heatpumpTemp: Zieltemperatur optional an das WP-Gerät durchreichen
    # (z. B. set d_pool_wp temperatur <x>). Nur im laufenden Betrieb, nicht
    # beim Config-Laden.
    if ($init_done && $cmd eq "set" && $attrName eq "heatpumpTemp"
        && defined $attrVal && $attrVal =~ /^[\d.]+$/) {
        my $hp     = AttrVal($name, "heatpumpSwitch", "");
        my $tmpcmd = AttrVal($name, "heatpumpTempCmd", "");
        if ($hp ne "" && $tmpcmd ne "" && defined $defs{$hp}) {
            fhem("set $hp $tmpcmd " . ($attrVal + 0));
        }
    }

    # Sollwert-Änderung (Attribut) -> Steuerung neu rechnen.
    if ($init_done && $attrName =~ /^(heatpumpTemp|filterHours)$/) {
        InternalTimer(gettimeofday() + 1, "PoolControl_Control", $hash, 0);
    }

    # Nach dem eigentlichen Setzen des Attributs NOTIFYDEV neu aufbauen.
    InternalTimer(gettimeofday() + 1, "PoolControl_setNotifyDev", $hash, 0)
        if ($init_done);

    return undef;
}

# ----------------------------------------------------------------------------
# PoolControl_setNotifyDev
#   Beschränkt die Notify-Auswertung auf die konfigurierten Quellgeräte.
# ----------------------------------------------------------------------------
sub PoolControl_setNotifyDev {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my %devs;
    for my $attr (qw(poolSensor inflowSensor solarIndexSensor qualitySensor
                     filterSwitch solarSwitch heatpumpSwitch solarEnable)) {
        my $spec = AttrVal($name, $attr, "");
        next if ($spec eq "");
        my ($dev) = split(/:/, $spec, 2);
        $devs{$dev} = 1 if (defined $dev && $dev ne "");
    }

    if (keys %devs) {
        $hash->{NOTIFYDEV} = join(",", sort keys %devs);
    }
    else {
        delete $hash->{NOTIFYDEV};
    }
    return undef;
}

# ----------------------------------------------------------------------------
# PoolControl_Notify
#   Reagiert auf Events der Quellgeräte und stößt (entprellt) eine
#   Neuberechnung an. Schutz gegen Rekursion über .inControl.
# ----------------------------------------------------------------------------
sub PoolControl_Notify {
    my ($own, $dev) = @_;
    my $name = $own->{NAME};

    return if (!$init_done);
    return if (IsDisabled($name));
    return if ($own->{".inControl"});
    return if (ReadingsVal($name, "controlActive", "on") ne "on");

    # Entprellen: in 2 s neu berechnen (verschiebt zugleich den periodischen Lauf).
    RemoveInternalTimer($own);
    InternalTimer(gettimeofday() + 2, "PoolControl_Control", $own, 0);
    return undef;
}

# ============================================================================
# Hilfsfunktionen
# ============================================================================

# Liest "<Gerät>:<Reading>" numerisch; Default bei fehlendem Wert.
sub PoolControl_num {
    my ($spec, $default) = @_;
    return $default if (!defined $spec || $spec eq "");
    my ($dev, $rd) = split(/:/, $spec, 2);
    $rd = "state" if (!defined $rd || $rd eq "");
    return $default if (!defined $dev || !defined $defs{$dev});
    return ReadingsNum($dev, $rd, $default);
}

# Prüft, ob ein Schalter "an" ist (Reading matcht Regex).
sub PoolControl_isOn {
    my ($dev, $reading, $regex) = @_;
    return 0 if (!defined $dev || $dev eq "" || !defined $defs{$dev});
    my $val = ReadingsVal($dev, $reading, "");
    return ($val =~ /$regex/) ? 1 : 0;
}

# Schaltet ein Gerät (no-op, falls Gerät nicht existiert).
sub PoolControl_switch {
    my ($dev, $cmd) = @_;
    return if (!defined $dev || $dev eq "" || !defined $defs{$dev});
    return if (!defined $cmd || $cmd eq "");
    fhem("set $dev $cmd");
    return;
}

# "HH:MM" -> Minuten seit Mitternacht.
sub PoolControl_hm2min {
    my ($hm) = @_;
    return undef if (!defined $hm || $hm !~ /^(\d{1,2}):(\d{2})$/);
    return $1 * 60 + $2;
}

# Aktive Solltemperatur aus einem Zeitplan "HH:MM temp HH:MM temp ...".
# Gilt der zuletzt erreichte Eintrag; vor dem ersten Eintrag des Tages gilt der
# späteste Eintrag (Umlauf über Mitternacht). Liefert undef bei leerem/ungültigem
# Plan, sodass der Aufrufer auf den manuellen Wert zurückfällt.
sub PoolControl_scheduledTarget {
    my ($spec) = @_;
    return undef if (!defined $spec || $spec eq "");
    my @tok = split(/\s+/, $spec);
    my @t   = localtime;
    my $now = $t[2] * 60 + $t[1];

    my ($best, $bestMin, $lastTemp, $lastMin);
    while (@tok >= 2) {
        my $hm   = shift @tok;
        my $temp = shift @tok;
        my $m = PoolControl_hm2min($hm);
        next if (!defined $m || $temp !~ /^-?\d+(?:\.\d+)?$/);
        if (!defined $lastMin || $m > $lastMin) { $lastMin = $m; $lastTemp = $temp; }
        if ($m <= $now && (!defined $bestMin || $m > $bestMin)) {
            $bestMin = $m; $best = $temp;
        }
    }
    return $best + 0     if (defined $best);       # passender Eintrag heute
    return $lastTemp + 0 if (defined $lastTemp);   # Umlauf: spätester Eintrag gilt
    return undef;
}

# Liegt "jetzt" im Fenster [start,end)? Unterstützt über Mitternacht.
sub PoolControl_inWindow {
    my ($start, $end) = @_;
    my $s = PoolControl_hm2min($start);
    my $e = PoolControl_hm2min($end);
    return 0 if (!defined $s || !defined $e);
    my @t   = localtime;
    my $now = $t[2] * 60 + $t[1];
    return ($s <= $e) ? ($now >= $s && $now < $e)
                      : ($now >= $s || $now < $e);
}

# Schlüssel des aktuellen "Filtertags". Der Tageswechsel liegt am Ende des
# Nachtfensters (filterNightEnd, Default 06:00), damit das nächtliche
# Nachfiltern über Mitternacht hinweg demselben Tag zugerechnet wird.
sub PoolControl_dayKey {
    my ($hash) = @_;
    my $name     = $hash->{NAME};
    my $startMin = PoolControl_hm2min(AttrVal($name, "filterNightEnd", "06:00"));
    $startMin = 360 if (!defined $startMin);
    return strftime("%Y-%m-%d", localtime(time() - $startMin * 60));
}

# ============================================================================
# PoolControl_Control – die eigentliche Steuerlogik
# ============================================================================
sub PoolControl_Control {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    RemoveInternalTimer($hash);

    my $interval = AttrVal($name, "interval", 60);
    $interval = 60 if ($interval !~ /^\d+$/ || $interval < 5);

    # Bei Disable / deaktivierter Steuerung nur den Timer am Leben halten.
    if (IsDisabled($name) || ReadingsVal($name, "controlActive", "on") ne "on") {
        InternalTimer(gettimeofday() + $interval, "PoolControl_Control", $hash, 0);
        return undef;
    }

    $hash->{".inControl"} = 1;

    # --- Eingangswerte einlesen -------------------------------------------
    my $poolTemp   = PoolControl_num(AttrVal($name, "poolSensor",       ""), undef);
    my $inflowTemp = PoolControl_num(AttrVal($name, "inflowSensor",     ""), undef);
    my $index      = PoolControl_num(AttrVal($name, "solarIndexSensor", ""), 0);
    # Solltemperatur: per "set targetTemp" gepflegt; optional zeitabhängig über
    # targetTempSchedule überschrieben (z. B. tagsüber niedriger, abends höher).
    my $target     = ReadingsNum($name, "desiredTemperature", 30);
    my $tsched     = AttrVal($name, "targetTempSchedule", "");
    if ($tsched ne "") {
        my $st = PoolControl_scheduledTarget($tsched);
        $target = $st if (defined $st);
    }
    my $filterTgt  = AttrVal($name, "filterHours",  5) + 0;
    my $hpTemp     = AttrVal($name, "heatpumpTemp", 28) + 0;
    my $hpOffset   = AttrVal($name, "heatpumpOffset", 0.9) + 0;
    my $hpRegBand  = AttrVal($name, "heatpumpRegBand", 0.5) + 0;
    # Erwartete Einlauftemperatur, die die WP liefert. Bei voller Leistung
    # (Pool deutlich unter Sollwert) hebt sie das Wasser um heatpumpOffset über
    # die aktuelle Pooltemperatur. In Sollnähe regelt die Inverter-WP jedoch ab:
    # sie heizt nur noch bis ~heatpumpTemp + heatpumpRegBand. Der kleinere der
    # beiden Werte gilt. Nur sinnvoll mit Pool-Sensor.
    my $hpEff;
    if (defined $poolTemp) {
        my $hpFull = $poolTemp + $hpOffset;       # voller Hub
        my $hpCap  = $hpTemp   + $hpRegBand;       # Eigenregelung der WP
        $hpEff = ($hpFull < $hpCap) ? $hpFull : $hpCap;
    }
    my $hyst       = AttrVal($name, "solarHysteresis",       0.5) + 0;
    my $hystFilter = AttrVal($name, "solarHysteresisFilter", 0.1) + 0;
    my $wpRampTime = AttrVal($name, "heatpumpRampTime",      180) + 0;

    # Betriebsmodus: auto (Automatik), forceOn (Filter+WP zwangsweise heizen,
    # Solar bleibt automatisch), forceOff (Filter/Solar/WP zwangsweise aus).
    my $mode = ReadingsVal($name, "mode", "auto");

    # --- Schalter-/Statushelfer -------------------------------------------
    my $filterDev   = AttrVal($name, "filterSwitch", "");
    my $filterRd    = AttrVal($name, "filterStateReading", "state");
    my $filterOnRe  = AttrVal($name, "filterOnRegex", "on|ON|1");
    my $filterOnCmd = AttrVal($name, "filterOnCmd",  "on");
    my $filterOffCmd= AttrVal($name, "filterOffCmd", "off");

    my $solarDev    = AttrVal($name, "solarSwitch", "");
    my $solarRd     = AttrVal($name, "solarStateReading", "state");
    my $solarOnRe   = AttrVal($name, "solarOnRegex", "on|ON|1");
    my $solarOnCmd  = AttrVal($name, "solarOnCmd",  "on");
    my $solarOffCmd = AttrVal($name, "solarOffCmd", "off");

    my $hpDev    = AttrVal($name, "heatpumpSwitch", "");
    my $hpRd     = AttrVal($name, "heatpumpStateReading", "state");
    my $hpOnRe   = AttrVal($name, "heatpumpOnRegex", "on|ON|1");
    my $hpOnCmd  = AttrVal($name, "heatpumpOnCmd",  "on");
    my $hpOffCmd = AttrVal($name, "heatpumpOffCmd", "off");

    my $filterOn = PoolControl_isOn($filterDev, $filterRd, $filterOnRe);
    my $solarOn  = PoolControl_isOn($solarDev,  $solarRd,  $solarOnRe);
    my $wpOn     = PoolControl_isOn($hpDev,     $hpRd,     $hpOnRe);

    # --- WP-Anlaufphase verfolgen -----------------------------------------
    # Die WP braucht ~heatpumpRampTime (Default 180 s = 3 min) bis zur vollen
    # Leistung; in dieser Zeit bricht das einlaufende Solarwasser kurz ein. Den
    # Einschaltzeitpunkt festhalten, um den Auskühlschutz währenddessen
    # auszusetzen (sonst würde Solar fälschlich abgeschaltet).
    my $nowT = gettimeofday();
    if ($wpOn && !($hash->{".wpWasOn"} // 0)) {
        $hash->{".wpOnTime"} = $nowT;
    }
    $hash->{".wpWasOn"} = $wpOn ? 1 : 0;
    my $wpRamping = ($wpOn && ($nowT - ($hash->{".wpOnTime"} // 0)) < $wpRampTime)
                  ? 1 : 0;

    # --- Nutzbaren Solarhub für den Auskühlschutz bestimmen ---------------
    # Solar erwärmt das Wasser nur bei langsamer Strömung stark. Die geforderte
    # Mindest-Übertemperatur des Einlaufwassers über dem Pool hängt daher vom
    # Filterzustand ab:
    #   * Filter AUS (langsamer Solarkreis): großer Hub  -> solarHysteresis (0.5)
    #   * Filter AN  (schnelle Strömung):    kleiner Hub -> solarHysteresisFilter (0.1)
    # Läuft die WP, hebt sie das einlaufende Wasser auf die erwartete
    # WP-Temperatur (hpEff, s. o.); dieser Beitrag über dem Pool wird abgezogen,
    # damit nur die echte Solarwärme bewertet wird. In Sollnähe regelt die WP ab,
    # der Beitrag schrumpft daher von ~heatpumpOffset bis auf 0 (Pool am oberen
    # Rand des Regelbands).
    my $reqGain = $filterOn ? $hystFilter : $hyst;
    my $wpAdj   = ($wpOn && defined $hpEff && defined $poolTemp && $hpEff > $poolTemp)
                ? ($hpEff - $poolTemp) : 0;
    my $solarGain = (defined $inflowTemp && defined $poolTemp)
                  ? ($inflowTemp - $wpAdj - $poolTemp) : undef;

    # --- Filterlaufzeit des Tages mitführen -------------------------------
    PoolControl_accrueRuntime($hash, $filterOn);
    my $runtimeSec = $hash->{".runtimeSec"} // 0;
    my $remainSec  = $filterTgt * 3600 - $runtimeSec;
    $remainSec = 0 if ($remainSec < 0);

    my @reason;

    # --- Heizbedarf --------------------------------------------------------
    my $heatNeeded = 0;
    if (defined $poolTemp) {
        $heatNeeded = ($poolTemp < $target) ? 1 : 0;
    }
    else {
        push @reason, "kein Pooltemperatur-Sensor";
    }

    # ======================================================================
    # 1) Solarthermie – kostenlose Wärme, hat Vorrang. Mit Auskühlschutz.
    # ======================================================================
    my $solarState = "off";
    if ($solarDev ne "") {
        my $settle     = AttrVal($name, "solarSettleTime", 180) + 0;
        my $retryDelay = AttrVal($name, "solarRetryDelay", 1800) + 0;
        my $coldAfter  = AttrVal($name, "solarColdStartAfter", 14400) + 0;
        my $coldExtra  = AttrVal($name, "solarColdStartExtra", 180) + 0;
        my $now        = gettimeofday();

        # Zeitpunkt merken, an dem Solar zuletzt lief – Basis für die
        # Kaltstart-Erkennung weiter unten (Anlaufversuch).
        $hash->{".solarLastRunTime"} = $now if ($solarOn);

        # --- Solarfenster: Zeit + optionale Freigabe-Bedingung ------------
        # Ohne Kollektorfühler weiß das Modul nicht von selbst, ob Wärme vom
        # Dach kommt. Daher optional einschränken, wann ein Anlaufversuch
        # überhaupt erlaubt ist:
        #   * solarStartTime/solarEndTime: Zeitfenster (leer = ganztags).
        #   * solarEnable (<dev>:<reading>): externe Freigabe, z. B. PV-
        #     Überschuss (pooltrigger) oder Kollektortemperatur. Bei gesetztem
        #     solarEnableMin wird das Reading numerisch (>= Min) ausgewertet,
        #     sonst gegen solarEnableRegex (Default on|ON|1).
        my $solStart = AttrVal($name, "solarStartTime", "");
        my $solEnd   = AttrVal($name, "solarEndTime",   "");
        my $inSolarWindow = ($solStart ne "" && $solEnd ne "")
                          ? PoolControl_inWindow($solStart, $solEnd) : 1;

        my $solEnable = AttrVal($name, "solarEnable", "");
        my $solEnergyOk = 1;
        if ($solEnable ne "") {
            my $solEnMin = AttrVal($name, "solarEnableMin", "");
            if ($solEnMin ne "") {
                $solEnergyOk = (PoolControl_num($solEnable, 0) >= $solEnMin + 0)
                             ? 1 : 0;
            }
            else {
                my ($eDev, $eRd) = split(/:/, $solEnable, 2);
                $eRd = "state" if (!defined $eRd || $eRd eq "");
                my $eRe = AttrVal($name, "solarEnableRegex", "on|ON|1");
                $solEnergyOk = (defined $defs{$eDev}
                                && ReadingsVal($eDev, $eRd, "") =~ /$eRe/) ? 1 : 0;
            }
        }
        # "set solarCheck" setzt ein klebriges Force-Flag, das das Solarfenster
        # (Zeit + Freigabe) übergeht, bis Solar aus einem echten Grund abschaltet.
        my $forceCheck   = $hash->{".solarForceCheck"} // 0;
        my $solarAllowed = ($forceCheck || ($inSolarWindow && $solEnergyOk))
                         ? 1 : 0;

        if ($mode eq "forceOff") {
            # Zwangsabschaltung -> Solarpumpe aus.
            if ($solarOn) {
                PoolControl_switch($solarDev, $solarOffCmd);
            }
            delete $hash->{".solarForceCheck"};   # erzwungenen Lauf beenden
            $solarState = "off (force off)";
        }
        elsif (!$heatNeeded) {
            # Pool warm genug -> Solar aus.
            if ($solarOn) {
                PoolControl_switch($solarDev, $solarOffCmd);
                $solarState = "off (Soll erreicht)";
            }
            delete $hash->{".solarForceCheck"};   # erzwungenen Lauf beenden
        }
        elsif (!$solarAllowed) {
            # Außerhalb Solarfenster bzw. keine Solarenergie -> nicht anlaufen.
            if ($solarOn) {
                PoolControl_switch($solarDev, $solarOffCmd);
            }
            $solarState = !$inSolarWindow
                        ? "off (ausserhalb Solarfenster)"
                        : "off (keine Solarenergie)";
        }
        elsif ($solarOn) {
            my $onSince = $hash->{".solarOnTime"} // $now;
            if ($wpRamping) {
                # WP läuft gerade hoch -> Solarwasser bricht kurz ein, jetzt
                # nicht bewerten, Solar halten.
                $solarState = "on (WP-Anlauf)";
            }
            elsif (($now - $onSince) >= $settle + ($hash->{".solarSettleBonus"} // 0)) {
                # Auskühlschutz: der nutzbare Solarhub muss die (flussabhängige)
                # Schwelle erreichen. Nach einem Kaltstart (Solar lange aus,
                # ausgekühlter Solarkreis) läuft die Prüfphase um solarColdStartExtra
                # länger (.solarSettleBonus), damit warmes Wasser den inflowSensor
                # überhaupt erreicht, bevor bewertet wird.
                if (defined $solarGain && $solarGain < $reqGain) {
                    PoolControl_switch($solarDev, $solarOffCmd);
                    $hash->{".solarOffColdTime"} = $now;
                    delete $hash->{".solarForceCheck"}; # erzwungenen Lauf beenden
                    $solarState = "off (zu kalt, Auskuehlschutz)";
                }
                else {
                    $solarState = "on (heizt)";
                }
            }
            else {
                $solarState = "on (Pruefphase)";
            }
        }
        else {
            # Solar aus, Heizbedarf -> Anlaufversuch, sofern nicht gerade
            # wegen "zu kalt" abgeschaltet (Flatterschutz).
            my $offCold = $hash->{".solarOffColdTime"} // 0;
            if (($now - $offCold) >= $retryDelay) {
                PoolControl_switch($solarDev, $solarOnCmd);
                $hash->{".solarOnTime"} = $now;
                # Kaltstart-Erkennung: lief Solar seit mindestens
                # solarColdStartAfter (Default 4 h) nicht mehr, ist der
                # Solarkreis ausgekühlt -> für diesen ersten Lauf die
                # Prüfphase um solarColdStartExtra (Default 3 min) verlängern.
                # Sonst kein Bonus (0). Wird bei jedem echten Anlaufversuch neu
                # bestimmt, bleibt also nie veraltet stehen.
                my $idle = $now - ($hash->{".solarLastRunTime"} // 0);
                $hash->{".solarSettleBonus"} =
                    ($coldExtra > 0 && $idle >= $coldAfter) ? $coldExtra : 0;
                $solarState = "on (Anlaufversuch)";
            }
            else {
                $solarState = "off (Wartezeit nach Auskuehlung)";
            }
        }
    }
    my $solarActive = PoolControl_isOn($solarDev, $solarRd, $solarOnRe);
    # Heizt die Solarthermie real (nutzbarer Solarhub über der Schwelle)?
    # Während des WP-Anlaufs gilt sie als heizend (Bewertung ausgesetzt).
    my $solarHeating = ($solarActive
                        && ($wpRamping
                            || (defined $solarGain && $solarGain >= $reqGain)))
                       ? 1 : 0;

    # Bei Heizbedarf festhalten, warum die Solarthermie nicht heizt (Auskühl-
    # Sperre, außerhalb Solarfenster, keine Solarenergie …), damit lastDecision
    # zusammen mit der WP-Begründung den Zustand "keine Quelle" erklärt.
    if ($solarDev ne "" && $mode eq "auto" && $heatNeeded && !$solarHeating) {
        push @reason, "Solar heizt nicht: $solarState";
    }

    # ======================================================================
    # 2) Wärmepumpe (Inverter) – nur freigeben, Regelung macht die WP selbst.
    #    Freigabe: innerhalb des Zeitfensters und bei ausreichendem
    #    Solarindex (verfügbarer Stromüberschuss). Die Zieltemperatur wird der
    #    WP mitgeteilt (set heatpumpTemp -> heatpumpTempCmd); die WP moduliert
    #    ihre Leistung selbst und schaltet bei Erreichen der Temperatur ab.
    # ======================================================================
    my $wpState = "off";
    my $wpWant  = 0;
    if ($hpDev ne "") {
        my $wpStart  = AttrVal($name, "wpStartTime", "09:00");
        my $wpEnd    = AttrVal($name, "wpEndTime",   "22:00");

        # Solarindex-Hysterese: WP erst ab solarIndexOn freigeben und erst bei
        # solarIndexOff wieder sperren; dazwischen Zustand halten (kein Flattern
        # an der Schwelle). solarIndexMin dient als Rückfall-Default, solange
        # solarIndexOn/Off nicht gesetzt sind.
        my $idxOn  = AttrVal($name, "solarIndexOn",
                     AttrVal($name, "solarIndexMin", 1)) + 0;
        my $idxOff = AttrVal($name, "solarIndexOff", $idxOn) + 0;

        my $inWindow = PoolControl_inWindow($wpStart, $wpEnd);
        my $indexOk;
        if    ($index >= $idxOn)  { $indexOk = 1; }     # genug Überschuss -> ein
        elsif ($index <= $idxOff) { $indexOk = 0; }     # zu wenig -> aus
        else                      { $indexOk = $wpOn; } # Halteband -> halten

        # WP und Solarthermie arbeiten zusammen (beide sind sonnengesteuert):
        # die WP läuft also unabhängig von der Solarpumpe. Bei WP-Betrieb läuft
        # die Filterpumpe mit; der Solarhub wird dann an der kleineren, fluss-
        # abhängigen Schwelle (solarHysteresisFilter) bewertet.
        #
        # WP nur freigeben, wenn sie real etwas beitragen kann: Heizbedarf
        # besteht UND der Pool noch unter dem WP-Sollwert liegt (darüber regelt
        # die WP ohnehin ab). Sonst liefe die Filterpumpe sinnlos "für die WP"
        # weiter, obwohl der Pool sein Soll schon erreicht hat. Ohne Pool-Sensor
        # nicht blockieren (dann wie bisher nur Fenster + Index).
        my $wpHeatOk = (!defined $poolTemp)
                     || ($heatNeeded && $poolTemp < $hpTemp);

        # forceOn -> WP zwangsweise heizen (Gates übergehen), forceOff -> aus.
        if    ($mode eq "forceOn")  { $wpWant = 1; }
        elsif ($mode eq "forceOff") { $wpWant = 0; }
        else { $wpWant = ($inWindow && $indexOk && $wpHeatOk) ? 1 : 0; }

        if ($wpWant && !$wpOn) {
            PoolControl_switch($hpDev, $hpOnCmd);
            $wpState = ($mode eq "forceOn") ? "on (force on)" : "on";
        }
        elsif (!$wpWant && $wpOn) {
            PoolControl_switch($hpDev, $hpOffCmd);
            $wpState = "off";
        }
        else {
            $wpState = $wpOn ? "on" : "off";
        }

        # Begründung für den deaktivierten Zustand protokollieren (nur Automatik).
        if (!$wpWant && $mode eq "auto") {
            push @reason, "WP aus: ausserhalb Zeitfenster" if (!$inWindow);
            push @reason, "WP aus: Solarindex zu niedrig ($index, ein>=$idxOn/aus<=$idxOff)"
                if ($inWindow && !$indexOk);
            if ($inWindow && $indexOk && !$wpHeatOk) {
                push @reason, (defined $poolTemp && !$heatNeeded)
                    ? "WP aus: Soll erreicht"
                    : "WP aus: Pool >= WP-Sollwert ($hpTemp)";
            }
        }
    }
    my $wpActive = PoolControl_isOn($hpDev, $hpRd, $hpOnRe);

    # ======================================================================
    # 3) Filtersteuerung
    #    Der Filter läuft für die WP (braucht Filtergeschwindigkeit), für die
    #    Nachtfilterung und zum Umrühren – NICHT für die Solarthermie: Solar
    #    hat einen eigenen, langsamen Kreis und liefert nur bei abgeschaltetem
    #    Filter den vollen Temperaturhub. Solar-Laufzeit zählt daher auch nicht
    #    auf das Filtersoll; das Tagessoll wird allein über die Filterpumpe
    #    (tags WP-Betrieb, sonst nachts) erfüllt.
    # ======================================================================
    my $heatActive = ($solarActive || $wpActive) ? 1 : 0;

    my $nightStart = AttrVal($name, "filterNightStart", "22:00");
    my $nightEnd   = AttrVal($name, "filterNightEnd",   "06:00");
    my $inNight    = PoolControl_inWindow($nightStart, $nightEnd);
    my $nightFill  = ($inNight && $remainSec > 0) ? 1 : 0;

    # --- Manueller Filter-Override (set filter on|off) --------------------
    # Beim Eintritt ins Nachtfenster einmalig auf "auto" zurücksetzen, damit die
    # Nachtfilterung normal läuft und ein tagsüber gesetztes on/off nicht ewig
    # hängen bleibt. Eine manuelle Vorgabe *im* Nachtfenster bleibt bestehen.
    if ($inNight) {
        if (!($hash->{".manualNightCleared"} // 0)) {
            readingsSingleUpdate($hash, "filterManual", "auto", 1)
                if (ReadingsVal($name, "filterManual", "auto") ne "auto");
            $hash->{".manualNightCleared"} = 1;
        }
    }
    else {
        $hash->{".manualNightCleared"} = 0;
    }
    my $manual = ReadingsVal($name, "filterManual", "auto");

    # --- Umrühren / Durchmischung ----------------------------------------
    # Das von der Solarthermie erwärmte Wasser sammelt sich oben im Pool.
    # Damit sich die Wärme verteilt (und der Sensor nicht vorzeitig
    # "warm genug" meldet), wird nach erreichtem Soll periodisch zirkuliert.
    # Solange noch Heizbedarf besteht (Pool unter Soll), wird NICHT gemischt:
    # Zirkulieren ohne Wärmezufuhr verteilt nichts und kühlt über den
    # Umwälzverlust sogar leicht aus. (mixInterval = 0 schaltet das ab.)
    my $now2        = gettimeofday();
    my $mixInterval = AttrVal($name, "mixInterval",  3600) + 0;
    my $mixDuration = AttrVal($name, "mixDuration",  300)  + 0;

    # Solange der Filter (aus beliebigem Grund) läuft, wird ohnehin
    # durchmischt -> Mix-Timer zurücksetzen.
    $hash->{".mixLastRun"} = $now2 if ($filterOn);

    # Nur mischen, wenn das Soll erreicht ist (kein Heizbedarf). Ohne
    # Pooltemperatur-Sensor lässt sich das nicht beurteilen -> nicht mischen.
    my $mayMix    = (defined $poolTemp && !$heatNeeded) ? 1 : 0;
    my $mixActive = 0;
    if ($mixInterval > 0) {
        my $until = $hash->{".mixUntil"} // 0;
        if ($now2 < $until) {
            $mixActive = 1;                       # laufender Mix-Zyklus
        }
        elsif ($until > 0) {
            delete $hash->{".mixUntil"};          # Mix-Zyklus beendet
            $hash->{".mixLastRun"} = $now2;
        }
        # Neuen Mix-Zyklus starten, wenn fällig und nicht ohnehin gefiltert wird.
        my $last = $hash->{".mixLastRun"} // 0;
        if (!$mixActive && !$heatActive && !$nightFill && $mayMix
            && ($now2 - $last) >= $mixInterval) {
            $hash->{".mixUntil"} = $now2 + $mixDuration;
            $mixActive = 1;
        }
    }

    # Vorrang: forceOn/forceOff (mode) > manueller Override (set filter on|off) >
    # Automatik. Solar löst KEINE Filterung aus (eigener langsamer Kreis); der
    # Filter folgt dem WP-Wunsch (wpWant, damit beide im selben Zyklus starten),
    # der Nachtfilterung und dem Umrühren.
    my $wantFilter;
    if    ($mode eq "forceOn")   { $wantFilter = 1; }
    elsif ($mode eq "forceOff")  { $wantFilter = 0; }
    elsif ($manual eq "on")      { $wantFilter = 1; }
    elsif ($manual eq "off")     { $wantFilter = 0; }
    else { $wantFilter = ($wpWant || $nightFill || $mixActive) ? 1 : 0; }

    if ($filterDev ne "") {
        if ($wantFilter && !$filterOn) {
            PoolControl_switch($filterDev, $filterOnCmd);
            $hash->{".filterByModule"} = 1;
        }
        elsif (!$wantFilter && $filterOn
               && (($hash->{".filterByModule"} // 0)
                   || $mode eq "forceOff" || $manual eq "off")) {
            # Sonst nur abschalten, wenn das Modul den Filter selbst eingeschaltet
            # hat (manuelle Fremdschaltungen nicht überstimmen). Bei forceOff und
            # bei manuellem "off" jedoch immer abschalten.
            PoolControl_switch($filterDev, $filterOffCmd);
            $hash->{".filterByModule"} = 0;
        }
    }

    # Beschreibt die aktuelle Lage. Solar heizt mit abgeschaltetem Filter ->
    # erscheint als "Solar" obwohl der Filter aus ist; die WP heizt mit Filter.
    my $filterReason =
          $mode eq "forceOn"  ? "force on"
        : $mode eq "forceOff" ? "force off"
        : $manual eq "on"     ? "manuell an"
        : $manual eq "off"    ? "manuell aus"
        : ($wpActive && $solarHeating) ? "WP+Solar"
        : $wpActive     ? "WP"
        : $solarHeating ? "Solar"
        : $solarActive  ? "Solar (Anlauf)"
        : $nightFill    ? "Nachtfilterung"
        : $mixActive    ? "Umruehren"
        : $heatNeeded   ? "Heizbedarf, keine Quelle"
        :                 "kein Bedarf";

    # ======================================================================
    # 4) Wasserqualität (optional, informativ)
    # ======================================================================
    my $qualDev = AttrVal($name, "qualitySensor", "");
    my $qualTxt = "";
    if ($qualDev ne "" && defined $defs{$qualDev}) {
        my $ph  = ReadingsVal($qualDev, "PH",  "");
        my $orp = ReadingsVal($qualDev, "ORP", "");
        $qualTxt = "pH $ph / ORP $orp" if ($ph ne "" || $orp ne "");
    }

    # ======================================================================
    # Readings aktualisieren
    # ======================================================================
    my $runMin    = int($runtimeSec / 60 + 0.5);
    my $remainH   = sprintf("%.1f", $remainSec / 3600);
    my $poolTxt   = defined $poolTemp   ? sprintf("%.1f", $poolTemp)   : "?";
    my $inflowTxt = defined $inflowTemp ? sprintf("%.1f", $inflowTemp) : "?";

    my $modePrefix = ($mode ne "auto") ? "[$mode] " : "";
    my $stateTxt = sprintf("%sPool %s/Soll %.1f°C | Filter %s (%s) | %.1f/%sh",
        $modePrefix, $poolTxt, $target, ($wantFilter ? "on" : "off"),
        $filterReason, $runtimeSec / 3600, $filterTgt);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "poolTemp",            $poolTxt);
    readingsBulkUpdate($hash, "inflowTemp",          $inflowTxt);
    readingsBulkUpdate($hash, "targetTemp",          $target);
    readingsBulkUpdate($hash, "solarIndex",          $index);
    readingsBulkUpdate($hash, "heatingNeeded",       $heatNeeded ? "yes" : "no");
    readingsBulkUpdate($hash, "filterState",         $wantFilter ? "on" : "off");
    readingsBulkUpdate($hash, "filterReason",        $filterReason);
    readingsBulkUpdate($hash, "filterRuntimeToday",  $runMin);
    readingsBulkUpdate($hash, "filterRemaining",     $remainH);
    readingsBulkUpdate($hash, "mixState",            $mixActive ? "active" : "idle");
    readingsBulkUpdate($hash, "solarState",          $solarState);
    readingsBulkUpdate($hash, "solarHeating",        $solarHeating ? "yes" : "no");
    readingsBulkUpdate($hash, "heatpumpState",       $wpState);
    readingsBulkUpdate($hash, "heatpumpEffective",
        defined $hpEff ? sprintf("%.1f", $hpEff) : "?");
    readingsBulkUpdate($hash, "mode",                $mode);
    readingsBulkUpdate($hash, "quality",             $qualTxt) if ($qualTxt ne "");
    # Immer schreiben, damit Wert + Zeitstempel den aktuellen Zyklus zeigen und
    # kein alter Hinweis stehenbleibt; "-" wenn gerade nichts anzumerken ist.
    readingsBulkUpdate($hash, "lastDecision", @reason ? join("; ", @reason) : "-");
    readingsBulkUpdate($hash, "state",               $stateTxt);
    readingsEndUpdate($hash, 1);

    delete $hash->{".inControl"};

    InternalTimer(gettimeofday() + $interval, "PoolControl_Control", $hash, 0);
    return undef;
}

# ----------------------------------------------------------------------------
# PoolControl_accrueRuntime
#   Summiert die tägliche Filterlaufzeit; Reset um Mitternacht.
# ----------------------------------------------------------------------------
sub PoolControl_accrueRuntime {
    my ($hash, $filterOn) = @_;

    my $now   = gettimeofday();
    my $today = PoolControl_dayKey($hash);

    if (($hash->{".runtimeDate"} // "") ne $today) {
        $hash->{".runtimeDate"} = $today;
        $hash->{".runtimeSec"}  = 0;
        $hash->{".lastTick"}    = $now;
        $hash->{".filterWasOn"} = $filterOn;
        return;
    }

    my $last = $hash->{".lastTick"} // $now;
    if ($hash->{".filterWasOn"}) {
        my $delta = $now - $last;
        $delta = 0 if ($delta < 0);
        # Plausibilitätsgrenze (z. B. nach Neustart): max. 1 h pro Tick anrechnen.
        $delta = 3600 if ($delta > 3600);
        $hash->{".runtimeSec"} = ($hash->{".runtimeSec"} // 0) + $delta;
    }
    $hash->{".lastTick"}    = $now;
    $hash->{".filterWasOn"} = $filterOn;
    return;
}

# ----------------------------------------------------------------------------
# PoolControl_dumpConfig
#   Übersicht der konfigurierten Zuordnungen (get config).
# ----------------------------------------------------------------------------
sub PoolControl_dumpConfig {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $out  = "PoolControl '$name' Konfiguration:\n";
    for my $a (qw(poolSensor inflowSensor solarIndexSensor qualitySensor
                  filterSwitch solarSwitch heatpumpSwitch
                  solarStartTime solarEndTime solarEnable solarEnableMin
                  solarHysteresis solarHysteresisFilter
                  wpStartTime wpEndTime solarIndexMin solarIndexOn solarIndexOff
                  heatpumpOffset heatpumpRegBand heatpumpRampTime heatpumpTemp
                  filterNightStart filterNightEnd filterHours interval
                  targetTempSchedule)) {
        $out .= sprintf("  %-18s = %s\n", $a, AttrVal($name, $a, "(default)"));
    }
    $out .= sprintf("  %-18s = %s\n", "desiredTemperature", ReadingsVal($name, "desiredTemperature", "?"));
    return $out;
}

1;

=pod
=item device
=item summary    Steuerung von Poolfilterung und Poolheizung (Solar + Wärmepumpe)
=item summary_DE Steuerung von Poolfilterung und Poolheizung (Solar + Wärmepumpe)
=begin html

<a id="PoolControl"></a>
<h3>PoolControl</h3>
<ul>
  Steuert Filterung und Heizung eines Pools. Die Filterlaufzeit pro Tag wird
  vorgegeben; WP-Betrieb läuft auf Filtergeschwindigkeit und wird auf das
  Tagessoll angerechnet, der Rest wird nachts nachgefiltert. WP und Solarthermie
  sind beide sonnengesteuert und arbeiten zusammen; bei WP-Betrieb läuft der
  Filter mit. Solar selbst löst keine Filterung aus: läuft nur Solar (ohne WP),
  bleibt der Filter aus, damit der langsame Solarkreis seinen vollen
  Temperaturhub erreicht. Solar-Laufzeit zählt nicht auf das Filtersoll. Der
  Auskühlschutz schaltet die Solarpumpe ab, wenn der nutzbare Solarhub die
  (flussabhängige) Schwelle unterschreitet. Die Wärmepumpe läuft nur im
  Zeitfenster, bei ausreichendem Solarindex und solange Heizbedarf besteht
  (Pool unter Soll und unter WP-Sollwert); ist der Pool warm genug, bleibt mit
  der WP auch die Filterpumpe aus.
  <br><br>

  <a id="PoolControl-define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; PoolControl</code><br>
    Alle Ein- und Ausgänge werden über Attribute zugeordnet.
  </ul><br>

  <a id="PoolControl-set"></a>
  <b>Set</b>
  <ul>
    <li><a id="PoolControl-set-control"></a><b>control</b> on|off &ndash; Steuerung aktivieren/deaktivieren (off = Modul fasst nichts an)</li>
    <li><a id="PoolControl-set-mode"></a><b>mode</b> auto|forceOn|forceOff &ndash; Betriebsmodus. <code>forceOn</code>: Filterpumpe und Wärmepumpe werden zwangsweise eingeschaltet (heizt sofort, ohne Zeitfenster/Solarindex); die Solarthermie läuft weiter automatisch (mit Auskühlschutz). <code>forceOff</code>: Filter, Solarpumpe und Wärmepumpe werden zwangsweise abgeschaltet. <code>auto</code>: zurück zur Automatik.</li>
    <li><a id="PoolControl-set-filter"></a><b>filter</b> on|off|auto &ndash; manueller Filter-Override: <code>on</code> Filter zwangsweise an, <code>off</code> zwangsweise aus, <code>auto</code> zurück zur Automatik. Wird beim Beginn des Nachtfensters automatisch auf <code>auto</code> zurückgesetzt (damit die Nachtfilterung läuft). <code>mode forceOn/forceOff</code> hat Vorrang.</li>
    <li><a id="PoolControl-set-targetTemp"></a><b>targetTemp</b> &lt;°C&gt; &ndash; Solltemperatur (0,5er-Schritte). Wird vom Attribut <code>targetTempSchedule</code> überschrieben, falls gesetzt.</li>
    <li><a id="PoolControl-set-filterHours"></a><b>filterHours</b> &lt;h&gt; &ndash; gewünschte Filterstunden pro Tag. Schreibt das gleichnamige <b>Attribut</b> <code>filterHours</code> (überlebt Neustarts).</li>
    <li><a id="PoolControl-set-heatpumpTemp"></a><b>heatpumpTemp</b> &lt;°C&gt; &ndash; der Wärmepumpe mitgeteilte Zieltemperatur. Schreibt das gleichnamige <b>Attribut</b> <code>heatpumpTemp</code> (überlebt Neustarts) und reicht den Wert optional über <code>heatpumpTempCmd</code> an das WP-Gerät durch.</li>
    <li><a id="PoolControl-set-resetRuntime"></a><b>resetRuntime</b> &ndash; Tageslaufzeitzähler zurücksetzen</li>
    <li><a id="PoolControl-set-solarCheck"></a><b>solarCheck</b> &ndash; erzwingt eine sofortige, frische Solar-Prüfung. Im Unterschied zu <code>check</code> wird dabei die Auskühl-Sperre (<code>solarRetryDelay</code>, gesetzt nach <code>off (zu kalt, Auskuehlschutz)</code>) sowie der Prüfphasen-Timer verworfen, sodass die Solarpumpe unabhängig von der vorherigen Automatik-Entscheidung erneut einen Anlaufversuch macht. Zusätzlich wird das Solarfenster übergangen &ndash; also das Zeitfenster <code>solarStartTime</code>/<code>solarEndTime</code> und die externe Freigabe <code>solarEnable</code> &ndash;, sodass der Check <b>auch ausserhalb des Solarfensters</b> läuft. Die Übergehung bleibt bestehen (überdauert die folgenden Automatik-Zyklen), damit der Auskühlschutz die volle <code>solarSettleTime</code> zum Messen hat; sie wird aufgehoben, sobald Solar aus einem echten Grund abschaltet (<code>off (zu kalt, Auskuehlschutz)</code>, <code>off (Soll erreicht)</code>, <code>off (force off)</code>). Nützlich, wenn die Sonne wieder klar auf den Kollektor scheint, das Modul aber noch in der Wartezeit nach der letzten Auskühlung oder ausserhalb des Zeitfensters steht. (Der Heizbedarf gilt weiterhin: ist der Pool warm genug, läuft Solar nicht an.)</li>
    <li><a id="PoolControl-set-check"></a><b>check</b> &ndash; Steuerzyklus sofort ausführen (respektiert die laufenden Sperren; für einen erzwungenen Solar-Neustart <code>solarCheck</code> verwenden)</li>
  </ul><br>

  <a id="PoolControl-get"></a>
  <b>Get</b>
  <ul>
    <li><a id="PoolControl-get-config"></a><b>config</b> &ndash; aktuelle Zuordnungen anzeigen</li>
  </ul><br>

  <a id="PoolControl-attr"></a>
  <b>Attribute</b>
  <ul>
    <p><b>Sensoren (Format <code>&lt;Gerät&gt;:&lt;Reading&gt;</code>)</b></p>
    <li><a id="PoolControl-attr-poolSensor"></a><b>poolSensor</b><br>
        Typ: textField. Pool-Wassertemperatur.</li>
    <li><a id="PoolControl-attr-inflowSensor"></a><b>inflowSensor</b><br>
        Typ: textField. Temperatur des einlaufenden Wassers (gemeinsamer Rücklauf von Solar und WP).</li>
    <li><a id="PoolControl-attr-solarIndexSensor"></a><b>solarIndexSensor</b><br>
        Typ: textField. Solarindex (verfügbarer Stromüberschuss) für die WP-Freigabe.</li>
    <li><a id="PoolControl-attr-qualitySensor"></a><b>qualitySensor</b><br>
        Typ: textField. Optionaler Wasserqualitätssensor (z. B. BLEYC01), nur informativ.</li>

    <p><b>Filterpumpe</b></p>
    <li><a id="PoolControl-attr-filterSwitch"></a><b>filterSwitch</b><br>
        Typ: textField. Schaltgerät der Filterpumpe.</li>
    <li><a id="PoolControl-attr-filterStateReading"></a><b>filterStateReading</b><br>
        Typ: textField. Reading, das den Pumpenzustand führt (Default <code>state</code>).</li>
    <li><a id="PoolControl-attr-filterOnRegex"></a><b>filterOnRegex</b><br>
        Typ: textField. Regex, der den Ein-Zustand erkennt (Default <code>on|ON|1</code>).</li>
    <li><a id="PoolControl-attr-filterOnCmd"></a><b>filterOnCmd</b><br>
        Typ: textField. set-Kommando zum Einschalten (Default <code>on</code>).</li>
    <li><a id="PoolControl-attr-filterOffCmd"></a><b>filterOffCmd</b><br>
        Typ: textField. set-Kommando zum Ausschalten (Default <code>off</code>).</li>
    <li><a id="PoolControl-attr-filterNightStart"></a><b>filterNightStart</b><br>
        Typ: textField (HH:MM). Beginn des Nachtfilterfensters (Default 22:00).</li>
    <li><a id="PoolControl-attr-filterNightEnd"></a><b>filterNightEnd</b><br>
        Typ: textField (HH:MM). Ende des Nachtfilterfensters; hier wechselt auch der Filtertag (Default 06:00).</li>
    <li><a id="PoolControl-attr-filterHours"></a><b>filterHours</b><br>
        Typ: Slider (0–24 h). Gewünschte Filterstunden pro Tag (Default 5). Wird auch per <code>set filterHours</code> gesetzt; als Attribut gespeichert, damit es Neustarts übersteht.</li>

    <p><b>Umrühren / Durchmischung</b></p>
    <li>Umgerührt wird nur, wenn das Soll erreicht ist (kein Heizbedarf), um die
        oben gesammelte Wärme zu verteilen. Bei Heizbedarf wird nicht gemischt.</li>
    <li><a id="PoolControl-attr-mixInterval"></a><b>mixInterval</b><br>
        Typ: Slider (0–7200 s). Mindestabstand zwischen Mix-Zyklen ohne Zirkulation; 0 = aus (Default 3600).</li>
    <li><a id="PoolControl-attr-mixDuration"></a><b>mixDuration</b><br>
        Typ: Slider (0–1800 s). Dauer eines Mix-Zyklus (Default 300).</li>

    <p><b>Solarthermie</b></p>
    <li><a id="PoolControl-attr-solarSwitch"></a><b>solarSwitch</b><br>
        Typ: textField. Schaltgerät der Solarthermie-Pumpe.</li>
    <li><a id="PoolControl-attr-solarStateReading"></a><b>solarStateReading</b><br>
        Typ: textField. Reading des Pumpenzustands (Default <code>state</code>).</li>
    <li><a id="PoolControl-attr-solarOnRegex"></a><b>solarOnRegex</b><br>
        Typ: textField. Regex für den Ein-Zustand (Default <code>on|ON|1</code>).</li>
    <li><a id="PoolControl-attr-solarOnCmd"></a><b>solarOnCmd</b><br>
        Typ: textField. set-Kommando zum Einschalten (Default <code>on</code>).</li>
    <li><a id="PoolControl-attr-solarOffCmd"></a><b>solarOffCmd</b><br>
        Typ: textField. set-Kommando zum Ausschalten (Default <code>off</code>).</li>
    <li><a id="PoolControl-attr-solarHysteresis"></a><b>solarHysteresis</b><br>
        Typ: Slider (0–5 °C). Geforderte Mindest-Übertemperatur des Einlaufwassers über dem Pool, wenn der Filter <b>aus</b> ist (langsamer Solarkreis, großer Hub; Default 0.5).</li>
    <li><a id="PoolControl-attr-solarHysteresisFilter"></a><b>solarHysteresisFilter</b><br>
        Typ: Slider (0–5 °C). Geforderte Mindest-Übertemperatur, wenn der Filter <b>läuft</b> (schnelle Strömung, kleiner Hub; Default 0.1).</li>
    <li><a id="PoolControl-attr-solarSettleTime"></a><b>solarSettleTime</b><br>
        Typ: Slider (0–1800 s). Wartezeit nach Solar-Anlauf vor der Auskühlschutz-Prüfung; deckt die Umlaufzeit des Solarkreises ab (~2 min; Default 180).</li>
    <li><a id="PoolControl-attr-solarRetryDelay"></a><b>solarRetryDelay</b><br>
        Typ: Slider (0–7200 s). Sperrzeit nach Abschaltung wegen Auskühlung (Default 1800). Ein <code>set solarCheck</code> hebt diese Sperre einmalig auf und erzwingt einen sofortigen Anlaufversuch.</li>
    <li><a id="PoolControl-attr-solarColdStartAfter"></a><b>solarColdStartAfter</b><br>
        Typ: Slider (0–86400 s). Kaltstart-Schwelle: lief die Solarpumpe seit mindestens dieser Zeit nicht mehr, ist der Solarkreis ausgekühlt und der nächste Anlaufversuch gilt als Kaltstart (Default 14400 = 4 h). Dann wird die Prüfphase einmalig um <code>solarColdStartExtra</code> verlängert.</li>
    <li><a id="PoolControl-attr-solarColdStartExtra"></a><b>solarColdStartExtra</b><br>
        Typ: Slider (0–1800 s). Zusätzliche Wartezeit vor der Auskühlschutz-Prüfung beim ersten Anlauf nach einem Kaltstart (Default 180 = 3 min), damit warmes Wasser aus dem ausgekühlten Solarkreis den <code>inflowSensor</code> erreicht, bevor bewertet wird. Kommt zur <code>solarSettleTime</code> hinzu; nur für diesen ersten Lauf. 0 = deaktiviert.</li>
    <li><a id="PoolControl-attr-solarStartTime"></a><b>solarStartTime</b><br>
        Typ: textField (HH:MM). Beginn des Zeitfensters, in dem ein Solar-Anlaufversuch erlaubt ist (leer = ganztags).</li>
    <li><a id="PoolControl-attr-solarEndTime"></a><b>solarEndTime</b><br>
        Typ: textField (HH:MM). Ende des Solar-Zeitfensters (leer = ganztags).</li>
    <li><a id="PoolControl-attr-solarEnable"></a><b>solarEnable</b><br>
        Typ: textField (<code>&lt;dev&gt;:&lt;reading&gt;</code>). Optionale externe Freigabe für Solar (z. B. PV-Überschuss oder Kollektortemperatur). Ohne <code>solarEnableMin</code> wird gegen <code>solarEnableRegex</code> geprüft, sonst numerisch (&ge; Min).</li>
    <li><a id="PoolControl-attr-solarEnableRegex"></a><b>solarEnableRegex</b><br>
        Typ: textField. Regex für die Freigabe bei boolschem Reading (Default <code>on|ON|1</code>).</li>
    <li><a id="PoolControl-attr-solarEnableMin"></a><b>solarEnableMin</b><br>
        Typ: textField. Mindestwert für die Freigabe bei numerischem Reading (z. B. Watt oder °C); leer = Regex-Auswertung.</li>

    <p><b>Wärmepumpe</b></p>
    <li><a id="PoolControl-attr-heatpumpSwitch"></a><b>heatpumpSwitch</b><br>
        Typ: textField. Schaltgerät der Wärmepumpe.</li>
    <li><a id="PoolControl-attr-heatpumpStateReading"></a><b>heatpumpStateReading</b><br>
        Typ: textField. Reading des WP-Zustands (Default <code>state</code>).</li>
    <li><a id="PoolControl-attr-heatpumpOnRegex"></a><b>heatpumpOnRegex</b><br>
        Typ: textField. Regex für den Ein-Zustand (Default <code>on|ON|1</code>).</li>
    <li><a id="PoolControl-attr-heatpumpOnCmd"></a><b>heatpumpOnCmd</b><br>
        Typ: textField. set-Kommando zum Einschalten (Default <code>on</code>).</li>
    <li><a id="PoolControl-attr-heatpumpOffCmd"></a><b>heatpumpOffCmd</b><br>
        Typ: textField. set-Kommando zum Ausschalten (Default <code>off</code>).</li>
    <li><a id="PoolControl-attr-heatpumpTemp"></a><b>heatpumpTemp</b><br>
        Typ: Slider (10–40 °C). Der Wärmepumpe mitgeteilte Zieltemperatur (Default 28). Wird auch per <code>set heatpumpTemp</code> gesetzt (reicht den Wert dann über <code>heatpumpTempCmd</code> an das WP-Gerät durch); als Attribut gespeichert, damit es Neustarts übersteht.</li>
    <li><a id="PoolControl-attr-heatpumpOffset"></a><b>heatpumpOffset</b><br>
        Typ: Slider (0–5 °C). Temperaturhub der WP über der aktuellen Pooltemperatur bei voller Leistung (bei Filtergeschwindigkeit ~0,8 °C, daher etwas höher als Toleranz wählen); wird im Auskühlschutz vom Einlaufwasser abgezogen und bestimmt die erwartete Einlauftemperatur <code>heatpumpEffective</code>. Zu niedrig gewählt würde Solar fälschlich als heizend gelten und Wärme über den kalten Kollektor verloren gehen (Default 0.9).</li>
    <li><a id="PoolControl-attr-heatpumpRegBand"></a><b>heatpumpRegBand</b><br>
        Typ: Slider (0–5 °C). Regelband der Inverter-WP: sie regelt zwischen <code>heatpumpTemp</code> und <code>heatpumpTemp + heatpumpRegBand</code> herunter und heizt nicht darüber hinaus. Begrenzt die erwartete Einlauftemperatur in Sollnähe (<code>heatpumpEffective = min(poolTemp + heatpumpOffset, heatpumpTemp + heatpumpRegBand)</code>) und damit den im Auskühlschutz abgezogenen WP-Beitrag (Default 0.5).</li>
    <li><a id="PoolControl-attr-heatpumpRampTime"></a><b>heatpumpRampTime</b><br>
        Typ: Slider (0–1800 s). Anlaufzeit der WP bis zur vollen Leistung; in dieser Zeit bricht das Solarwasser kurz ein, daher wird der Auskühlschutz währenddessen ausgesetzt (Default 180).</li>
    <li><a id="PoolControl-attr-heatpumpTempCmd"></a><b>heatpumpTempCmd</b><br>
        Typ: textField. set-Kommando, mit dem die mitgeteilte Temperatur an das WP-Gerät durchgereicht wird (z. B. <code>temperatur</code>).</li>
    <li><a id="PoolControl-attr-wpStartTime"></a><b>wpStartTime</b><br>
        Typ: textField (HH:MM). Beginn des WP-Zeitfensters (Default 09:00).</li>
    <li><a id="PoolControl-attr-wpEndTime"></a><b>wpEndTime</b><br>
        Typ: textField (HH:MM). Ende des WP-Zeitfensters (Default 22:00).</li>
    <li><a id="PoolControl-attr-solarIndexMin"></a><b>solarIndexMin</b><br>
        Typ: textField. Mindest-Solarindex für WP-Betrieb; Rückfall-Default, wenn <code>solarIndexOn</code> nicht gesetzt ist (Default 1).</li>
    <li><a id="PoolControl-attr-solarIndexOn"></a><b>solarIndexOn</b><br>
        Typ: textField. Solarindex, ab dem die WP freigegeben wird (Einschaltschwelle der Hysterese).</li>
    <li><a id="PoolControl-attr-solarIndexOff"></a><b>solarIndexOff</b><br>
        Typ: textField. Solarindex, bei dem die WP wieder gesperrt wird; dazwischen wird der Zustand gehalten (Ausschaltschwelle, Default = <code>solarIndexOn</code>).</li>

    <p><b>Allgemein</b></p>
    <li><a id="PoolControl-attr-targetTempSchedule"></a><b>targetTempSchedule</b><br>
        Typ: textField. Zeitabhängige Solltemperatur als Liste von <code>HH:MM Temp</code>-Paaren
        (z. B. <code>00:00 32 16:00 33.5</code>). Es gilt jeweils der zuletzt erreichte Eintrag;
        vor dem ersten Eintrag des Tages der späteste (Umlauf über Mitternacht). Überschreibt die
        per <code>set targetTemp</code> gesetzte <code>desiredTemperature</code>. Leer = keine
        Zeitsteuerung. Sinnvoll z. B. tagsüber niedriger (Sonne heizt nach), abends höher.</li>
    <li><a id="PoolControl-attr-interval"></a><b>interval</b><br>
        Typ: textField. Steuerintervall in Sekunden (Default 60).</li>
    <li><a id="PoolControl-attr-disable"></a><b>disable</b> 0|1<br>
        Steuerung anhalten.</li>
  </ul><br>

  <a id="PoolControl-readings"></a>
  <b>Readings</b>
  <ul>
    <p><b>Sollwerte / Betrieb</b> (per <code>set</code> gepflegt)</p>
    <li><b>controlActive</b> &ndash; on|off: ob die Steuerung aktiv ist (<code>set control</code>).</li>
    <li><b>mode</b> &ndash; auto|forceOn|forceOff: aktueller Betriebsmodus (<code>set mode</code>).</li>
    <li><b>filterManual</b> &ndash; on|off|auto: manueller Filter-Override (<code>set filter</code>); wird nachts automatisch auf <code>auto</code> zurückgesetzt.</li>
    <li><b>desiredTemperature</b> &ndash; eingestellte Solltemperatur in °C (<code>set targetTemp</code>).</li>
    <li>Hinweis: <code>filterHours</code> und <code>heatpumpTemp</code> sind jetzt <b>Attribute</b> (nicht mehr Readings), damit sie Neustarts überstehen.</li>

    <p><b>Messwerte</b></p>
    <li><b>poolTemp</b> &ndash; aktuelle Pool-Wassertemperatur in °C (aus <code>poolSensor</code>; <code>?</code> wenn kein Sensor).</li>
    <li><b>inflowTemp</b> &ndash; Temperatur des einlaufenden Wassers in °C (aus <code>inflowSensor</code>).</li>
    <li><b>targetTemp</b> &ndash; aktuell wirksame Solltemperatur in °C (entspricht <code>desiredTemperature</code>).</li>
    <li><b>solarIndex</b> &ndash; aktueller Solarindex (verfügbarer Stromüberschuss) aus <code>solarIndexSensor</code>.</li>
    <li><b>heatingNeeded</b> &ndash; yes|no: besteht Heizbedarf (<code>poolTemp &lt; targetTemp</code>)?</li>

    <p><b>Filter / Umrühren</b></p>
    <li><b>filterState</b> &ndash; on|off: vom Modul gewünschter Filterzustand.</li>
    <li><b>filterReason</b> &ndash; Begründung des Filterzustands: <code>WP+Solar</code>, <code>WP</code>,
        <code>Solar</code> (Filter dabei bewusst aus), <code>Solar (Anlauf)</code>, <code>Nachtfilterung</code>,
        <code>Umruehren</code>, <code>Heizbedarf, keine Quelle</code>, <code>kein Bedarf</code> bzw.
        <code>force on</code>/<code>force off</code> im Handbetrieb.</li>
    <li><b>filterRuntimeToday</b> &ndash; heutige Filterlaufzeit in Minuten (Tageswechsel bei <code>filterNightEnd</code>).</li>
    <li><b>filterRemaining</b> &ndash; heute noch fehlende Filterzeit in Stunden.</li>
    <li><b>mixState</b> &ndash; active|idle: läuft gerade ein Umrühr-Zyklus?</li>

    <p><b>Solarthermie</b></p>
    <li><b>solarState</b> &ndash; Zustand/Begründung der Solarpumpe, z. B. <code>on (heizt)</code>,
        <code>on (Pruefphase)</code>, <code>on (WP-Anlauf)</code>, <code>off (zu kalt, Auskuehlschutz)</code>,
        <code>off (Wartezeit nach Auskuehlung)</code>, <code>off (ausserhalb Solarfenster)</code>,
        <code>off (keine Solarenergie)</code>, <code>off (Soll erreicht)</code>.</li>
    <li><b>solarHeating</b> &ndash; yes|no: heizt die Solarthermie real (nutzbarer Solarhub über der flussabhängigen Schwelle bzw. WP-Anlaufphase)?</li>

    <p><b>Wärmepumpe</b></p>
    <li><b>heatpumpState</b> &ndash; Zustand der WP-Freigabe: <code>off</code>, <code>on</code>,
        <code>on (force on)</code>.</li>
    <li><b>heatpumpEffective</b> &ndash; erwartete Einlauftemperatur der WP in °C:
        <code>min(poolTemp + heatpumpOffset, heatpumpTemp + heatpumpRegBand)</code> –
        voller Hub über dem Pool, in Sollnähe durch die Eigenregelung der WP gedeckelt.
        Vergleich mit <code>inflowTemp</code> zeigt, ob die WP wie erwartet liefert
        (<code>?</code> ohne Pool-Sensor).</li>

    <p><b>Sonstige</b></p>
    <li><b>quality</b> &ndash; Wasserqualität als <code>pH &lt;x&gt; / ORP &lt;y&gt;</code> (nur wenn <code>qualitySensor</code> Werte liefert).</li>
    <li><b>lastDecision</b> &ndash; Klartext-Begründung des aktuellen Zyklus (z. B. warum WP/Solar nicht laufen); <code>-</code>, wenn nichts anzumerken ist. Wird jeden Zyklus aktualisiert (kein veralteter Hinweis).</li>
    <li><b>state</b> &ndash; Kurzüberblick: <code>[Modus] Pool x/Soll y°C | Filter on/off (Grund) | Laufzeit/Soll h</code>.</li>
  </ul>
</ul>

=end html
=cut
