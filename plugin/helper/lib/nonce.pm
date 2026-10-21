package nonce;
# lib/nonce.pm: per-compaction nonce (MOD-SPEC §2.2): 8 lowercase hex from
# /dev/urandom, redrawn while <watch>/<sid>/dispatch/<nonce>.json exists.
# Owner: WP-core.
use strict;
use warnings;

# draw(sid [, watch]) -> nonce
sub draw {
    my ($sid, $watch) = @_;
    $watch //= rc::watch();
    for (1 .. 64) {
        my $n = util::rand_hex(8);
        next unless $n =~ /^[0-9a-f]{8}$/;
        return $n unless defined $watch && defined $sid && -e "$watch/$sid/dispatch/$n.json";
    }
    die "nonce: no free draw\n";
}

sub valid { return defined $_[0] && $_[0] =~ /^[0-9a-f]{8}$/ ? 1 : 0 }

1;
