#!/usr/bin/perl
#
# Statische Pruefung der Widget-Definitionen im Modul (Slider).
#
# FHEMWEB parst einen Slider in FW_createSlider (www/pgm2/fhemweb.js) so:
#
#   var min = parseFloat(vArr[1]); var stp = parseFloat(vArr[2]);
#   var max = parseFloat(vArr[3]); var flt = (vArr.length == 5 && vArr[4] == "1");
#   ...
#   if(vArr.length < 4 || vArr.length > 5 || vArr[0] != "slider") ...
#
# Daraus folgen drei Regeln, die hier geprueft werden:
#  1. slider braucht 4 oder 5 Felder (slider,min,step,max[,1]).
#  2. Ohne das Float-Flag "1" als fuenftes Feld laeuft der Wert durch
#     parseInt() - der Slider rastet also auf GANZE ZAHLEN, egal welcher Step
#     angegeben ist. Jede Definition mit Dezimalstelle braucht das Flag.
#  3. Der Bereich sollte durch den Step glatt teilbar sein, sonst ist der
#     Endwert (max) mit dem Slider nicht erreichbar.
#
# Diese Datei laedt das Modul nicht, sie liest den Quelltext - damit sind
# beide Listen erfasst (AttrList in PoolControl_Initialize und die set-Liste
# in PoolControl_Set).

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $dir  = dirname(abs_path(__FILE__));
my $file = "$dir/../FHEM/98_PoolControl.pm";

open(my $fh, "<", $file) or die "Kann $file nicht lesen: $!\n";
my @lines = <$fh>;
close($fh);

my $fails = 0;
my $oks   = 0;
sub ok { my ($c,$t)=@_; printf("%-5s %s\n", $c?"ok":"FAIL", $t); $c ? $oks++ : $fails++; }

my $found = 0;
for my $i (0 .. $#lines) {
    my $line = $lines[$i];
    while ($line =~ /\b([a-zA-Z]+):slider,([^ "]+)/g) {
        my ($name, $spec) = ($1, $2);
        $found++;
        my @f = split(/,/, $spec, -1);

        # Regel 1: 3 Werte, optional das Flag -> 3 oder 4 Felder hinter "slider"
        if (!ok(@f == 3 || @f == 4,
                sprintf("%-22s Feldzahl ok (slider,%s)", $name, $spec))) {
            next;
        }

        my ($min, $step, $max, $flag) = @f;
        my $decimal = grep { /\./ } ($min, $step, $max);

        # Regel 2: Dezimalwerte brauchen das Float-Flag
        if ($decimal) {
            ok(defined $flag && $flag eq "1",
               sprintf("%-22s Dezimal-Step %s hat Float-Flag", $name, $step));
        }
        else {
            ok(!defined $flag,
               sprintf("%-22s ganzzahlig, kein Flag noetig", $name));
        }

        # Regel 3: max muss mit dem Step erreichbar sein
        my $steps = ($step != 0) ? ($max - $min) / $step : 0;
        ok($step != 0 && abs($steps - int($steps + 0.5)) < 1e-9,
           sprintf("%-22s %s..%s in %d Schritten erreichbar", $name, $min, $max,
                   int($steps + 0.5)));
    }
}

ok($found > 0, "Slider-Definitionen gefunden ($found)");

printf("\n%d ok, %d FAILED\n", $oks, $fails);
exit($fails ? 1 : 0);
