#!/usr/bin/perl
#
# Steuerlogik-Szenarien: PoolControl_Control wird komplett ausgefuehrt.
# Schwerpunkt Saisonbetrieb (heating on|off), Umruehren und die nicht
# fernsteuerbare Waermepumpe (heatpumpReadOnly).

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Absoluter Pfad: require mit relativem Pfad wuerde in @INC suchen.
# (require braucht dafuer einen Skalar, keinen Ausdruck.)
my $stub = dirname(abs_path(__FILE__)) . "/fhem_stub.pl";
require $stub;

our (%defs, %attr, $NOW, $DEVICE, @SWITCHED);
my ($h, $st);

print "=== Kuenstlich tiefes Soll: fuehrt zum Umruehren (Ausgangsfehler) ===\n";
# Soll 5 Grad heisst fuer das Modul "Soll erreicht" -> Umruehr-Bedingung.
# Mit vorher gelaufener Waermequelle wird deshalb gemischt.
$h = setup_pool(pool=>18, target=>5);
$h->{".heatSinceMix"} = 1;
$h->{".mixLastRun"}   = at_time("13:00") - 7200;
$st = run_at($h, "13:00");
ok($st eq "on", "Umruehren startet -> Filter $st");
ok(rd("filterReason") eq "Umruehren", "Grund: ".rd("filterReason"));

print "\n=== ...aber nicht ohne vorher gelaufene Waermequelle ===\n";
$h = setup_pool(pool=>18, target=>5);
delete $h->{".heatSinceMix"};
$h->{".mixLastRun"} = at_time("13:00") - 7200;
$st = run_at($h, "13:00");
ok($st eq "off", "kein Umruehren ohne Waerme -> Filter $st");
ok(rd("mixState") eq "idle", "mixState: ".rd("mixState"));

print "\n=== heating off: der saubere Weg (Soll bleibt echt) ===\n";
$h = setup_pool(pool=>18, target=>30, heating=>"off", solarOn=>1, wpOn=>1);
$h->{".heatSinceMix"} = 1;
$h->{".mixLastRun"}   = at_time("13:00") - 7200;
$st = run_at($h, "13:00");
ok($st eq "off", "Filter aus -> $st");
ok(rd("heatingNeeded") eq "no", "heatingNeeded: ".rd("heatingNeeded"));
ok(rd("heating") eq "off", "Reading heating: ".rd("heating"));
ok(rd("solarState") eq "off (Heizen deaktiviert)",
   "solarState: ".rd("solarState"));
ok(switched("set d_solar off"), "Solarpumpe abgeschaltet");
ok(switched("set d_wp off"),    "WP-Anforderung abgeschaltet");
ok(rd("mixState") eq "idle", "kein Umruehren: ".rd("mixState"));

print "\n=== heating off + WP meldet an (readOnly): kein Durchfluss ===\n";
$h = setup_pool(pool=>18, target=>30, heating=>"off", wpOn=>1, readOnly=>1);
$st = run_at($h, "13:00");
ok($st eq "off", "Filter bleibt aus -> $st");
ok(rd("filterReason") eq "aus: WP an, soll nicht heizen",
   "filterReason: ".rd("filterReason"));
ok(rd("heatpumpState") eq "on (beobachtet)",
   "heatpumpState: ".rd("heatpumpState"));
ok(!grep({ /^set d_wp / } @SWITCHED), "WP-Dummy nicht ueberschrieben");
ok(rd("lastDecision") =~ /WP meldet an/, "lastDecision: ".rd("lastDecision"));

print "\n=== heating off: Nachtfilterung erfuellt das Tagessoll weiter ===\n";
$h = setup_pool(pool=>18, target=>30, heating=>"off");
$st = run_at($h, "23:00");
ok($st eq "on", "Filter laeuft nachts -> $st");
ok(rd("filterReason") eq "Nachtfilterung", "filterReason: ".rd("filterReason"));

print "\n=== heating off: Handbetrieb geht vor (mit Warnung) ===\n";
$h = setup_pool(pool=>18, target=>30, heating=>"off", manual=>"on",
                      wpOn=>1, readOnly=>1);
$st = run_at($h, "13:00");
ok($st eq "on", "set filter on wirkt -> $st");
ok(rd("lastDecision") =~ /Achtung/, "Warnung: ".rd("lastDecision"));

print "\n=== Zeitschaltuhr-Schutz: Uhr 09-19, Nacht 22-06, Dummy aus ===\n";
for my $hm (qw(10:00 13:00 18:30)) {
    $h = setup_pool(pool=>18, target=>30, heating=>"off", readOnly=>1);
    $st = run_at($h, $hm);
    ok($st eq "off" && rd("filterReason") eq "aus: WP-Zeitfenster, soll nicht heizen",
       "$hm (WP hat Strom): Filter $st, Grund: ".rd("filterReason"));
}
$h = setup_pool(pool=>18, target=>30, heating=>"off", readOnly=>1);
$st = run_at($h, "19:30");
ok($st eq "off", "19:30 (Uhr aus, kein Nachtfenster): Filter $st");
for my $hm (qw(23:00 03:00 05:30)) {
    $h = setup_pool(pool=>18, target=>30, heating=>"off", readOnly=>1);
    $st = run_at($h, $hm);
    ok($st eq "on", "$hm (Uhr aus): Filter $st, Grund: ".rd("filterReason"));
}

print "\n=== Zeitfenster-Schutz nur mit heatpumpReadOnly ===\n";
$h = setup_pool(pool=>18, target=>30, heating=>"off", readOnly=>0);
$st = run_at($h, "13:00");
ok(rd("filterReason") eq "nur filtern (Heizen aus)",
   "ohne readOnly kein Zeitfenster-Block: ".rd("filterReason"));

print "\n=== readOnly: Solarindex entscheidet weiter ueber den Filter ===\n";
# Regression: readOnly ersetzt nur das Schalten, nicht die Freigabelogik.
$h = setup_pool(pool=>18, target=>30, wpOn=>1, readOnly=>1, index=>2);
$st = run_at($h, "12:30");
ok($st eq "off", "Index 2 (< ein 8): Filter $st");
ok(rd("lastDecision") =~ /Solarindex zu niedrig/,
   "lastDecision erklaert es: ".rd("lastDecision"));

$h = setup_pool(pool=>18, target=>30, wpOn=>1, readOnly=>1, index=>10);
$st = run_at($h, "12:30");
ok($st eq "on", "Index 10 (>= ein 8): Filter $st -> WP bekommt Durchfluss");
ok(rd("filterReason") =~ /^WP/, "filterReason: ".rd("filterReason"));

$h = setup_pool(pool=>18, target=>30, wpOn=>1, readOnly=>1, index=>10);
$st = run_at($h, "20:00");
ok($st eq "off", "20:00 ausserhalb WP-Fenster: Filter $st");

$h = setup_pool(pool=>32, target=>30, inflow=>32, wpOn=>1, readOnly=>1, index=>10);
$st = run_at($h, "12:30");
ok(rd("lastDecision") =~ /Soll erreicht/, "Pool ueber Soll: ".rd("lastDecision"));

$h = setup_pool(pool=>18, target=>30, wpOn=>0, readOnly=>1, index=>10);
$st = run_at($h, "12:30");
ok($st eq "off", "Dummy aus trotz Index: Filter $st");
ok(rd("lastDecision") =~ /nur beobachtet/, "Grund sichtbar: ".rd("lastDecision"));

print "\n=== Live-Zustand der Anlage vom 26.08.2026, 12:25 ===\n";
# Aus Main/fhem.save der Instanz nachgestellt: Pool 22.2, Zulauf 23.4,
# solarIndex 0, WP-Dummy an, heatpumpReadOnly 1, solarStartTime 13:00.
# Live lief der Filter mit Grund "WP" - obwohl der Index 0 war.
$h = setup_pool(pool=>22.2, inflow=>23.4, index=>0, target=>30,
                      wpOn=>1, readOnly=>1, heating=>"on");
$attr{$DEVICE}{solarStartTime}  = "13:00";
$attr{$DEVICE}{solarHysteresis} = 0.3;
$st = run_at($h, "12:25");
ok($st eq "off", "Filter jetzt $st (live war: on, Grund WP)");
ok(rd("lastDecision") =~ /Solarindex zu niedrig \(0, ein>=8/,
   "Grund genannt: ".rd("lastDecision"));
ok(rd("heatpumpEffective") eq "23.1",
   "heatpumpEffective wie live: ".rd("heatpumpEffective"));
ok(!grep({ /^set d_wp / } @SWITCHED), "WP-Dummy unangetastet");

$h = setup_pool(pool=>22.2, inflow=>23.4, index=>9, target=>30,
                      wpOn=>1, readOnly=>1, heating=>"on");
$attr{$DEVICE}{solarStartTime} = "13:00";
$st = run_at($h, "12:25");
ok($st eq "on", "Index 9: Filter $st -> WP heizt wieder");

print "\n=== Sommer-Regressionen ===\n";
$h = setup_pool(pool=>32, target=>30, inflow=>33);
$h->{".heatSinceMix"} = 1;
$h->{".mixLastRun"}   = at_time("13:00") - 7200;
$st = run_at($h, "13:00");
ok($st eq "on", "Soll erreicht + Solar hatte geheizt -> Umruehren ($st)");
ok(rd("filterReason") eq "Umruehren", "filterReason: ".rd("filterReason"));
ok(!defined $h->{".heatSinceMix"}, "Flag verbraucht (ein Mix pro Heizepisode)");

$h = setup_pool(pool=>25, target=>30, inflow=>27, index=>10);
$st = run_at($h, "13:00");
ok(rd("heatingNeeded") eq "yes", "Heizbedarf erkannt");
ok(switched("set d_wp on"),    "WP wird angefordert");
ok(switched("set d_solar on"), "Solar-Anlaufversuch");
ok($st eq "on", "Filter laeuft fuer die WP -> $st");

done();
