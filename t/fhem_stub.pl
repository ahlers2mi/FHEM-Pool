#!/usr/bin/perl
#
# Minimaler FHEM-Ersatz, damit 98_PoolControl.pm ohne laufende FHEM-Instanz
# getestet werden kann. Wird von den .t-Dateien per require geladen und lädt
# selbst das Modul.
#
# Warum ein Stub und kein echtes FHEM: die Steuerlogik ist reine
# Entscheidungslogik über Readings/Attribute und Uhrzeit. Genau die lässt sich
# hier deterministisch durchspielen - inklusive Uhrzeiten, die man in einer
# echten Instanz nur durch Warten erreicht.
#
# Zwei Fallstricke, die hier gelöst sind:
#  * Die Uhr muss simulierbar sein. PoolControl_inWindow ruft ein
#    argumentloses localtime auf - das umgeht eine reine time()-Überschreibung,
#    daher werden BEIDE abgefangen (und zwar in einem BEGIN-Block, damit die
#    Überschreibung steht, bevor das Modul kompiliert wird).
#  * Das Modul wird per do() geladen; es hat kein "package", die Subs landen
#    also in main und sind danach direkt aufrufbar.

use strict;
use warnings;
use POSIX qw(strftime);

BEGIN {
    *CORE::GLOBAL::time      = sub { defined $main::NOW ? $main::NOW : CORE::time() };
    *CORE::GLOBAL::localtime = sub {
        return CORE::localtime(@_ ? $_[0]
                               : (defined $main::NOW ? $main::NOW : CORE::time()));
    };
}

our (%defs, %attr, $init_done, $readingFnAttributes, $NOW);
our @SWITCHED;              # Protokoll aller per fhem() gesendeten Befehle
our $DEVICE = "poolControl";

$init_done           = 1;
$readingFnAttributes = "";

# --- von fhem.pl bereitgestellte Funktionen ---------------------------------
sub Log3 { }
sub AttrVal {
    my ($n, $a, $d) = @_;
    return (exists $attr{$n} && defined $attr{$n}{$a} && $attr{$n}{$a} ne "")
        ? $attr{$n}{$a} : $d;
}
sub ReadingsVal {
    my ($n, $r, $d) = @_;
    return $d if (!exists $defs{$n} || !exists $defs{$n}{READINGS}{$r});
    return $defs{$n}{READINGS}{$r}{VAL};
}
sub ReadingsNum {
    my ($n, $r, $d) = @_;
    my $v = ReadingsVal($n, $r, $d);
    return (defined $v && $v =~ /^-?[\d.]+$/) ? $v + 0 : $d;
}
sub gettimeofday       { return defined $NOW ? $NOW : CORE::time(); }
sub InternalTimer      { }
sub RemoveInternalTimer{ }
sub readingsBeginUpdate{ }
sub readingsEndUpdate  { }
sub readingsBulkUpdate   { my ($h,$r,$v)=@_; $h->{READINGS}{$r}{VAL}=$v; }
sub readingsSingleUpdate { my ($h,$r,$v)=@_; $h->{READINGS}{$r}{VAL}=$v; }
sub readingsDelete       { my ($h,$r)=@_;    delete $h->{READINGS}{$r}; }
sub CommandAttr { my (undef,$s)=@_; my ($n,$a,$v)=split(/ /,$s,3); $attr{$n}{$a}=$v; }
sub IsDisabled  { return 0; }
sub fhem {
    my ($c) = @_;
    push @SWITCHED, $c;
    # Schaltbefehl auf dem Stub-Gerät nachziehen, damit die Folgezyklen den
    # neuen Zustand sehen (wie in FHEM).
    if ($c =~ /^set (\S+) (\S+)$/ && exists $defs{$1}) {
        $defs{$1}{READINGS}{state}{VAL} = $2;
    }
}

# --- Modul laden ------------------------------------------------------------
my $modul = __FILE__;
$modul =~ s{/[^/]+$}{};                       # t/
$modul .= "/../FHEM/98_PoolControl.pm";
do $modul or die "Konnte $modul nicht laden: " . ($@ || $!) . "\n";

# ---------------------------------------------------------------------------
# Testhilfen
# ---------------------------------------------------------------------------
our $FAILS = 0;
our $OKS   = 0;

sub ok {
    my ($cond, $text) = @_;
    printf("%-5s %s\n", $cond ? "ok" : "FAIL", $text);
    $cond ? $OKS++ : $FAILS++;
    return $cond ? 1 : 0;
}

sub done {
    printf("\n%d ok, %d FAILED\n", $OKS, $FAILS);
    exit($FAILS ? 1 : 0);
}

# Uhrzeit "HH:MM" des heutigen Tages als Epoch (Datum von der echten Uhr).
sub at_time {
    my ($hm) = @_;
    my ($H, $M) = split(/:/, $hm);
    my @t = CORE::localtime(CORE::time());
    return POSIX::mktime(0, $M + 0, $H + 0, $t[3], $t[4], $t[5]);
}

# Standard-Anlage aufbauen. Optionen überschreiben Messwerte/Zustände:
#   pool inflow index target             - Messwerte / Solltemperatur
#   filterOn solarOn wpOn                - Ist-Zustand der Schaltgeräte
#   mode manual heating readOnly         - Betriebsart / Saisonschalter
sub setup_pool {
    my (%o) = @_;
    my $N = $DEVICE;
    @SWITCHED = ();
    %defs = ();
    %attr = ();

    $defs{p_temp}   = {NAME=>"p_temp",   READINGS=>{temperature=>{VAL=>$o{pool}   // 18}}};
    $defs{i_temp}   = {NAME=>"i_temp",   READINGS=>{temperature=>{VAL=>$o{inflow} // 18}}};
    $defs{d_idx}    = {NAME=>"d_idx",    READINGS=>{index=>{VAL=>$o{index} // 0}}};
    $defs{d_filter} = {NAME=>"d_filter", READINGS=>{state=>{VAL=>$o{filterOn} ? "on" : "off"}}};
    $defs{d_solar}  = {NAME=>"d_solar",  READINGS=>{state=>{VAL=>$o{solarOn}  ? "on" : "off"}}};
    $defs{d_wp}     = {NAME=>"d_wp",     READINGS=>{state=>{VAL=>$o{wpOn}     ? "on" : "off"}}};

    $defs{$N} = {NAME=>$N, READINGS=>{
        controlActive      => {VAL=>"on"},
        mode               => {VAL=>$o{mode}   // "auto"},
        filter             => {VAL=>$o{manual} // "auto"},
        desiredTemperature => {VAL=>$o{target} // 30},
    }};

    $attr{$N} = {
        poolSensor       => "p_temp:temperature",
        inflowSensor     => "i_temp:temperature",
        solarIndexSensor => "d_idx:index",
        filterSwitch     => "d_filter",
        solarSwitch      => "d_solar",
        heatpumpSwitch   => "d_wp",
        filterNightStart => "22:00",
        filterNightEnd   => "06:00",
        filterHours      => 3,
        mixInterval      => 3600,
        mixDuration      => 300,
        solarStartTime   => "11:00",
        solarEndTime     => "20:30",
        wpStartTime      => "09:00",
        wpEndTime        => "19:00",
        heatpumpTemp     => 31,
        solarIndexOn     => 8,
        solarIndexOff    => 3,
    };
    $attr{$N}{heating}          = $o{heating}  if (defined $o{heating});
    $attr{$N}{heatpumpReadOnly} = $o{readOnly} if (defined $o{readOnly});

    my $h = $defs{$N};
    # Tageszähler als "heute, noch nichts gefiltert"; Wiederherstellung aus dem
    # Statefile ist nicht Gegenstand dieser Szenarien (siehe 01_restore.t).
    $h->{".runtimeSec"}  = 0;
    $h->{".runtimeDate"} = PoolControl_dayKey($h);
    $h->{".restoreDone"} = 1;
    return $h;
}

# Steuerzyklen zur Uhrzeit $hm laufen lassen (je Tick +60 s).
sub run_at {
    my ($h, $hm, $ticks) = @_;
    $ticks //= 1;
    for my $i (1 .. $ticks) {
        $NOW = at_time($hm) + ($i - 1) * 60;
        PoolControl_Control($h);
    }
    return ReadingsVal($DEVICE, "filterState", "?");
}

sub rd { return ReadingsVal($DEVICE, $_[0], ""); }
sub switched { return grep { $_ eq $_[0] } @SWITCHED; }

1;
