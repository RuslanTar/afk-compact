# AT-M3-14c-c8-rare setup: edit the case's own staged baseline, as
# `perl baseline-edit.pl BASELINE N|-N|text:S|min|below-top|top|none|zero-one|zero-all|text-count|no-counts|no-c8|shape|count`:
# N or -N set c8.rare_max to that number, text:S to the string S (a malformed limit), min to the
# lowest count (so the strings at the limit itself are rare), below-top to one less than the
# highest count (so the most frequent string is a common word and the rest stay rare), top to
# the highest count (every count of 1 or more rare), none removes the key (an older baseline's
# shape); zero-one sets the least frequent string's count to 0, zero-all every count (a count the
# tool never writes); text-count sets the first string's count to a text, no-counts removes
# c8.counts, no-c8 removes the c8 part (a baseline C8 cannot compare: smoke must fail it). shape
# edits nothing and prints `arm_list absent` or `arm_list present`. count edits nothing and
# prints `rare R common C`, then ` zero Z` when Z counts are 0: how many strings the baseline
# makes rare (a whole number from 1 to rare_max; any from 1 when rare_max is not a whole number,
# as smoke's _rare), how many common, and how many 0 (never rare); R and C are the numbers
# smoke's C8 pass line should name.
use strict;
use warnings;

my ($file, $max) = @ARGV;
die "usage: BASELINE N|-N|text:S|min|below-top|top|none|zero-one|zero-all|text-count|no-counts|no-c8|shape|count\n"
    unless defined $max && $max =~ /^(?:-?[0-9]+|text:.*|min|below-top|top|none|zero-one|zero-all|text-count|no-counts|no-c8|shape|count)\z/s;
open(my $in, '<:raw', $file) or die "read $file: $!\n";
my $raw = do { local $/; <$in> };
close $in;
require JSON::PP;
my $j = JSON::PP->new->utf8->canonical->pretty;
my $doc = $j->decode($raw);
my $c8 = $doc->{c8};
my @counted = map { $c8->{counts}{$_} } keys %{ $c8->{counts} };
if ($max eq 'shape') {
    print 'arm_list ' . (exists $c8->{arm_list} ? 'present' : 'absent') . "\n";
    exit 0;
}
if ($max eq 'count') {
    my $lim = $c8->{rare_max};
    my $whole = defined $lim && !ref $lim && $lim =~ /^[0-9]+\z/;
    my ($rare, $common, $zero) = (0, 0, 0);
    for my $n (@counted) {
        if ($n == 0) { $zero++ } elsif (!$whole || $n <= $lim) { $rare++ } else { $common++ }
    }
    print "rare $rare common $common" . ($zero ? " zero $zero" : '') . "\n";
    exit 0;
}
if ($max eq 'none') { delete $c8->{rare_max} }
elsif ($max eq 'text-count') { my ($k) = sort keys %{ $c8->{counts} }; $c8->{counts}{$k} = '4x' }
elsif ($max eq 'no-counts') { delete $c8->{counts} }
elsif ($max eq 'no-c8') { delete $doc->{c8} }
elsif ($max eq 'zero-one') { my ($low) = sort { $c8->{counts}{$a} <=> $c8->{counts}{$b} || $a cmp $b } keys %{ $c8->{counts} }; $c8->{counts}{$low} = 0 }
elsif ($max eq 'zero-all') { $_ = 0 for values %{ $c8->{counts} } }
elsif ($max eq 'min') { ($c8->{rare_max}) = sort { $a <=> $b } @counted }
elsif ($max eq 'below-top') { my ($top) = sort { $b <=> $a } @counted; $c8->{rare_max} = $top - 1 }
elsif ($max eq 'top') { ($c8->{rare_max}) = sort { $b <=> $a } @counted }
elsif ($max =~ /^text:(.*)\z/s) { $c8->{rare_max} = "$1" }
else { $c8->{rare_max} = 0 + $max }
open(my $out, '>:raw', $file) or die "write $file: $!\n";
print $out $j->encode($doc);
close($out) or die "close $file: $!\n";
