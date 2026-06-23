##############################################################################
# 98_PoolControl.pm
#
# FHEM-Modul zur Steuerung von Poolfilterung und Poolheizung.
#
# Funktionen:
#   * Filterung: Vorgabe der gewünschten Filterstunden pro Tag. Heizbetrieb
#     (Solarthermie / Wärmepumpe) zirkuliert das Wasser ohnehin und wird auf
#     das Tagessoll angerechnet. Fehlt am Tagesende noch Laufzeit, wird in
#     einem konfigurierbaren Nachtfenster nachgefiltert. Der Filtertag wechselt
#     am Ende des Nachtfensters (filterNightEnd), damit das Nachfiltern über
#     Mitternacht hinweg demselben Tag zugerechnet wird.
#   * Solltemperatur (desiredTemperature) einstellbar.
#   * Solarthermie mit Auskühlschutz: Beim Anlaufen wird nach einer Settle-Zeit
#     geprüft, ob das einlaufende Wasser (inflowSensor) wärmer ist als der Pool.
#     Ist es kälter, wird die Solarpumpe wieder abgeschaltet, damit der Pool
#     nicht auskühlt. Anlaufversuche lassen sich optional auf ein Zeitfenster
#     (solarStartTime/solarEndTime) und eine externe Freigabe (solarEnable,
#     z. B. PV-Überschuss oder Kollektortemperatur) einschränken, damit die
#     Pumpe nachts/ohne Sonne nicht sinnlos taktet.
#   * Wärmepumpe (Inverter, regelt selbst): Das Modul gibt die WP nur frei
#     (Zeitfenster wpStartTime/wpEndTime und ausreichender Solarindex) und teilt
#     ihr die Zieltemperatur mit. Der Solarindex (verfügbarer Stromüberschuss)
#     wirkt mit Hysterese: Freigabe ab solarIndexOn, Sperre bei solarIndexOff,
#     dazwischen Zustand halten. Die Leistungsregelung übernimmt die WP selbst.
#   * Optionaler Wasserqualitätssensor (z. B. BLEYC01). Da dieser instabil
#     laufen kann, ist er optional und blockiert die Steuerung nicht.
#
# Das Modul steuert ausschließlich über konfigurierbare Fremdgeräte (per
# Attribut) und hält keine eigene Hardware. Alle Ein-/Ausgänge sind über
# Attribute frei zuordenbar.
#
# Autor:    ahlers2mi
# Version:  v0.8.1
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
        . "solarSettleTime:slider,0,30,1800 "
        . "solarRetryDelay:slider,0,60,7200 "
        . "circulationLoss:slider,0,0.1,5 "
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
        . "heatpumpOffset:slider,0,0.1,5 "
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
    $hash->{VERSION} = "0.8.1";

    # Defaultwerte für die per "set" gepflegten Sollwerte anlegen,
    # falls noch keine Readings existieren.
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "controlActive",
        ReadingsVal($name, "controlActive", "on"));
    readingsBulkUpdate($hash, "mode",
        ReadingsVal($name, "mode", "auto"));
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
        . "mode:auto,forceOn,forceOff "
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
    elsif ($cmd eq "mode") {
        my $v = $args[0] // "";
        return "mode needs auto|forceOn|forceOff"
            if ($v !~ /^(auto|forceOn|forceOff)$/);
        readingsSingleUpdate($hash, "mode", $v, 1);
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
        $hash->{".runtimeDate"} = PoolControl_dayKey($hash);
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
    my $target     = ReadingsNum($name, "desiredTemperature", 30);
    my $filterTgt  = ReadingsNum($name, "filterHoursTarget",  0);
    my $hpTemp     = ReadingsNum($name, "heatpumpTemp",       0);
    my $hpOffset   = AttrVal($name, "heatpumpOffset", 0.5) + 0;
    my $hpEff      = $hpTemp + $hpOffset;
    my $circLoss   = AttrVal($name, "circulationLoss", 0.3) + 0;
    my $hysteresis = AttrVal($name, "solarHysteresis", 0.5) + 0;

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

    # --- Einlaufwasser für den Auskühlschutz korrigieren ------------------
    # Der gemeinsame Rücklauf (inflowSensor) wird von Solar UND WP gespeist und
    # verliert beim Umwälzen Wärme. Damit der Auskühlschutz nur die echte
    # Solarwärme bewertet, wird das Einlaufwasser korrigiert:
    #   * WP an und Pool unter WP-Sollwert -> WP heizt aktiv, hebt das Wasser um
    #     ~heatpumpOffset; diesen Beitrag abziehen.
    #   * WP an, Pool darüber -> Inverter-WP regelt ab, kein Abzug.
    #   * WP aus -> nur Umwälzverlust (circulationLoss, ~0,3°); als Toleranz
    #     wieder draufrechnen, sonst würde Solar fälschlich abgeschaltet.
    my $inflowAdj;
    if ($wpOn) {
        $inflowAdj = (defined $poolTemp && $poolTemp <= $hpTemp) ? -$hpOffset : 0;
    }
    else {
        $inflowAdj = $circLoss;
    }
    my $inflowEff  = defined $inflowTemp ? ($inflowTemp + $inflowAdj) : undef;

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
        my $solarAllowed = ($inSolarWindow && $solEnergyOk) ? 1 : 0;

        if ($mode eq "forceOff") {
            # Zwangsabschaltung -> Solarpumpe aus.
            if ($solarOn) {
                PoolControl_switch($solarDev, $solarOffCmd);
            }
            $solarState = "off (force off)";
        }
        elsif (!$heatNeeded) {
            # Pool warm genug -> Solar aus.
            if ($solarOn) {
                PoolControl_switch($solarDev, $solarOffCmd);
                $solarState = "off (Soll erreicht)";
            }
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
            if (($now - $onSince) >= $settle) {
                # Auskühlschutz: einlaufendes Wasser (ohne WP-Beitrag) muss
                # wärmer sein als der Pool.
                if (defined $inflowEff && defined $poolTemp
                    && $inflowEff <= ($poolTemp + $hysteresis)) {
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
    # Heizt die Solarthermie real (Einlaufwasser ohne WP-Beitrag wärmer als Pool)?
    my $solarHeating = ($solarActive && defined $inflowEff && defined $poolTemp
                        && $inflowEff > ($poolTemp + $hysteresis)) ? 1 : 0;

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

        # forceOn -> WP zwangsweise heizen (Gates übergehen), forceOff -> aus.
        my $wpWant;
        if    ($mode eq "forceOn")  { $wpWant = 1; }
        elsif ($mode eq "forceOff") { $wpWant = 0; }
        else { $wpWant = ($inWindow && $indexOk) ? 1 : 0; }

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

    # forceOn -> Filter zwangsweise an, forceOff -> aus, sonst Automatik.
    my $wantFilter;
    if    ($mode eq "forceOn")  { $wantFilter = 1; }
    elsif ($mode eq "forceOff") { $wantFilter = 0; }
    else { $wantFilter = ($heatActive || $nightFill || $mixActive) ? 1 : 0; }

    if ($filterDev ne "") {
        if ($wantFilter && !$filterOn) {
            PoolControl_switch($filterDev, $filterOnCmd);
            $hash->{".filterByModule"} = 1;
        }
        elsif (!$wantFilter && $filterOn
               && (($hash->{".filterByModule"} // 0) || $mode eq "forceOff")) {
            # Sonst nur abschalten, wenn das Modul den Filter selbst eingeschaltet
            # hat (manuelle Schaltungen nicht überstimmen). Bei forceOff jedoch
            # immer abschalten.
            PoolControl_switch($filterDev, $filterOffCmd);
            $hash->{".filterByModule"} = 0;
        }
    }

    my $filterReason =
          $mode eq "forceOn"  ? "force on"
        : $mode eq "forceOff" ? "force off"
        : $heatActive ? ($solarActive && $wpActive ? "Solar+WP"
                       : $solarActive ? "Solar" : "WP")
        : $nightFill  ? "Nachtfilterung"
        : $mixActive  ? "Umruehren"
        : $heatNeeded ? "Heizbedarf, keine Quelle"
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
    readingsBulkUpdate($hash, "heatpumpEffective",   sprintf("%.1f", $hpEff));
    readingsBulkUpdate($hash, "mode",                $mode);
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
                  wpStartTime wpEndTime solarIndexMin solarIndexOn solarIndexOff
                  heatpumpOffset
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
=item device
=item summary    Steuerung von Poolfilterung und Poolheizung (Solar + Wärmepumpe)
=item summary_DE Steuerung von Poolfilterung und Poolheizung (Solar + Wärmepumpe)
=begin html

<a id="PoolControl"></a>
<h3>PoolControl</h3>
<ul>
  Steuert Filterung und Heizung eines Pools. Die Filterlaufzeit pro Tag wird
  vorgegeben; Heizbetrieb (Solarthermie/Wärmepumpe) wird auf das Tagessoll
  angerechnet und der Rest nachts nachgefiltert. Die Solarthermie wird mit
  Auskühlschutz betrieben (Abschaltung, wenn das einlaufende Wasser kälter ist
  als der Pool). Die Wärmepumpe läuft nur im Zeitfenster und bei ausreichendem
  Solarindex.
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
    <li><a id="PoolControl-set-targetTemp"></a><b>targetTemp</b> &lt;°C&gt; &ndash; Solltemperatur (0,5er-Schritte)</li>
    <li><a id="PoolControl-set-filterHours"></a><b>filterHours</b> &lt;h&gt; &ndash; gewünschte Filterstunden pro Tag</li>
    <li><a id="PoolControl-set-heatpumpTemp"></a><b>heatpumpTemp</b> &lt;°C&gt; &ndash; der Wärmepumpe mitgeteilte Temperatur (wird optional über <code>heatpumpTempCmd</code> durchgereicht)</li>
    <li><a id="PoolControl-set-resetRuntime"></a><b>resetRuntime</b> &ndash; Tageslaufzeitzähler zurücksetzen</li>
    <li><a id="PoolControl-set-check"></a><b>check</b> &ndash; Steuerzyklus sofort ausführen</li>
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
        Typ: Slider (0–5 °C). Mindest-Übertemperatur des Einlaufwassers gegenüber dem Pool (Default 0.5).</li>
    <li><a id="PoolControl-attr-solarSettleTime"></a><b>solarSettleTime</b><br>
        Typ: Slider (0–1800 s). Wartezeit nach Solar-Anlauf vor der Auskühlschutz-Prüfung (Default 180).</li>
    <li><a id="PoolControl-attr-solarRetryDelay"></a><b>solarRetryDelay</b><br>
        Typ: Slider (0–7200 s). Sperrzeit nach Abschaltung wegen Auskühlung (Default 1800).</li>
    <li><a id="PoolControl-attr-circulationLoss"></a><b>circulationLoss</b><br>
        Typ: Slider (0–5 °C). Wärmeverlust beim Umwälzen, wenn die WP aus ist; wird im Auskühlschutz als Toleranz auf das Einlaufwasser addiert (Default 0.3).</li>
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
    <li><a id="PoolControl-attr-heatpumpOffset"></a><b>heatpumpOffset</b><br>
        Typ: Slider (0–5 °C). Mehrtemperatur der WP über ihrem Sollwert; wird im Auskühlschutz vom Einlaufwasser abgezogen (solange Pool &le; <code>heatpumpTemp</code>) und fließt in <code>heatpumpEffective</code> ein (Default 0.5).</li>
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
    <li><a id="PoolControl-attr-interval"></a><b>interval</b><br>
        Typ: textField. Steuerintervall in Sekunden (Default 60).</li>
    <li><a id="PoolControl-attr-disable"></a><b>disable</b> 0|1<br>
        Steuerung anhalten.</li>
  </ul>
</ul>

=end html
=cut
