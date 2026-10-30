# AT-M3-14c-c8-rare setup: write a stand-in Claude Code binary whose C8 string counts equal the
# baseline's, as `perl fake-claude.pl BASELINE OUT [MUTATION]`: a shell script that exits 0
# (smoke runs `plugin validate` and `plugin test` with it), then each counted string on comment
# lines as often as the baseline counts it. Longest strings first: a string that holds a shorter
# one (the arm list holds every arm, short_v2 holds short) adds to that one's count, so each
# string is written only as often as its count still needs. MUTATION, applied after:
#   common     one more line holding the most frequent string (a common word)
#   drop-rare  every occurrence of the least frequent string other than the arm list (rare)
#               replaced by x's of the same length
#   drop-arm   the arm the baseline counts most often (a common word, so only the arm list
#               is a rare change) taken out of every copy of the arm list
use strict;
use warnings;

my ($base_file, $out, $mut) = @ARGV;
die "usage: BASELINE OUT [common|drop-rare|drop-arm]\n" unless defined $out;
open(my $bf, '<:raw', $base_file) or die "read $base_file: $!\n";
my $braw = do { local $/; <$bf> };
close $bf;
require JSON::PP;
my $c8 = JSON::PP->new->decode($braw)->{c8};
my %want = %{ $c8->{counts} };
my $arm_list = $c8->{arm_list};

sub count_in {
    my ($data, $s) = @_;
    my ($n, $pos) = (0, 0);
    while (($pos = index($data, $s, $pos)) >= 0) { $n++; $pos += length $s }
    return $n;
}

my $body = '';
for my $s (sort { length($b) <=> length($a) || $a cmp $b } keys %want) {
    my $need = $want{$s} - count_in($body, $s);
    die "$s: the longer strings already hold it more often than the baseline counts\n" if $need < 0;
    $body .= "# $s\n" x $need;
}
for my $s (keys %want) {
    die "$s: counted " . count_in($body, $s) . ", baseline $want{$s}\n" unless count_in($body, $s) == $want{$s};
}
$mut //= '';
if ($mut eq 'common') {
    my ($top) = sort { $want{$b} <=> $want{$a} || $a cmp $b } keys %want;
    $body .= "# $top\n";
}
elsif ($mut eq 'drop-rare') {
    my ($low) = sort { $want{$a} <=> $want{$b} || $a cmp $b } grep { !defined $arm_list || $_ ne $arm_list } keys %want;
    my $x = 'x' x length $low;
    $body =~ s/\Q$low\E/$x/g;
}
elsif ($mut eq 'drop-arm') {
    die "the baseline has no arm list\n" unless defined $arm_list;
    my ($arm) = sort { ($want{$b} // 0) <=> ($want{$a} // 0) || $a cmp $b } $arm_list =~ /"([^"]+)"/g;
    (my $short = $arm_list) =~ s/"\Q$arm\E",?//;
    $short =~ s/,]\z/]/;
    $body =~ s/\Q$arm_list\E/$short/g;
}
elsif ($mut ne '') { die "unknown mutation $mut\n" }
(my $od = $out) =~ s{/[^/]+\z}{};
system('/bin/mkdir', '-p', $od) == 0 or die "mkdir $od failed\n" if $od ne $out && $od ne '';
open(my $fh, '>:raw', $out) or die "write $out: $!\n";
print $fh "#!/bin/sh\nexit 0\n", $body;
close($fh) or die "close $out: $!\n";
chmod 0755, $out or die "chmod $out: $!\n";
