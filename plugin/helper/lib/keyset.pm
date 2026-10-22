package keyset;
# lib/keyset.pm: C5 payload key-set canary (MOD-SPEC §5.6). Owner: WP-core.
# The baseline (assets/canary-baseline.json, tools/canary-baseline) lists each
# event's required and optional top-level keys. A payload with a key outside that
# set, or without a required key, logs one `keyset_change` per (event, key set): the
# exclusive-create marker <watch>/keyset/<event>-<keyset_sha8> (P5-FOLD A7: not per version,
# so a key set first seen before the version is known does not fire again under it); the
# row carries cc_version in its envelope.
use strict;
use warnings;
use utf8;

my $BASE;
sub baseline {
    return $BASE if defined $BASE;
    my $raw = util::read_file(ctx::asset_path('canary-baseline.json'));
    my $j = defined $raw ? eval { jsonc::decode($raw) } : undef;
    $BASE = ref $j eq 'HASH' ? $j : 0;
    return $BASE;
}

sub sha8 { return substr(sha::hex256(join(',', sort @{ $_[0] })), 0, 8) }

sub check {
    my ($event, $payload) = @_;
    return unless ref $payload eq 'HASH';
    my $b = baseline() or return;
    my $ks = ref $b->{keysets} eq 'HASH' ? $b->{keysets}{$event} : undef;
    return unless ref $ks eq 'HASH';
    my %known = map { $_ => 1 } @{ $ks->{required} || [] }, @{ $ks->{optional} || [] };
    my @keys = sort keys %$payload;
    my @added = grep { !$known{$_} } @keys;
    my %have = map { $_ => 1 } @keys;
    my @missing = grep { !$have{$_} } @{ $ks->{required} || [] };
    return unless @added || @missing;
    my $w = rc::watch() // return;
    my $ks8 = sha8(\@keys);
    (my $tag = "$event-$ks8") =~ s/[^A-Za-z0-9._-]/_/g;
    my $first = eval { util::write_excl("$w/keyset/$tag", '', 0600) };
    return unless $first;
    my @clip = map { /^[A-Za-z0-9_]{1,64}$/ ? $_ : 'other' } @added;
    rc::emit('keyset_change', [event => $event, keyset_sha8 => $ks8, baseline_sha8 => $ks->{sha8},
                               added => [@clip[0 .. ($#clip > 9 ? 9 : $#clip)]], missing => \@missing]);
}

1;
