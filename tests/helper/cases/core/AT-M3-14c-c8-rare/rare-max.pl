# AT-M3-14c-c8-rare setup: set c8.rare_max in the case's own staged baseline, as
# `perl rare-max.pl BASELINE N|min|none` (min: the lowest count but the arm list's, so the
# strings at the limit itself are rare; none: the key removed, an older baseline's shape).
use strict;
use warnings;

my ($file, $max) = @ARGV;
die "usage: BASELINE N|min|none\n" unless defined $max && $max =~ /^(?:\d+|min|none)\z/;
open(my $in, '<:raw', $file) or die "read $file: $!\n";
my $raw = do { local $/; <$in> };
close $in;
require JSON::PP;
my $j = JSON::PP->new->utf8->canonical->pretty;
my $doc = $j->decode($raw);
my $c8 = $doc->{c8};
if ($max eq 'none') { delete $c8->{rare_max} }
elsif ($max eq 'min') {
    my ($low) = sort { $a <=> $b } map { $c8->{counts}{$_} } grep { $_ ne ($c8->{arm_list} // '') } keys %{ $c8->{counts} };
    $c8->{rare_max} = $low;
}
else { $c8->{rare_max} = 0 + $max }
open(my $out, '>:raw', $file) or die "write $file: $!\n";
print $out $j->encode($doc);
close($out) or die "close $file: $!\n";
