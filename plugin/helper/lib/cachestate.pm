package cachestate;
# lib/cachestate.pm: the prompt cache's state for a status line (0.1.7, D-81). Owner: WP-core.
# `cache` (cmd/cache.pl, read-only) reports whether the session's prompt cache is warm: from
# Claude Code's own status-line `prompt_cache` (2.1.312+, --stdin), else from the transcript's last
# main `api-request` line (its timestamp and cache TTL), with the plugin's keep-warm on top. The
# contract is assets/cache-contract.md (`<plugin>-cache/v1`).
# State: one small file per session at a fixed place no option moves (a status line reads no
# plugin option): ${XDG_STATE_HOME:-~/.local/state}/<plugin>/cache/<sid>.v1.json. Writers:
# cmd/log.pl after a main keep-warm or compaction row of the mod (note_rows: the mod's `compacted`
# row comes after every compaction it wraps, Claude Code's own too, with its actor; `idle_compact`
# is written before the compaction is tried, so it is not read), the
# SessionStart hook (on_start: the transcript path; ended_at cleared, so a resumed session is live
# again) and SessionEnd (on_end). A write reads the file, changes it and renames
# a temp file over it; two processes of one session (a reload) may race: the last writer wins and
# the next row heals it. Nothing is written inside a git work tree or a .planning folder (the
# walk of MOD-SPEC §1.2, no git call).
# SessionStart also keeps a launcher shim with a stable path, ${XDG_STATE_HOME:-~/.local/state}/
# <plugin>/bin/ and the launcher's own file name (keep_shim): a two-line #!/bin/sh exec of this
# plugin copy's launcher, for status lines; never to a --plugin-dir load.
use strict;
use warnings;
use utf8;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);

# keepwarm.ts: the next ping 50 min after the last warm request; none later than 58 min.
our $PING_S = 50 * 60;
our $LATEST_S = 58 * 60;
our %TTL_S = ('1h' => 3600, '5m' => 300);
# A ping counts after a main request whose start only prompt_cache's expires_at bounds: its end
# within this many seconds of that bound (the fork's own touch moves it).
our $TOUCH_SLACK_S = 5;
our $MAX_BYTES = 65536;
# the transcript tail read for the last main api-request line, growing once
our @TAIL = (256 * 1024, 2 * 1024 * 1024);
our $PRUNE_DAYS = 7;
# the mod rows note_rows reads (keepwarm.ts; boundary.ts and compact.ts write `compacted` once the
# compaction ran or was skipped). Not idle.ts's `idle_compact`: it comes before the attempt, which
# may then be skipped or never run, and a compaction that runs writes its own `compacted` row.
our %ROWS = map { $_ => 1 } qw(keep_warm_start keep_warm_ping keep_warm_stop compacted);

sub schema       { return ctx::brand() . '-cache/v1' }
sub state_schema { return ctx::brand() . '-cache-state/v1' }

# base() -> ${XDG_STATE_HOME:-~/.local/state}/<plugin> (XDG_STATE_HOME only as an absolute path,
# as paths::state_default), or undef without an absolute home.
sub base {
    my $x = $ENV{XDG_STATE_HOME};
    my $root;
    if (defined $x && $x =~ m{\A/}) { $root = $x }
    else {
        my $h = util::home();
        return undef unless defined $h && $h =~ m{\A/};
        $root = "$h/.local/state";
    }
    return util::clean_path("$root/" . ctx::brand());
}

sub dir       { my $b = base() // return undef; return "$b/cache" }
sub shim_path { my $b = base() // return undef; return "$b/bin/" . ctx::brand() . '-store' }

sub sid_ok { my ($s) = @_; return args::valid_sid($s) && !args::reserved_sid($s) ? 1 : 0 }

sub file {
    my ($sid) = @_;
    return undef unless sid_ok($sid);
    my $d = dir() // return undef;
    return "$d/$sid.v1.json";
}

sub _num { my ($v) = @_; return defined $v && !ref $v && $v =~ /\A-?[0-9]+(?:\.[0-9]+)?\z/ ? 0 + $v : undef }
# epoch seconds kept to the millisecond
sub _t { my ($v) = @_; return defined $v ? 0 + sprintf('%.3f', $v) : undef }
sub _max { my $m; for (@_) { $m = $_ if defined $_ && (!defined $m || $_ > $m) } return $m }

# _safe(dir) -> 0 when the folder, read as given or through its links, lies in a git work tree or
# a .planning folder (a `.git` or `.planning` entry at or above it); the launcher's fallback walk.
sub _safe {
    my ($d) = @_;
    for my $p ($d, util::real_path($d)) {
        next unless defined $p && $p =~ m{\A/};
        return 0 if "$p/" =~ m{/\.planning/}i;
        my $t = $p;
        for (1 .. 64) {
            return 0 if -e "$t/.git" || -e "$t/.planning";
            last if $t eq '/' || $t eq '';
            $t = util::dirname($t);
        }
    }
    return 1;
}

# _put(path, bytes, mode) -> 1 when written: a temp file in the same folder renamed over it (where a
# rename over a file fails, as it can under Git Bash, the old one is removed first).
sub _put {
    my ($path, $bytes, $mode) = @_;
    my $d = util::dirname($path);
    return 0 unless _safe($d);
    eval { util::mkdir_p($d); 1 } or return 0;
    my $tmp = sprintf('%s/.%s.%d.%04x', $d, util::basename($path), $$, int(rand(65536)));
    sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, $mode) or return 0;
    my $ok = defined syswrite($fh, $bytes) ? 1 : 0;
    $ok = 0 unless close $fh;
    if ($ok) {
        chmod $mode, $tmp;
        $ok = rename($tmp, $path) ? 1 : 0;
        $ok = rename($tmp, $path) ? 1 : 0 if !$ok && !-d $path && unlink($path);
    }
    unlink $tmp unless $ok;
    return $ok;
}

# read_state(sid) -> this session's state, or undef (none, unreadable, torn, another schema or sid)
sub read_state {
    my ($sid) = @_;
    my $f = file($sid) // return undef;
    my $raw = util::read_file($f, $MAX_BYTES + 1) // return undef;
    return undef if length($raw) > $MAX_BYTES;
    my $j = eval { jsonc::decode($raw) };
    return undef unless ref $j eq 'HASH' && ($j->{schema} // '') eq state_schema() && ($j->{sid} // '') eq $sid;
    return $j;
}

# _update(sid, code, create) -> 1 when written: code changes the state (a fresh one with create)
# and returns true when anything changed.
sub _update {
    my ($sid, $code, $create) = @_;
    my $f = file($sid) // return 0;
    my $s = read_state($sid);
    return 0 if !$s && !$create;
    $s //= { schema => state_schema(), sid => $sid };
    return 0 unless $code->($s);
    $s->{updated_at} = _t(util::now());
    return _put($f, jsonc::encode_bytes($s) . "\n", 0600);
}

# ---------------------------------------------------------------- writers

# note_rows(sid, [row hash...]): cmd/log.pl, the mod's rows of one call. Only main rows of keep-warm
# and compaction count; a row older than what the state holds changes nothing in it.
sub note_rows {
    my ($sid, $rows) = @_;
    my @r = grep { ref $_ eq 'HASH' && !ref $_->{ev} && $ROWS{ $_->{ev} // '' } && ($_->{actor} // 'main') eq 'main' } @{ $rows || [] };
    return 0 unless @r;
    return _update($sid, sub { my ($s) = @_; my $ch = 0; $ch += _apply($s, $_) for @r; return $ch }, 1);
}

# the gap a ping or stop row belongs to: its start, from the row's gap_s (rounded to the second)
sub _same_gap { my ($kw, $gs) = @_; return defined $kw->{gap_start} && abs($kw->{gap_start} - $gs) <= 3 ? 1 : 0 }

sub _apply {
    my ($s, $r) = @_;
    my $t = util::parse_iso(ref $r->{ts} ? '' : $r->{ts} // '') // return 0;
    my $ch = 0;
    # a row after the session's end: it runs again (resumed in another process)
    if (defined _num($s->{ended_at}) && $t > $s->{ended_at}) { delete $s->{ended_at}; $ch = 1 }
    my $ev = $r->{ev};
    # a compaction a hook skipped (`skip` set) did not run
    return $ch if $ev eq 'compacted' && defined $r->{skip};
    if ($ev eq 'compacted') {
        return $ch if defined _num($s->{compacted_at}) && $t <= $s->{compacted_at};
        $s->{compacted_at} = _t($t);
        return 1;
    }
    my $kw = ref $s->{keep_warm} eq 'HASH' ? $s->{keep_warm} : undef;
    # out of order (two writers): a row older than the gap's latest one changes nothing
    return $ch if $kw && defined _num($kw->{last_at}) && $t < $kw->{last_at};
    my $gap = _num($r->{gap_s}) // 0;
    if ($ev eq 'keep_warm_start') {
        my $gs = $t - $gap;
        $s->{keep_warm} = { started_at => _t($t), gap_start => _t($gs), hours => _num($r->{hours}), n => 0, warm_at => _t($gs),
                            result => undef, stop => undef, last_at => _t($t) };
        return 1;
    }
    if ($ev eq 'keep_warm_ping') {
        # the row is written after the fork: it started ms before
        my $start = $t - (_num($r->{ms}) // 0) / 1000;
        my $gs = $start - $gap;
        $kw = $s->{keep_warm} = { started_at => undef, gap_start => _t($gs), hours => undef, n => 0, warm_at => _t($gs), stop => undef }
            unless $kw && _same_gap($kw, $gs);
        my $res = !ref $r->{result} && defined $r->{result} && $r->{result} =~ /\A[a-z-]{1,40}\z/ ? $r->{result} : 'error';
        @$kw{qw(n result last_at)} = (_num($r->{n}) // $kw->{n} // 0, $res, _t($t));
        $kw->{warm_at} = _t($start) if $res eq 'warm';
        # the gap's last warm ping and last fork-miss, kept apart from the latest ping: a warm ping's
        # cache outlives a later ping that failed (api-error, aborted, error, nothing-to-fork)
        $kw->{warm_ping} = [_t($start), _t($t)] if $res eq 'warm';
        $kw->{miss_ping} = [_t($start), _t($t)] if $res eq 'fork-miss';
        return 1;
    }
    # keep_warm_stop (one with no start before it, `no-idle-path`, is a gap of its own)
    my $gs = $t - $gap;
    $kw = $s->{keep_warm} = { started_at => undef, gap_start => _t($gs), hours => undef, n => 0, warm_at => _t($gs) }
        unless $kw && _same_gap($kw, $gs);
    my $why = !ref $r->{why} && defined $r->{why} && $r->{why} =~ /\A[a-z0-9-]{1,40}\z/ ? $r->{why} : 'other';
    $kw->{stop} = { why => $why, pings => _num($r->{pings}) // $kw->{n} // 0, at => _t($t) };
    $kw->{last_at} = _t($t);
    return 1;
}

# on_start(sid, transcript path): SessionStart, any source: the transcript (for `cache --sid`
# without --stdin) and the session live again (a resume keeps its id).
sub on_start {
    my ($sid, $tp) = @_;
    $tp = undef unless defined $tp && !ref $tp && $tp =~ m{\A/} && length($tp) <= 4096 && $tp !~ /[\x00-\x1f]/;
    return _update($sid, sub {
        my ($s) = @_;
        my $ch = 0;
        if (defined $tp && ($s->{transcript} // '') ne $tp) { $s->{transcript} = $tp; $ch = 1 }
        if (exists $s->{ended_at}) { delete $s->{ended_at}; $ch = 1 }
        return $ch;
    }, 1);
}

# on_end(sid): SessionEnd: the session's end, on a state already kept.
sub on_end {
    my ($sid) = @_;
    return _update($sid, sub { $_[0]{ended_at} = _t(util::now()); 1 }, 0);
}

# ---------------------------------------------------------------- the stable launcher shim

sub _shim_text {
    my ($target) = @_;
    my $b = ctx::brand();
    return "#!/bin/sh\n# $b: a fixed path to the installed plugin's helper, for status lines (README: the cache state in your status line); kept by its SessionStart hook.\nexec '$target' \"\$@\"\n";
}

# _shim_target(text) -> the launcher a shim of this form runs, or undef (not ours)
sub _shim_target {
    my ($t) = @_;
    return undef unless defined $t && $t =~ m{\A#!/bin/sh\n# [^\n]*kept by its SessionStart hook\.\nexec '(/[^'\n]*)' "\$\@"\n\z};
    return $1;
}

sub _vparts { my ($v) = @_; return defined $v && $v =~ /\A([0-9]+)\.([0-9]+)\.([0-9]+)/ ? ($1, $2, $3) : () }
# _vcmp(a, b) -> -1, 0, 1 by major.minor.patch; undef when either has no such form
sub _vcmp {
    my @a = _vparts($_[0]);
    my @b = _vparts($_[1]);
    return undef unless @a && @b;
    for my $i (0 .. 2) { return $a[$i] <=> $b[$i] if $a[$i] != $b[$i] }
    return 0;
}

# installed() -> 1 when this copy is one Claude Code installed (.../plugins/cache/<marketplace>/
# <name>/<version>, or .../plugins/synced/<x>/<name>, as hook.pl own_data_name reads it) and not a
# --plugin-dir load (settings::inline_key).
sub installed {
    return 0 if defined settings::inline_key();
    my $b = ctx::brand();
    my @s = grep { $_ ne '' } split m{/+}, ctx::root() // '';
    return 1 if @s >= 5 && $s[-5] eq 'plugins' && $s[-4] eq 'cache' && $s[-2] eq $b;
    return 1 if @s >= 4 && $s[-4] eq 'plugins' && $s[-3] eq 'synced' && $s[-1] =~ /\A\Q$b\E(?:~g[0-9]+)?\z/;
    return 0;
}

# keep_shim() -> what it did: written, same, newer-kept, foreign, dev-load, no-launcher, unquotable,
# no-home, failed. The shim points at this copy's launcher unless it points at a newer version's
# that still exists; one pointing at a launcher that is gone is pointed here again. A file there
# that is not such a shim is left alone.
sub keep_shim {
    return 'dev-load' unless installed();
    my $target = ctx::launcher();
    return 'no-launcher' unless -f $target;
    return 'unquotable' if $target =~ /['\x00-\x1f]/;
    my $shim = shim_path() // return 'no-home';
    my $want = _shim_text($target);
    if (-l $shim || (-e _ && !-f _)) { return 'foreign' }
    if (-e $shim) {
        my $have = util::read_file($shim, 4096);
        return 'same' if defined $have && $have eq $want;
        my $cur = _shim_target($have) // return 'foreign';
        if (-f $cur) {
            # the version of the copy it runs: <root>/scripts/<launcher> -> <root>/.claude-plugin/plugin.json
            my $m = eval { jsonc::decode(util::read_file(util::dirname(util::dirname($cur)) . '/.claude-plugin/plugin.json', $MAX_BYTES)) };
            my $c = _vcmp(ref $m eq 'HASH' ? $m->{version} : undef, ctx::version());
            return 'newer-kept' if defined $c && $c > 0;
        }
    }
    return _put($shim, $want, 0755) ? 'written' : 'failed';
}

# ---------------------------------------------------------------- prune

# stale(now) -> [{path, bytes, mtime}...]: the state files of sessions that ended more than
# $PRUNE_DAYS days ago (ended_at), those with no end not written for as long (a session that
# crashed never gets one; one still open with no keep-warm or compaction row that long loses only
# what `cache --sid` without --stdin reads), unreadable ones and temp files by the same age;
# `prune --apply` deletes them.
sub stale {
    my ($now) = @_;
    my $d = dir() // return ();
    return () if -l $d || !-d $d;
    my $cut = $now - $PRUNE_DAYS * 86400;
    my @out;
    for my $e (util::list_dir($d)) {
        my $p = "$d/$e";
        my @st = lstat $p or next;
        next if -l _ || !-f _;
        my $at;
        if ($e =~ /\A(.+)\.v1\.json\z/ && sid_ok($1)) {
            my $s = read_state($1);
            $at = ($s ? _num($s->{ended_at}) : undef) // $st[9];
        } elsif ($e =~ /\A\..+\.v1\.json\.[0-9]+\.[0-9a-f]{4}\z/) {
            $at = $st[9];
        } else { next }
        push @out, { path => $p, bytes => $st[7], mtime => $st[9] } if $at < $cut;
    }
    return @out;
}

# ---------------------------------------------------------------- the reader

# last_main(transcript) -> {at, ttl} of the last main api-request line (querySource
# repl_main_thread…; ttl from its last cache_control breakpoint, 5m when that names none, undef
# with none), or undef. Reads the last 256 KiB, then 2 MiB when no such line was in it.
sub last_main {
    my ($tp) = @_;
    return undef unless defined $tp && !ref $tp && $tp =~ m{\A/} && -f $tp;
    my $size = -s _;
    for my $n (@TAIL) {
        my $tail = util::read_tail($tp, $n) // return undef;
        my @l = split /\n/, $tail;
        for (my $i = $#l; $i >= 0; $i--) {
            next unless index($l[$i], '"api-request"') >= 0;
            my $j = eval { jsonc::decode($l[$i]) };
            next unless ref $j eq 'HASH' && ($j->{type} // '') eq 'api-request';
            next unless !ref $j->{querySource} && ($j->{querySource} // '') =~ /\Arepl_main_thread(?::|\z)/;
            my $at = util::parse_iso(!ref $j->{timestamp} ? $j->{timestamp} // '' : '') // next;
            my $ttl;
            if (ref $j->{cacheControl} eq 'ARRAY' && @{ $j->{cacheControl} }) {
                my $last = $j->{cacheControl}[-1];
                my $v = ref $last eq 'HASH' && ref $last->{value} eq 'HASH' ? $last->{value}{ttl} : undef;
                $ttl = defined $v && !ref $v && $TTL_S{$v} ? $v : '5m';
            }
            return { at => $at, ttl => $ttl };
        }
        last if $size <= $n;
    }
    return undef;
}

sub _int { my ($v) = @_; return defined $v ? int($v) : undef }

# _ping(kw state, warm | fork-miss) -> [start, end] of the gap's last ping with that result, or undef
sub _ping {
    my ($kw, $res) = @_;
    my $p = $kw->{ $res eq 'warm' ? 'warm_ping' : 'miss_ping' };
    return undef unless ref $p eq 'ARRAY' && defined _num($p->[0]);
    return [_num($p->[0]), _num($p->[1])];
}

# report(sid => S, input => status-line JSON or undef, now => epoch) -> the `<plugin>-cache/v1` object
sub report {
    my (%o) = @_;
    my $now = $o{now} // util::now();
    my %r = (schema => schema(), sid => undef, now => int($now), state => 'unknown', why => 'no-data', ttl => undef, source => undef,
             last => undef, expires_at => undef, seconds_left => undef, age_s => undef, keep_warm => undef, ended_at => undef,
             plugin_version => ctx::version());
    my $in = ref $o{input} eq 'HASH' ? $o{input} : undef;
    my $sid = $o{sid};
    my $isid = $in && !ref $in->{session_id} ? $in->{session_id} : undef;
    $sid //= $isid;
    # --sid and the status line's session_id must agree
    if (!defined $sid || !sid_ok($sid) || (defined $isid && $sid ne $isid)) {
        $r{why} = 'bad-sid';
        return \%r;
    }
    $r{sid} = $sid;
    my $st = read_state($sid);
    my $pc = $in && ref $in->{prompt_cache} eq 'HASH' ? $in->{prompt_cache} : undef;
    my $tp = $in && !ref $in->{transcript_path} && defined $in->{transcript_path} ? $in->{transcript_path} : $st ? $st->{transcript} : undef;
    my $main = last_main($tp);
    my $kw = $st && ref $st->{keep_warm} eq 'HASH' ? $st->{keep_warm} : undef;

    # the main session's last request: Claude Code's ledger, else the transcript
    my ($src, $ttl, $exp, $main_at, $anchor);
    if ($pc && jsonc::is_bool($pc->{caching_observed}) && !$pc->{caching_observed}) {
        $r{why} = 'caching-off';
        return _with_kw(\%r, $kw, $st, $now, undef, 1);
    }
    if ($pc && defined _num($pc->{expires_at})) {
        $src = 'claude-code';
        $ttl = !ref $pc->{ttl} && defined $pc->{ttl} && $TTL_S{ $pc->{ttl} } ? $pc->{ttl} : undef;
        $exp = _num($pc->{expires_at});
        $main_at = $main ? $main->{at} : undef;
        # without the transcript, the last request started no later than expires_at - ttl
        $anchor = $main_at // (defined $ttl ? $exp - $TTL_S{$ttl} : undef);
    } elsif ($main && defined $main->{ttl}) {
        ($src, $ttl, $main_at) = ('transcript', $main->{ttl}, $main->{at});
        $exp = $main_at + $TTL_S{$ttl};
        $anchor = $main_at;
    }
    my $last = defined $main_at ? { kind => 'main', at => $main_at } : undef;
    my $why;
    # the plugin's keep-warm pings, when they started after the last main request: the gap's last
    # warm one and its last fork-miss, whatever pings came after them; the later of the two decides
    my $after = sub {
        my ($p) = @_;
        return 0 unless defined $p;
        return defined $main_at ? $p->[0] > $main_at : defined $anchor ? ($p->[1] // $p->[0]) + $TOUCH_SLACK_S >= $anchor : 1;
    };
    my ($wp, $mp) = $kw ? (_ping($kw, 'warm'), _ping($kw, 'fork-miss')) : ();
    $wp = undef unless $after->($wp);
    $mp = undef unless $after->($mp);
    if ($mp && (!$wp || $mp->[0] > $wp->[0])) {
        # the ping did not read the main prefix: the main cache was found cold (v0.1.7 probes Q3:
        # the next main request missed in 17 of 17 such cases)
        $last = { kind => 'keep_warm', at => $mp->[0] };
        $src //= 'plugin';
        $why = 'fork-miss';
    } elsif ($wp) {
        $last = { kind => 'keep_warm', at => $wp->[0] };
        if (!defined $src) { ($src, $ttl, $exp) = ('plugin', '1h', $wp->[0] + $TTL_S{'1h'}) }
        elsif (($ttl // '') eq '1h') { $exp = _max($exp, $wp->[0] + $TTL_S{'1h'}) }
    }
    # a compaction after the last request: the next one writes the cache anew
    my $ref = $last ? $last->{at} : $anchor;
    my $cat = $st ? _num($st->{compacted_at}) : undef;
    $why //= 'compacted' if defined $src && defined $cat && (!defined $ref || $cat > $ref);
    $r{source} = $src;
    $r{ttl} = $ttl;
    if ($last) {
        $r{last} = { kind => $last->{kind}, at => int($last->{at}), source => ($last->{kind} eq 'keep_warm' ? 'plugin' : $src) };
        $r{age_s} = _int($now - $last->{at});
    }
    if (defined $why) { @r{qw(state why)} = ('cold', $why) }
    elsif (!defined $src || !defined $exp) { @r{qw(state why)} = ('unknown', 'no-data') }
    else {
        $r{expires_at} = int($exp);
        $r{seconds_left} = $exp > $now ? int($exp - $now) : 0;
        @r{qw(state why)} = $exp > $now ? ('warm', undef) : ('cold', 'expired');
    }
    return _with_kw(\%r, $kw, $st, $now, $main_at, defined $pc);
}

# _with_kw(report, kw state, state, now, last main request, live): keep_warm and ended_at
sub _with_kw {
    my ($r, $kw, $st, $now, $main_at, $live) = @_;
    my $end = $st ? _num($st->{ended_at}) : undef;
    $end = undef if $live || (defined $end && defined $main_at && $main_at > $end);
    $r->{ended_at} = _int($end);
    return $r unless $kw;
    my $hours = _num($kw->{hours});
    my $max = defined $hours ? int(($hours * 60 - 1) / 50) : undef;
    $max = 0 if defined $max && $max < 0;
    my $started = _num($kw->{started_at});
    my $stop = ref $kw->{stop} eq 'HASH' ? $kw->{stop} : undef;
    my $warm = _num($kw->{warm_at}) // _num($kw->{gap_start});
    # warming runs from its start row to its stop row; a gap whose stop never came (a crash) ends at
    # the 58-minute bound of its last warm request, at the cutoff, at the session's end, or at a main
    # request after its last row
    my $active = defined $started && !$stop && !defined $end && defined $warm && $now <= $warm + $LATEST_S + 120
                 && (!defined $hours || $now < (_num($kw->{gap_start}) // $started) + $hours * 3600 + 600)
                 && !(defined $main_at && $main_at > (_num($kw->{last_at}) // $started)) ? 1 : 0;
    $r->{keep_warm} = {
        active => jsonc::bool($active), n => _num($kw->{n}) // 0, max => $max, hours => $hours,
        gap_started_at => _int(_num($kw->{gap_start})), next_due_at => ($active ? int($warm + $PING_S) : undef),
        last_result => (defined $kw->{result} && !ref $kw->{result} ? $kw->{result} : undef),
        stop => ($stop ? { why => $stop->{why}, pings => _num($stop->{pings}) // 0, at => _int(_num($stop->{at})) } : undef),
    };
    return $r;
}

sub _span {
    my ($s) = @_;
    return int($s / 86400) . 'd' if $s >= 86400;
    return int($s / 3600) . 'h' if $s >= 3600;
    return int($s / 60) . 'm';
}

# line(report) -> the one plain line (no newline), or '' when the state is unknown:
# `cache 1h warm 42m left ↻3/7`, `cache 1h cold (expired 12m ago)`, `cache cold (compacted)`.
sub line {
    my ($r) = @_;
    return '' if $r->{state} eq 'unknown';
    my $t = defined $r->{ttl} ? " $r->{ttl}" : '';
    my $kw = $r->{keep_warm};
    my $ping = $kw && $kw->{active} ? ' ↻' . $kw->{n} . (defined $kw->{max} ? "/$kw->{max}" : '') : '';
    return "cache$t warm " . int(($r->{seconds_left} + 59) / 60) . "m left$ping" if $r->{state} eq 'warm';
    return "cache$t cold (expired " . _span($r->{now} - $r->{expires_at}) . ' ago)' if $r->{why} eq 'expired';
    return 'cache cold (' . ($r->{why} eq 'fork-miss' ? 'keep-warm ping missed' : $r->{why}) . ')';
}

1;
