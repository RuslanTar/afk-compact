# AT-M3-14c-c8-rare setup: edit the case's own staged baseline, as
# `perl baseline-edit.pl BASELINE N|-N|text:S|min|none|uncount-arm|count`: N or -N set c8.rare_max
# to that number, text:S to the string S (a malformed limit), min to the lowest count but the arm
# list's (so the strings at the limit itself are rare), none removes the key (an older
# baseline's shape); uncount-arm removes the arm list from c8.counts. count edits nothing and
# prints `rare R common C`: how many strings but the arm list the baseline makes rare (a count of
# at most rare_max; all of them when rare_max is not a whole number) and how many common, the
# numbers smoke's C8 pass line should name.
use strict;
use warnings;

my ($file, $max) = @ARGV;
die "usage: BASELINE N|-N|text:S|min|none|uncount-arm|count\n"
    unless defined $max && $max =~ /^(?:-?\d+|text:.*|min|none|uncount-arm|count)\z/s;
open(my $in, '<:raw', $file) or die "read $file: $!\n";
my $raw = do { local $/; <$in> };
close $in;
require JSON::PP;
my $j = JSON::PP->new->utf8->canonical->pretty;
my $doc = $j->decode($raw);
my $c8 = $doc->{c8};
my $arm = $c8->{arm_list} // '';
if ($max eq 'count') {
    my $lim = $c8->{rare_max};
    my $whole = defined $lim && !ref $lim && $lim =~ /^\d+\z/;
    my ($rare, $common) = (0, 0);
    for my $s (grep { $_ ne $arm } keys %{ $c8->{counts} }) {
        if (!$whole || $c8->{counts}{$s} <= $lim) { $rare++ } else { $common++ }
    }
    print "rare $rare common $common\n";
    exit 0;
}
if ($max eq 'none') { delete $c8->{rare_max} }
elsif ($max eq 'uncount-arm') { delete $c8->{counts}{$arm} }
elsif ($max eq 'min') {
    my ($low) = sort { $a <=> $b } map { $c8->{counts}{$_} } grep { $_ ne $arm } keys %{ $c8->{counts} };
    $c8->{rare_max} = $low;
}
elsif ($max =~ /^text:(.*)\z/s) { $c8->{rare_max} = "$1" }
else { $c8->{rare_max} = 0 + $max }
open(my $out, '>:raw', $file) or die "write $file: $!\n";
print $out $j->encode($doc);
close($out) or die "close $file: $!\n";
