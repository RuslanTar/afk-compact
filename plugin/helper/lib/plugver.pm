package plugver;
# lib/plugver.pm: which plugin copy this session runs against the one sessions started later
# load (0.1.3 version skew). Owner: WP-core. Claude Code fixes a plugin's folder when a session
# loads it, so a long session keeps running an older copy after an install (15 sessions after the
# 0.1.2 install; one ran 0.1.0 for about 18 h).
#   <root>/.sessions/loads/<load epoch>_<pid>-<lstart epoch>_<version>.json
#     {v, plugin_version, plugin_root, host, session_id, source, ts}: one record per Claude Code
#     process and plugin version, written by SessionStart (every source) when this process has no
#     record of this version yet. So a /clear, /resume or compaction in a process that keeps its
#     copy adds none, and a process whose copy changed (/reload-plugins) adds one. The name holds
#     the load time and the version, so a reader sorts and walks the names and reads only a few
#     files. Records are never rewritten or removed (as .sessions/by-pid/).
#   note_load(sid, source) -> 1 when a record was written, else 0
#   skew() -> undef | {own, ref, since, newest}: the reference is the version of the newest load
#     of this host; undef (no notice) unless all of: both versions readable and different, the
#     newest load at most $WINDOW_S old, and this copy installed before that load (its
#     .claude-plugin/plugin.json mtime; a copy installed later is the newer one, e.g. after
#     /reload-plugins). since = the oldest load of the reference version after the newest load of
#     another version (within the names walked).
#   line() -> `this session runs <own>; sessions started since <stamp> run <ref>: /reload-plugins`
#     or undef. Bounded: one directory listing, at most $READ_MAX small reads, one stat; never dies.
use strict;
use warnings;
use utf8;

# A week: the sessions seen lived up to about 2.5 days (started 2026-10-30 07:33, still running
# 2026-11-01 22:00), so every skew inside a session's life is covered three times over; a newest
# load older than that no longer says what is installed (a later uninstall, update or rollback
# with no session started since is not seen), so it is not trusted.
our $WINDOW_S = 7 * 86400;
our $READ_MAX = 8;
our $NAME_MAX = 64;
my $VER_RE = qr/[0-9A-Za-z][0-9A-Za-z.+-]{0,39}/;
my $NAME_RE = qr/\A(\d{1,12})_(\d+-\d+)_($VER_RE)\.json\z/;

sub dir { return sessions::dir() . '/loads' }

sub _ver_ok { my ($v) = @_; return defined $v && !ref $v && $v =~ /\A$VER_RE\z/ ? 1 : 0 }

# _loads() -> [[epoch, key, version, name] ...], newest first (ties: name order, reversed)
sub _loads {
    my @l;
    for my $n (util::list_dir(dir())) {
        push @l, [0 + $1, $2, $3, $n] if $n =~ $NAME_RE;
    }
    return [sort { $b->[0] <=> $a->[0] || $b->[3] cmp $a->[3] } @l];
}

sub note_load {
    my ($sid, $source) = @_;
    return 0 unless rc::root_ok('handoff_root');
    my $v = ctx::version();
    return 0 unless _ver_ok($v);
    my $c = rc::claude();
    return 0 unless ref $c eq 'HASH' && defined $c->{pid};
    my $key = sessions::_key($c);
    return 0 if grep { $_->[1] eq $key && $_->[2] eq $v } @{ _loads() };
    my $now = util::now();
    my $rec = jsonc::obj(v => 1, plugin_version => $v, plugin_root => ctx::root(), host => identity::host(),
                         session_id => $sid, source => $source, ts => util::iso($now));
    return util::write_excl(dir() . '/' . int($now) . "_${key}_$v.json", jsonc::encode_bytes($rec) . "\n", 0600) ? 1 : 0;
}

# installed() -> this copy's install time: the mtime of its .claude-plugin/plugin.json, or undef
sub installed {
    my @st = stat(ctx::root() . '/.claude-plugin/plugin.json');
    return @st ? $st[9] : undef;
}

sub skew {
    my $own = ctx::version();
    return undef unless _ver_ok($own) && rc::root_ok('handoff_root');
    my $all = _loads();
    splice(@$all, $NAME_MAX) if @$all > $NAME_MAX;
    my $host = identity::host();
    my ($ri, $reads) = (undef, 0);
    for my $i (0 .. $#$all) {
        last if $reads++ >= $READ_MAX;
        my $raw = util::read_file(dir() . '/' . $all->[$i][3], 64 * 1024) // next;
        my $j = eval { jsonc::decode($raw) };
        next unless ref $j eq 'HASH' && ($j->{host} // '') eq $host && ($j->{plugin_version} // '') eq $all->[$i][2];
        $ri = $i;
        last;
    }
    return undef unless defined $ri;
    my ($newest, $ref) = @{ $all->[$ri] }[0, 2];
    return undef if $ref eq $own;
    return undef if util::now() - $newest > $WINDOW_S;
    my $inst = installed();
    return undef if defined $inst && $inst >= $newest;
    my $since = $newest;
    for my $i ($ri + 1 .. $#$all) {
        last unless $all->[$i][2] eq $ref;
        $since = $all->[$i][0];
    }
    return { own => $own, ref => $ref, since => $since, newest => $newest };
}

sub line {
    my $s = eval { skew() } or return undef;
    return sprintf('this session runs %s; sessions started since %s run %s: /reload-plugins', $s->{own}, util::stamp($s->{since}), $s->{ref});
}

1;
