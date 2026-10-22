# AT-P-11 fixture: one line per L1, L2 and L3 rule
use strict;
use warnings;
use JSON::PP;
require "nolib.pm";
my %h = %+;
my $n = $+{name};
my $c = "\N{BULLET}";
my $u = "x" =~ /\p{Lu}/;
use open qw(:std :utf8);
my $b = Encode::encode('UTF-8', 'x');
use v5.36;
use feature qw(say signatures);
my $t = builtin::true;
require fine;
