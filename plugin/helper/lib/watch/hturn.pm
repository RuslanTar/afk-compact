package watch::hturn;
# lib/watch/hturn.pm: the plugin-submitted handoff turn (MOD-SPEC §9.1, D-18; WATCHER-SPEC
# M-17, A-18, A-19, A-27, DP-14 (6)). Owner: WP-watch.
#
# The mod opens a handoff turn with `handoff-turn open`, which exclusive-creates
# <watch>/<sid>/handoff-turn/<ht>.json (core's handoff_turn.pm: {v, ht, session_id, reason,
# max_calls, max_tokens, opened_at}; <ht>.stage, <ht>.published and <ht>.superseded beside
# it), and then, after boundary_delay_ms, submits the turn. The submit is a `user` row with
# the plugin origin, the same shape as a `continue`; an open `ht` record told apart in time
# is what makes it a `handoff_turn` and never a `continue`. The watcher only reads these
# files, never writes them.
use strict;
use warnings;
use watch::ctx;
use watch::io;

# A submit row follows `handoff-turn open` by the boundary delay (seconds); the window is
# generous on the late side (a busy machine) and tight on the early side (clock skew).
our $SUBMIT_AFTER_S = 300;
our $SKEW_S = 5;
# How far after a halted `continue` row a handoff turn may open (the mod opens it at the
# nudged turn's end, right after the row).
our $OPEN_AFTER_ROW_S = 120;

sub dir_of { return watch::ctx::sid_dir($_[0]) . '/handoff-turn' }

# The ht records of this session, oldest first: {ht, opened (epoch), reason, published}.
# Read once per ctx (a hook call is short).
sub records {
    my ($ctx) = @_;
    return $ctx->{_hturns} if ref $ctx->{_hturns} eq 'ARRAY';
    my $dir = dir_of($ctx);
    my @r;
    for my $f (watch::io::list_dir($dir)) {
        next unless $f =~ /\A([0-9a-f]{8})\.json\z/;
        my $ht = $1;
        my $j = watch::io::read_json_file("$dir/$f");
        next unless ref $j eq 'HASH';
        my $t = watch::io::parse_iso($j->{opened_at});
        next unless defined $t;
        push @r, { ht => $ht, opened => $t, reason => (defined $j->{reason} && !ref $j->{reason} ? $j->{reason} : undef),
                   published => (-e "$dir/$ht.published" ? 1 : 0) };
    }
    @r = sort { $a->{opened} <=> $b->{opened} || $a->{ht} cmp $b->{ht} } @r;
    return $ctx->{_hturns} = \@r;
}

# The handoff turn a plugin-origin `user` row at epoch $ts submits: the latest record opened
# at most $SKEW_S after the row and at most $SUBMIT_AFTER_S before it, not in $used (one
# submit per ht). Returns the record or undef.
sub submit_for {
    my ($ctx, $ts, $used) = @_;
    return undef unless defined $ts;
    my $best;
    for my $r (@{ records($ctx) }) {
        next if $used && $used->{ $r->{ht} };
        next if $r->{opened} > $ts + $SKEW_S || $ts - $r->{opened} > $SUBMIT_AFTER_S;
        $best = $r;
    }
    return $best;
}

# The handoff turn opened for a halted `continue` row at epoch $rt (first one at or after the
# row, with a little skew allowed).
sub opened_after {
    my ($ctx, $rt) = @_;
    return undef unless defined $rt;
    for my $r (@{ records($ctx) }) {
        return $r if $r->{opened} >= $rt - $SKEW_S && $r->{opened} <= $rt + $OPEN_AFTER_ROW_S;
    }
    return undef;
}

1;
