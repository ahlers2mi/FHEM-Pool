##############################################################################
# 98_PoolControl.pm
#
# FHEM-Modul zur Steuerung von Poolfilterung und Poolheizung.
#
# Funktionen:
#   * Filterung: Vorgabe der gewünschten Filterstunden pro Tag. Heizbetrieb
#     (Solarthermie / Wärmepumpe) zirkuliert das Wasser ohnehin und wird auf
#     das Tagessoll angerechnet. Fehlt am Tagesende noch Laufzeit, wird in
#     einem konfigurierbaren Nachtfenster nachgefiltert.
#   * Solltemperatur (desiredTemperature) einstellbar.
#   * Solarthermie mit Auskühlschutz: Beim Anlaufen wird nach einer Settle-Zeit
#     geprüft, ob das einlaufende Wasser (inflowSensor) wärmer ist als der Pool.
#     Ist es kälter, wird die Solarpumpe wieder abgeschaltet, damit der Pool
#     nicht auskühlt.
#   * Wärmepumpe (übergangsweise nicht direkt regelbar): Es kann eine
#     Wärmepumpentemperatur mitgeteilt werden. Die WP heizt typ. etwas über
#     dem eingestellten Wert (heatpumpOffset, Default 0,5 °C). Die WP läuft nur
#     innerhalb eines Zeitfensters (wpStartTime/wpEndTime) und nur, wenn der
#     Solarindex (verfügbarer Stromüberschuss) ausreicht (solarIndexMin).
#   * Optionaler Wasserqualitätssensor (z. B. BLEYC01). Da dieser instabil
#     laufen kann, ist er optional und blockiert die Steuerung nicht.
#
# Das Modul steuert ausschließlich über konfigurierbare Fremdgeräte (per
# Attribut) und hält keine eigene Hardware. Alle Ein-/Ausgänge sind über
# Attribute frei zuordenbar.
#
# Autor:    ahlers2mi
# Version:  v0.1.0
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
        . "interval "
        # --- Sensoren (Format: <Gerät>:<Reading>) ---
        . "poolSensor "
        . "inflowSensor "
        . "solarIndexSensor "
        . "qualitySensor "
        # --- Filterpumpe ---
        . "filterSwitch "
        . "filterStateReading "
        . "filterOnRegex "
        . "filterOnCmd "
        . "filterOffCmd "
        . "filterNightStart "
        . "filterNightEnd "
        # --- Solarthermie ---
        . "solarSwitch "
        . "solarStateReading "
        . "solarOnRegex "
        . "solarOnCmd "
        . "solarOffCmd "
        . "solarHysteresis "
        . "solarSettleTime "
        . "solarRetryDelay "
        # --- Wärmepumpe ---
        . "heatpumpSwitch "
        . "heatpumpStateReading "
        . "heatpumpOnRegex "
        . "heatpumpOnCmd "
        . "heatpumpOffCmd "
        . "heatpumpOffset "
        . "heatpumpTempCmd "
        . "wpStartTime "
        . "wpEndTime "
        . "solarIndexMin "
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
    $hash->{VERSION} = "0.1.0";

    # Defaultwerte für die per "set" gepflegten Sollwerte anlegen,
    # falls noch keine Readings existieren.
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "controlActive",
        ReadingsVal($name, "controlActive", "on"));
    readingsBulkUpdate($hash, "desiredTemperature",
        ReadingsVal($name, "desiredTemperature", 30));
    readingsBulkUpdate($hash, "filterHoursTarget",
        ReadingsVal($name, "filterHoursTarget", 5));
    readingsBulkUpdate($hash, "heatpumpTemp",
        ReadingsVal($name, "heatpumpTemp", 28));
    readingsEndUpdate($hash, 0);

    PoolControl_setNotifyDev($hash);

    # Erste Steuerung kurz nach dem Start (Geräte müssen geladen sein).
    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday() + 5, "PoolControl_Control", $hash, 0)
        if ($init_done);

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
        . "targetTemp:slider,10,0.5,40 "
        . "filterHours:slider,0,0.5,24 "
        . "heatpumpTemp:slider,10,0.5,40 "
        . "resetRuntime:noArg "
        . "check:noArg";

    if ($cmd eq "control") {
        my $v = $args[0] // "";
        return "control needs on|off" if ($v ne "on" && $v ne "off");
        readingsSingleUpdate($hash, "controlActive", $v, 1);
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
        readingsSingleUpdate($hash, "filterHoursTarget", $args[0] + 0, 1);
        PoolControl_Control($hash);
        return undef;
    }
    elsif ($cmd eq "heatpumpTemp") {
        return "heatpumpTemp needs a number" if (!defined $args[0] || $args[0] !~ /^[\d.]+$/);
        readingsSingleUpdate($hash, "heatpumpTemp", $args[0] + 0, 1);

        # Wert optional an das WP-Gerät durchreichen (z. B. set d_pool_wp temperatur <x>)
        my $hp     = AttrVal($name, "heatpumpSwitch", "");
        my $tmpcmd = AttrVal($name, "heatpumpTempCmd", "");
        if ($hp ne "" && $tmpcmd ne "" && defined $defs{$hp}) {
            fhem("set $hp $tmpcmd " . ($args[0] + 0));
        }
        PoolControl_Control($hash);
        return undef;
    }
    elsif ($cmd eq "resetRuntime") {
        $hash->{".runtimeSec"}  = 0;
        $hash->{".runtimeDate"} = strftime("%Y-%m-%d", localtime);
        readingsSingleUpdate($hash, "filterRuntimeToday", 0, 1);
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
                     filterSwitch solarSwitch heatpumpSwitch)) {
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
    my $target     = ReadingsNum($name, "desiredTemperature", 30);
    my $filterTgt  = ReadingsNum($name, "filterHoursTarget",  0);
    my $hpTemp     = ReadingsNum($name, "heatpumpTemp",       0);
    my $hpOffset   = AttrVal($name, "heatpumpOffset", 0.5) + 0;
    my $hpEff      = $hpTemp + $hpOffset;
    my $hysteresis = AttrVal($name, "solarHysteresis", 0.5) + 0;

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
        my $now        = gettimeofday();

        if (!$heatNeeded) {
            # Pool warm genug -> Solar aus.
            if ($solarOn) {
                PoolControl_switch($solarDev, $solarOffCmd);
                $solarState = "off (Soll erreicht)";
            }
        }
        elsif ($solarOn) {
            my $onSince = $hash->{".solarOnTime"} // $now;
            if (($now - $onSince) >= $settle) {
                # Auskühlschutz: einlaufendes Wasser muss wärmer sein als Pool.
                if (defined $inflowTemp && defined $poolTemp
                    && $inflowTemp <= ($poolTemp + $hysteresis)) {
                    PoolControl_switch($solarDev, $solarOffCmd);
                    $hash->{".solarOffColdTime"} = $now;
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
                $solarState = "on (Anlaufversuch)";
            }
            else {
                $solarState = "off (Wartezeit nach Auskuehlung)";
            }
        }
    }
    my $solarActive = PoolControl_isOn($solarDev, $solarRd, $solarOnRe);
    # Heizt die Solarthermie real (warmes Einlaufwasser)?
    my $solarHeating = ($solarActive && defined $inflowTemp && defined $poolTemp
                        && $inflowTemp > ($poolTemp + $hysteresis)) ? 1 : 0;

    # ======================================================================
    # 2) Wärmepumpe – nur im Zeitfenster und bei ausreichendem Solarindex.
    #    Läuft ergänzend, wenn die Solarthermie nicht (ausreichend) heizt.
    # ======================================================================
    my $wpState = "off";
    if ($hpDev ne "") {
        my $wpStart  = AttrVal($name, "wpStartTime", "09:00");
        my $wpEnd    = AttrVal($name, "wpEndTime",   "22:00");
        my $indexMin = AttrVal($name, "solarIndexMin", 1) + 0;

        my $inWindow = PoolControl_inWindow($wpStart, $wpEnd);
        my $indexOk  = ($index >= $indexMin) ? 1 : 0;
        # WP heizt nur, solange Pool unter Soll UND unter der (effektiven)
        # WP-Zieltemperatur liegt.
        my $wpTempOk = (defined $poolTemp && $poolTemp < $hpEff) ? 1 : 0;

        my $wpWant = ($heatNeeded && $inWindow && $indexOk && $wpTempOk
                      && !$solarHeating) ? 1 : 0;

        if ($wpWant && !$wpOn) {
            PoolControl_switch($hpDev, $hpOnCmd);
            $wpState = "on";
        }
        elsif (!$wpWant && $wpOn) {
            PoolControl_switch($hpDev, $hpOffCmd);
            $wpState = "off";
        }
        else {
            $wpState = $wpOn ? "on" : "off";
        }

        # Begründung für den deaktivierten Zustand protokollieren.
        if (!$wpWant) {
            push @reason, "WP aus: ausserhalb Zeitfenster"      if (!$inWindow && $heatNeeded);
            push @reason, "WP aus: Solarindex zu niedrig ($index<$indexMin)"
                if ($inWindow && !$indexOk && $heatNeeded);
            push @reason, "WP aus: Solar heizt bereits"          if ($solarHeating && $heatNeeded);
        }
    }
    my $wpActive = PoolControl_isOn($hpDev, $hpRd, $hpOnRe);

    # ======================================================================
    # 3) Filtersteuerung – Heizbetrieb wird angerechnet, Rest nachts.
    # ======================================================================
    my $heatActive = ($solarActive || $wpActive) ? 1 : 0;

    my $nightStart = AttrVal($name, "filterNightStart", "22:00");
    my $nightEnd   = AttrVal($name, "filterNightEnd",   "06:00");
    my $inNight    = PoolControl_inWindow($nightStart, $nightEnd);
    my $nightFill  = ($inNight && $remainSec > 0) ? 1 : 0;

    my $wantFilter = ($heatActive || $nightFill) ? 1 : 0;

    if ($filterDev ne "") {
        if ($wantFilter && !$filterOn) {
            PoolControl_switch($filterDev, $filterOnCmd);
            $hash->{".filterByModule"} = 1;
        }
        elsif (!$wantFilter && $filterOn && ($hash->{".filterByModule"} // 0)) {
            # Nur abschalten, wenn das Modul den Filter selbst eingeschaltet hat
            # (manuelle Schaltungen nicht überstimmen).
            PoolControl_switch($filterDev, $filterOffCmd);
            $hash->{".filterByModule"} = 0;
        }
    }

    my $filterReason =
          $heatActive ? ($solarActive && $wpActive ? "Solar+WP"
                       : $solarActive ? "Solar" : "WP")
        : $nightFill  ? "Nachtfilterung"
        :               "kein Bedarf";

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

    my $stateTxt = sprintf("Pool %s/Soll %.1f°C | Filter %s (%s) | %.1f/%sh",
        $poolTxt, $target, ($wantFilter ? "on" : "off"),
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
    readingsBulkUpdate($hash, "solarState",          $solarState);
    readingsBulkUpdate($hash, "solarHeating",        $solarHeating ? "yes" : "no");
    readingsBulkUpdate($hash, "heatpumpState",       $wpState);
    readingsBulkUpdate($hash, "heatpumpEffective",   sprintf("%.1f", $hpEff));
    readingsBulkUpdate($hash, "quality",             $qualTxt) if ($qualTxt ne "");
    readingsBulkUpdate($hash, "lastDecision",        join("; ", @reason)) if (@reason);
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
    my $today = strftime("%Y-%m-%d", localtime($now));

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
                  wpStartTime wpEndTime solarIndexMin heatpumpOffset
                  filterNightStart filterNightEnd interval)) {
        $out .= sprintf("  %-18s = %s\n", $a, AttrVal($name, $a, "(default)"));
    }
    $out .= sprintf("  %-18s = %s\n", "desiredTemperature", ReadingsVal($name, "desiredTemperature", "?"));
    $out .= sprintf("  %-18s = %s\n", "filterHoursTarget",  ReadingsVal($name, "filterHoursTarget",  "?"));
    $out .= sprintf("  %-18s = %s\n", "heatpumpTemp",       ReadingsVal($name, "heatpumpTemp",       "?"));
    return $out;
}

1;

=pod
=item summary    Steuerung von Poolfilterung und Poolheizung (Solar + Wärmepumpe)
=item summary_DE Steuerung von Poolfilterung und Poolheizung (Solar + Wärmepumpe)
=begin html

<a name="PoolControl"></a>
<h3>PoolControl</h3>
<ul>
  Steuert Filterung und Heizung eines Pools. Die Filterlaufzeit pro Tag wird
  vorgegeben; Heizbetrieb (Solarthermie/Wärmepumpe) wird auf das Tagessoll
  angerechnet und der Rest nachts nachgefiltert. Die Solarthermie wird mit
  Auskühlschutz betrieben (Abschaltung, wenn das einlaufende Wasser kälter ist
  als der Pool). Die Wärmepumpe läuft nur im Zeitfenster und bei ausreichendem
  Solarindex.
  <br><br>

  <a name="PoolControldefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; PoolControl</code><br>
    Alle Ein- und Ausgänge werden über Attribute zugeordnet.
  </ul><br>

  <a name="PoolControlset"></a>
  <b>Set</b>
  <ul>
    <li><b>control</b> on|off &ndash; Steuerung aktivieren/deaktivieren</li>
    <li><b>targetTemp</b> &lt;°C&gt; &ndash; Solltemperatur</li>
    <li><b>filterHours</b> &lt;h&gt; &ndash; gewünschte Filterstunden pro Tag</li>
    <li><b>heatpumpTemp</b> &lt;°C&gt; &ndash; der Wärmepumpe mitgeteilte Temperatur</li>
    <li><b>resetRuntime</b> &ndash; Tageslaufzeitzähler zurücksetzen</li>
    <li><b>check</b> &ndash; Steuerzyklus sofort ausführen</li>
  </ul><br>

  <a name="PoolControlget"></a>
  <b>Get</b>
  <ul>
    <li><b>config</b> &ndash; aktuelle Zuordnungen anzeigen</li>
  </ul><br>

  <a name="PoolControlattr"></a>
  <b>Attribute</b>
  <ul>
    <li><b>poolSensor</b> &lt;dev&gt;:&lt;reading&gt; &ndash; Pool-Wassertemperatur</li>
    <li><b>inflowSensor</b> &lt;dev&gt;:&lt;reading&gt; &ndash; Temperatur des einlaufenden Wassers</li>
    <li><b>solarIndexSensor</b> &lt;dev&gt;:&lt;reading&gt; &ndash; Solarindex (Stromüberschuss)</li>
    <li><b>qualitySensor</b> &lt;dev&gt; &ndash; optionaler Wasserqualitätssensor (z. B. BLEYC01)</li>
    <li><b>filterSwitch</b>, <b>filterStateReading</b>, <b>filterOnRegex</b>, <b>filterOnCmd</b>, <b>filterOffCmd</b> &ndash; Filterpumpe</li>
    <li><b>filterNightStart</b>, <b>filterNightEnd</b> &ndash; Nachtfilterfenster (Default 22:00&ndash;06:00)</li>
    <li><b>solarSwitch</b>, <b>solarStateReading</b>, <b>solarOnRegex</b>, <b>solarOnCmd</b>, <b>solarOffCmd</b> &ndash; Solarthermie-Pumpe</li>
    <li><b>solarHysteresis</b> &ndash; Mindest-Übertemperatur des Einlaufwassers (Default 0.5)</li>
    <li><b>solarSettleTime</b> &ndash; Wartezeit nach Solar-Anlauf vor Auskühlschutz-Prüfung (Sekunden, Default 180)</li>
    <li><b>solarRetryDelay</b> &ndash; Sperrzeit nach Abschaltung wegen Auskühlung (Sekunden, Default 1800)</li>
    <li><b>heatpumpSwitch</b>, <b>heatpumpStateReading</b>, <b>heatpumpOnRegex</b>, <b>heatpumpOnCmd</b>, <b>heatpumpOffCmd</b> &ndash; Wärmepumpe</li>
    <li><b>heatpumpOffset</b> &ndash; Mehrtemperatur der WP gegenüber Sollwert (Default 0.5)</li>
    <li><b>heatpumpTempCmd</b> &ndash; set-Kommando, mit dem die mitgeteilte Temperatur an das WP-Gerät durchgereicht wird (z. B. <code>temperatur</code>)</li>
    <li><b>wpStartTime</b>, <b>wpEndTime</b> &ndash; Zeitfenster der Wärmepumpe (Default 09:00&ndash;22:00)</li>
    <li><b>solarIndexMin</b> &ndash; Mindest-Solarindex für WP-Betrieb (Default 1)</li>
    <li><b>interval</b> &ndash; Steuerintervall in Sekunden (Default 60)</li>
    <li><b>disable</b> 0|1</li>
  </ul>
</ul>

=end html
=cut
