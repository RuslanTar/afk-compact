package usagerec;
# lib/usagerec.pm: the shared usage record (0.1.8).
# The latest usage reading each session on this machine saw, per window kind and source, in one
# small file of the plugin's own state at a fixed place no option moves (as cachestate.pm's):
# ${XDG_STATE_HOME:-~/.local/state}/<plugin>/usage.v1.json (0600). An entry is
# {kind, pct, resets_at, at, src, sid8}: the window kind Claude Code names (five_hour, seven_day,
# spend_limit), its share, its reset (epoch seconds, or null), when it was read (epoch seconds),
# its source and the first 8 characters of the session id. Sources: `plugin`, the mod's
# $.session.usage() (cmd/usage.pl --stdin), and `statusline`, the rate_limits of the JSON Claude Code
# sends a status line (cmd/cache.pl --note-usage). No account id, no secret, no content. Claude Code
# fills both from one in-process object (the last API response's headers), so the two sources of
# one session are one reading at two times; only another session's reading is independent.
# A status line gets that reading without the time Claude Code took it and shows it again while it
# is on screen, so a `statusline` entry's `at` is when a status line first showed that share and
# reset: an unchanged one keeps it and only moves `seen`, the last time the status line showed it.
# That first time is known only while the entry stays in the record (one dropped and shown again is
# dated anew), so readers never date a `statusline` entry newer than its session's own refresh:
# that session's `plugin` entry of the same kind (dated() here; the mod: limits.ts recordReadings),
# and one with no such entry is no reading.
# Writers read the file, merge their entries (one per sid8, src and kind; the later `at` wins),
# drop those that no longer count (kept(): a window's share only grows until its reset, so an
# entry stays until its `resets_at`, however old; one with none only $FRESH_S after it was last
# read or seen), keep at most $MAX_ENTRIES, a session's entries together (the sessions last read or
# seen first), never dropping for room the session and kind whose entry is the latest of a window
# (_deciding(): the reading a near-limit decision goes by), and rename a temp file over it
# (cachestate::_put: never inside a git work tree or a .planning folder, so with the state folder
# in one there is no record). Two writers at once: the last one wins, and the lost entry comes
# back at that session's next write.
use strict;
use warnings;
use utf8;

# An entry with no reset time is kept this long after it was last read or seen (the plugin counts
# one only while it is that fresh: limits.ts LIMIT_FRESH_MS).
our $FRESH_S = 600;
# Entries of one kind whose resets are at most this far apart are of one window (limits.ts RESET_SAME_MS).
our $SAME_RESET_S = 60;
our $MAX_ENTRIES = 64;
our $MAX_BYTES = 65536;
# A statusline entry with the same share and reset as the one kept moves its `seen` only this
# much later (a status line with a short refreshInterval runs every few seconds).
our $SAME_S = 60;
our %SRC = map { $_ => 1 } qw(plugin statusline);

sub schema { return ctx::brand() . '-usage/v1' }

sub file { my $b = cachestate::base() // return undef; return "$b/usage.v1.json" }

sub _num { my ($v) = @_; return defined $v && !ref $v && $v =~ /\A-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/ ? 0 + $v : undef }
sub _t { my ($v) = @_; return 0 + sprintf('%.3f', $v) }

# sid8(sid) -> the first 8 characters of a session id, or undef for none
sub sid8 {
    my ($s) = @_;
    return undef unless cachestate::sid_ok($s);
    return substr($s, 0, 8);
}

# _entry(hash) -> a clean entry, or undef when any field is out of form
sub _entry {
    my ($e) = @_;
    return undef unless ref $e eq 'HASH';
    my ($kind, $src, $sid8) = map { ref $_ ? undef : $_ } @$e{qw(kind src sid8)};
    return undef unless defined $kind && $kind =~ /\A[a-z0-9_]{1,40}\z/;
    return undef unless defined $src && $SRC{$src};
    return undef unless defined $sid8 && $sid8 =~ /\A[A-Za-z0-9._-]{1,8}\z/;
    my $pct = _num($e->{pct});
    my $at = _num($e->{at});
    return undef unless defined $pct && $pct >= 0 && $pct <= 1000 && defined $at && $at > 0;
    my $r = _num($e->{resets_at});
    my $seen = _num($e->{seen});
    return { kind => $kind, pct => $pct, resets_at => (defined $r && $r > 0 ? int($r) : undef), at => _t($at), src => $src, sid8 => $sid8,
             (defined $seen && $seen > $at ? (seen => _t($seen)) : ()) };
}

# _last(entry) -> when the entry was last read or seen
sub _last { my ($e) = @_; return $e->{seen} // $e->{at} }

# read_all() -> [entry...] as kept (none, unreadable or another schema: [])
sub read_all {
    my $f = file() // return [];
    my $raw = util::read_file($f, $MAX_BYTES + 1) // return [];
    return [] if length($raw) > $MAX_BYTES;
    my $j = eval { jsonc::decode($raw) };
    return [] unless ref $j eq 'HASH' && ($j->{schema} // '') eq schema() && ref $j->{readings} eq 'ARRAY';
    return [ grep { defined } map { _entry($_) } @{ $j->{readings} } ];
}

sub _key { my ($e) = @_; return join("\0", @$e{qw(sid8 src kind)}) }

# kept(entries, now) -> [entry...]: those that still count at `now`: an entry with a reset
# time until it, one without for $FRESH_S after it was last read or seen
sub kept {
    my ($all, $now) = @_;
    return [ grep { defined $_->{resets_at} ? $_->{resets_at} > $now : $now - _last($_) <= $FRESH_S } @$all ];
}

# _deciding(entries) -> { "sid8\0kind" => 1 }: per window (a kind, its entries' resets within
# $SAME_RESET_S of the window's earliest) the session whose reading is the latest (dated(); the
# larger share on a tie): the one that decides for that window
sub _deciding {
    my ($all) = @_;
    my (%out, $win, $first);
    for my $e (sort { $a->{kind} cmp $b->{kind} || $a->{resets_at} <=> $b->{resets_at} } grep { defined $_->{resets_at} } @{ dated($all) }) {
        if (!$win || $win->{kind} ne $e->{kind} || $e->{resets_at} - $first > $SAME_RESET_S) {
            $out{"$win->{sid8}\0$win->{kind}"} = 1 if $win;
            ($win, $first) = ($e, $e->{resets_at});
            next;
        }
        $win = $e if $e->{at} > $win->{at} || ($e->{at} == $win->{at} && $e->{pct} > $win->{pct});
    }
    $out{"$win->{sid8}\0$win->{kind}"} = 1 if $win;
    return \%out;
}

# note([entry...], now) -> [entry...] kept after the merge (written when anything changed)
sub note {
    my ($new, $now) = @_;
    my $all = read_all();
    my %at = map { (_key($_) => $_) } @$all;
    my $ch = 0;
    for my $e (grep { defined } map { _entry($_) } @{ $new || [] }) {
        next if $e->{at} > $now + 300;
        my $old = $at{ _key($e) };
        next if $old && _last($old) >= $e->{at};
        if ($old && $e->{src} eq 'statusline' && $old->{pct} == $e->{pct} && ($old->{resets_at} // 0) == ($e->{resets_at} // 0)) {
            next if $e->{at} - _last($old) < $SAME_S;
            $at{ _key($e) } = { %$old, seen => $e->{at} };
        } else {
            $at{ _key($e) } = $e;
        }
        $ch = 1;
    }
    my @live = @{ kept([ values %at ], $now) };
    my %grp;
    for my $e (@live) { $grp{ $e->{sid8} } = _last($e) if !defined $grp{ $e->{sid8} } || _last($e) > $grp{ $e->{sid8} } }
    my @keep = sort { $grp{ $b->{sid8} } <=> $grp{ $a->{sid8} } || $a->{sid8} cmp $b->{sid8} || _last($b) <=> _last($a) || _key($a) cmp _key($b) } @live;
    if (@keep > $MAX_ENTRIES) {
        my $dec = _deciding(\@keep);
        my $room = $MAX_ENTRIES - grep { $dec->{"$_->{sid8}\0$_->{kind}"} } @keep;
        @keep = grep { $dec->{"$_->{sid8}\0$_->{kind}"} || $room-- > 0 } @keep;
        splice(@keep, $MAX_ENTRIES) if @keep > $MAX_ENTRIES;
    }
    $ch = 1 if @keep != @$all;
    return \@keep unless $ch;
    my $f = file();
    cachestate::_put($f, jsonc::encode_bytes({ schema => schema(), updated_at => _t($now), readings => \@keep }) . "\n", 0600) if defined $f;
    return \@keep;
}

# dated([entry...]) -> [entry...]: the entries as readings: a `statusline` entry dated no later than
# its session's `plugin` entry of the same kind, and left out with none (see the header)
sub dated {
    my ($all) = @_;
    my %pat;
    for my $e (grep { $_->{src} eq 'plugin' } @$all) {
        my $k = "$e->{sid8}\0$e->{kind}";
        $pat{$k} = $e->{at} if !defined $pat{$k} || $e->{at} > $pat{$k};
    }
    my @out;
    for my $e (@$all) {
        if ($e->{src} ne 'statusline') { push @out, $e; next }
        my $cap = $pat{"$e->{sid8}\0$e->{kind}"} // next;
        push @out, { %$e, at => ($e->{at} < $cap ? $e->{at} : $cap) };
    }
    return \@out;
}

# from_statusline(input, now) -> [entry...]: the rate_limits of a status line's JSON
# ({"five_hour": {"used_percentage", "resets_at"}, "seven_day": …, "spend_limit": …}) of its session,
# shown `now` (note() keeps an unchanged one's first time)
sub from_statusline {
    my ($in, $now) = @_;
    return [] unless ref $in eq 'HASH' && ref $in->{rate_limits} eq 'HASH';
    my $s8 = sid8(ref $in->{session_id} ? undef : $in->{session_id}) // return [];
    my $rl = $in->{rate_limits};
    my @out;
    for my $k (sort keys %$rl) {
        my $w = $rl->{$k};
        next unless ref $w eq 'HASH';
        push @out, { kind => $k, pct => $w->{used_percentage}, resets_at => $w->{resets_at}, at => $now, src => 'statusline', sid8 => $s8 };
    }
    return \@out;
}

1;
