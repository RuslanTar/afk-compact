package fine;
# AT-P-11 fixture: a helper library on the floor (no hit). Comment lines are not linted: %+ \N{BULLET} use open
use strict;
use warnings;
use 5.010;
my $fmt = sprintf('%+d', 3);
my $nl = "a\Nb" =~ /a\N{U+0062}/;
sub f { my ($x) = @_; return $1 if $x =~ /(\d+)/; return eval { require Time::HiRes; 1 } ? 1 : 0 }
1;
