#!/usr/bin/perl
#
# Tageslaufzeit über einen FHEM-Neustart hinweg (PoolControl_restoreState).
#
# Hintergrund: Internals ($hash->{...}) schreibt FHEM nicht ins Statefile,
# Readings dagegen schon. Lag der Zähler nur im Internal, begann er nach jedem
# Neustart bei 0 und der Filter arbeitete das komplette Tagessoll erneut ab.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Absoluter Pfad: require mit relativem Pfad wuerde in @INC suchen.
# (require braucht dafuer einen Skalar, keinen Ausdruck.)
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;

our (%defs, %attr, $NOW, $DEVICE);
my $N = $DEVICE;

# Gerät nur mit den Readings aufbauen, die aus dem Statefile kämen.
sub after_restart {
    my (%o) = @_;
    %defs = ($N => {NAME=>$N, READINGS=>{}});
    %attr = ($N => {filterNightEnd => "06:00", filterHours => 3});
    my $r = $defs{$N}{READINGS};
    $r->{filterRuntimeToday} = {VAL=>$o{minutes}} if (defined $o{minutes});
    $r->{filterRuntimeDay}   = {VAL=>$o{day}}     if (defined $o{day});
    $r->{filterState}        = {VAL=>$o{filterState} // "off"};
    return $defs{$N};
}

$NOW = at_time("13:00");
my $today  = PoolControl_dayKey({NAME=>$N});

print "=== Neustart am selben Zaehltag: Laufzeit wird uebernommen ===\n";
my $h = after_restart(minutes=>135, day=>$today);
PoolControl_restoreState($h);
ok(($h->{".runtimeSec"} // -1) == 135*60,
   "135 min uebernommen (".($h->{".runtimeSec"} // "undef")." s)");
ok(($h->{".runtimeDate"} // "") eq $today, "Zaehltag gesetzt");
ok(!$h->{".filterByModule"}, "keine Filter-Eigentuemerschaft (filterState off)");
my $remain = 3*3600 - $h->{".runtimeSec"};
ok(abs($remain - 2700) < 1, "Restlaufzeit 0,75 h statt 3 h");

print "\n=== Neustart an einem anderen Zaehltag: bei 0 beginnen ===\n";
$h = after_restart(minutes=>135, day=>"2020-01-01", filterState=>"on");
PoolControl_restoreState($h);
ok(!defined $h->{".runtimeSec"}, "alter Zaehltag -> nichts uebernommen");
ok($h->{".filterByModule"}, "filterState on -> Modul darf Filter abschalten");

print "\n=== Altbestand ohne filterRuntimeDay ===\n";
$h = after_restart(minutes=>135);
PoolControl_restoreState($h);
ok(!defined $h->{".runtimeSec"}, "ohne Zaehltag-Reading -> nichts uebernommen");

print "\n=== Zweiter Aufruf (Timer + Steuerlauf) zaehlt nicht doppelt ===\n";
$h = after_restart(minutes=>60, day=>$today);
PoolControl_restoreState($h);
my $first = $h->{".runtimeSec"};
$h->{".runtimeSec"} += 300;               # ein Steuerlauf verbucht 5 min
PoolControl_restoreState($h);             # zweiter Aufruf
ok($h->{".runtimeSec"} == $first + 300, "zweiter Aufruf ueberschreibt nicht");

print "\n=== defmod im Betrieb: laufender Zaehler bleibt ===\n";
$h = after_restart(minutes=>60, day=>$today);
$h->{".runtimeSec"}  = 9999;
$h->{".runtimeDate"} = $today;
PoolControl_restoreState($h);
ok($h->{".runtimeSec"} == 9999, "laufender Zaehler unangetastet");

print "\n=== Verbuchung zaehlt ab uebernommenem Stand weiter ===\n";
$h = after_restart(minutes=>100, day=>$today, filterState=>"on");
PoolControl_restoreState($h);
PoolControl_accrueRuntime($h, 1);         # erster Tick nach dem Neustart
$h->{".lastTick"} -= 120;                 # 2 min simulieren
PoolControl_accrueRuntime($h, 1);
ok(abs($h->{".runtimeSec"} - (100*60 + 120)) < 2,
   "zaehlt weiter (".int($h->{".runtimeSec"})." s)");

done();
