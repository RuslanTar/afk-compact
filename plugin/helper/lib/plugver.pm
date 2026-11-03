package plugver;
# lib/plugver.pm: which plugin copy this session runs against the one sessions started later
# load (0.1.3 version skew). Owner: WP-core. Claude Code fixes a plugin's folder when a session
# loads it, so a long session keeps running an older copy after an install (15 sessions after the
# 0.1.2 install; one ran 0.1.0 for about 18 h).
#   <root>/.sessions/loads/<load epoch>_<pid>-<lstart epoch>_<version>_<scope tag>.json
#     {v, plugin_version, plugin_root, scope, host, machine?, session_id, source, ts}: one record
#     per Claude Code process and plugin version, written by SessionStart (every source) when this
#     process has no record of this version yet. So a /clear, /resume or compaction in a process
#     that keeps its copy adds none, and a process whose copy changed (/reload-plugins) adds one.
#     None when the process walk did not find Claude Code: the pid is then the helper's parent (a
#     hook shell), which no later start shares, so a /clear would add a fresh record of an old copy.
#     The name holds the load time, the version and the scope tag, so a reader sorts and walks the
#     names and reads only a few files.
#   scope(cwd) -> {kind, tag}: the install this copy belongs to. A copy in Claude Code's plugin
#     cache (<config>/plugins/cache/<marketplace>/<name>/<version>) is `project` when that config's
#     plugins/installed_plugins.json holds a project or local entry of the plugin for this session's
#     project folder (CLAUDE_PROJECT_DIR, else the hook's cwd), else `user`; any other folder (a
#     --plugin-dir run, a checkout) is `dir`, compared with loads of that same folder only. The tag
#     (8 hex of sha256 over the kind, the cache folder of the plugin's versions or the folder, and
#     the project) keeps another config folder, project pin or folder apart: a project pinned to
#     another version is never compared with the user install.
#   machine() -> 16 hex of sha256 over the machine id (macOS IOPlatformUUID, Linux
#     /etc/machine-id or /var/lib/dbus/machine-id), or undef when none is readable; read once per
#     process and kept in the load record, so a reader of that process takes it from there. A
#     record matches this machine by its machine field; a record without one (or a process with
#     none) by the host name, so a rename of the host (macOS adds -2, -3 ... after a name
#     conflict) hides no record that has the id.
#   note_load(sid, source, cwd) -> 1 when a record was written, else 0. Before it writes, it drains
#     at most $PRUNE_BATCH names of a folder an earlier prune moved aside, and once a day prunes;
#     both under one lock (loads-drop/.lock), so a drain never meets a prune halfway.
#   prune: keeps the record of every pid that runs (its process may start another session: the
#     per-process dedupe), the newest record per version and scope ($GROUP_MAX groups) and the
#     newest $KEEP_MAX records of the last $WINDOW_S; drops the rest and records dated over
#     $FUTURE_S ahead. Up to $PRUNE_BATCH drops are unlinked in place; more move the folder aside
#     (<root>/.sessions/loads-drop/<epoch>-<pid>, the kept records moved back), which later starts
#     drain in bounded batches. So a hook never unlinks more than a batch, and a reader lists a
#     folder of at most a few hundred names.
#   skew() -> undef | {own, ref, since, newest}: the reference is the version of the newest load
#     of this machine and scope; undef (no notice) unless all of: both versions readable and
#     different, the newest load at most $WINDOW_S old (loads dated over $FUTURE_S ahead are not
#     read), and this copy installed before that load (its .claude-plugin/plugin.json mtime; a copy
#     installed later is the newer one, e.g. after /reload-plugins). since = the oldest load of the
#     reference version after the newest load of another version (within the names walked).
#   line() -> `this session runs <own>; sessions started since <stamp> run <ref>: /reload-plugins`
#     or undef. Bounded: one directory listing, at most $READ_MAX + 1 small reads, one stat;
#     installed_plugins.json and the machine id only when this process has no load record; never dies.
use strict;
use warnings;
use utf8;

# A week: the sessions seen lived up to about 2.5 days (started 2026-10-30 07:33, still running
# 2026-11-01 22:00), so every skew inside a session's life is covered three times over; a newest
# load older than that no longer says what is installed (a later uninstall, update or rollback
# with no session started since is not seen), so it is not trusted.
our $WINDOW_S = 7 * 86400;
# A clock that ran ahead once must not leave a load that stays the newest for good.
our $FUTURE_S = 600;
our $READ_MAX = 8;
our $NAME_MAX = 64;
our $KEEP_MAX = 200;
our $GROUP_MAX = 64;
our $PRUNE_EVERY_S = 86400;
# About 40 ms of unlinks on a loaded Mac (75 us each).
our $PRUNE_BATCH = 500;
my $VER_RE = qr/[0-9A-Za-z][0-9A-Za-z.+-]{0,39}/;
my $NAME_RE = qr/\A(\d{1,12})_(\d+-\d+)_($VER_RE)_([0-9a-f]{8})\.json\z/;

sub dir { return sessions::dir() . '/loads' }
sub drop_dir { return sessions::dir() . '/loads-drop' }

sub _ver_ok { my ($v) = @_; return defined $v && !ref $v && $v =~ /\A$VER_RE\z/ ? 1 : 0 }

# Test seams (STORE_TEST_MODE only): small values stand in for the batch and the two caps.
sub _seam { my ($k, $v) = @_; return util::test_mode() && ($ENV{$k} // '') =~ /\A([1-9][0-9]{0,5})\z/ ? $1 : $v }
sub _batch { return _seam('STORE_TEST_LOADS_BATCH', $PRUNE_BATCH) }

# _loads() -> [[epoch, key, version, tag, name] ...], newest first (ties: name order, reversed)
sub _loads {
    my @l;
    for my $n (util::list_dir(dir())) {
        push @l, [0 + $1, $2, $3, $4, $n] if $n =~ $NAME_RE;
    }
    return [sort { $b->[0] <=> $a->[0] || $b->[4] cmp $a->[4] } @l];
}

sub _real {
    my ($p) = @_;
    return undef unless defined $p && !ref $p && $p =~ m{\A/};
    require Cwd;
    return Cwd::abs_path($p) // $p;
}

sub _same_path {
    my ($a, $b) = @_;
    return 0 unless defined $a && defined $b && !ref $a && !ref $b;
    return 1 if $a eq $b;
    my ($x, $y) = (_real($a), _real($b));
    return defined $x && defined $y && $x eq $y ? 1 : 0;
}

my $SCOPE;
sub scope {
    my ($cwd) = @_;
    return $SCOPE if $SCOPE;
    my $root = ctx::root();
    my ($kind, $key) = ('dir', "dir\n$root");
    if ($root =~ m{\A(.+)/plugins/cache/([^/]+)/([^/]+)/[^/]+\z}) {
        my ($cfg, $mkt, $name) = ($1, $2, $3);
        my $parent = util::dirname($root);
        ($kind, $key) = ('user', "user\n$parent");
        my $pd = defined $ENV{CLAUDE_PROJECT_DIR} && $ENV{CLAUDE_PROJECT_DIR} =~ m{\A/} ? $ENV{CLAUDE_PROJECT_DIR}
               : defined $cwd && !ref $cwd && $cwd =~ m{\A/} ? $cwd : do { require Cwd; Cwd::getcwd() };
        my $raw = util::read_file("$cfg/plugins/installed_plugins.json", 16 << 20);
        my $j = defined $raw ? eval { jsonc::decode($raw) } : undef;
        my $list = ref $j eq 'HASH' && ref $j->{plugins} eq 'HASH' ? $j->{plugins}{"$name\@$mkt"} : undef;
        for my $e (ref $list eq 'ARRAY' ? @$list : ()) {
            next unless ref $e eq 'HASH' && ($e->{scope} // '') =~ /\A(?:project|local)\z/ && _same_path($e->{projectPath}, $pd);
            ($kind, $key) = ('project', "project\n$parent\n$e->{projectPath}");
            last;
        }
    }
    return $SCOPE = { kind => $kind, tag => substr(sha::hex256($key), 0, 8) };
}

my $MACHINE;
sub machine {
    return $MACHINE->[0] if $MACHINE;
    my $raw;
    if (util::test_mode() && defined $ENV{STORE_TEST_MACHINE_ID}) {
        $raw = $ENV{STORE_TEST_MACHINE_ID};
    } elsif ($^O eq 'darwin') {
        my $io = -x '/usr/sbin/ioreg' ? '/usr/sbin/ioreg' : util::which('ioreg');
        my $r = defined $io ? util::run([$io, '-rd1', '-c', 'IOPlatformExpertDevice'], timeout_ms => 2000, env => { LC_ALL => 'C' }) : undef;
        $raw = $1 if $r && $r->{exit} == 0 && $r->{out} =~ /"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f-]{16,64})"/;
    } else {
        for my $f ('/etc/machine-id', '/var/lib/dbus/machine-id') {
            my $t = util::read_file($f, 4096) // next;
            if ($t =~ /\A\s*([0-9A-Fa-f]{16,64})\s*\z/) { $raw = $1; last }
        }
    }
    $raw = undef unless defined $raw && $raw =~ /\A[0-9A-Za-z-]{1,64}\z/;
    $MACHINE = [defined $raw ? substr(sha::hex256("machine\n" . lc $raw), 0, 16) : undef];
    return $MACHINE->[0];
}

# _same_machine(record, machine) -> 1 when the record was written on this machine
sub _same_machine {
    my ($j, $m) = @_;
    my $rm = $j->{machine};
    return $rm eq $m ? 1 : 0 if defined $rm && !ref $rm && defined $m;
    my $h = $j->{host};
    return defined $h && !ref $h && $h eq identity::host() ? 1 : 0;
}

sub _alive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid > 1;
    return kill(0, $pid) || $!{EPERM} ? 1 : 0;
}

sub note_load {
    my ($sid, $source, $cwd) = @_;
    return 0 unless rc::root_ok('handoff_root');
    my $v = ctx::version();
    return 0 unless _ver_ok($v);
    my $c = rc::claude();
    return 0 unless ref $c eq 'HASH' && defined $c->{pid} && $c->{found};
    my $key = sessions::_key($c);
    my $all = _loads();
    return 0 if grep { $_->[1] eq $key && $_->[2] eq $v } @$all;
    my $now = util::now();
    eval { _drain($now) };
    eval { _prune($all, $now) };
    my $sc = scope($cwd);
    my $m = machine();
    my $rec = jsonc::obj(v => 1, plugin_version => $v, plugin_root => ctx::root(), scope => $sc->{kind},
                         host => identity::host(), (defined $m ? (machine => $m) : ()),
                         session_id => $sid, source => $source, ts => util::iso($now));
    return util::write_excl(dir() . '/' . int($now) . "_${key}_${v}_$sc->{tag}.json", jsonc::encode_bytes($rec) . "\n", 0600) ? 1 : 0;
}

# _prune(loads, now) -> number of records dropped; at most once per $PRUNE_EVERY_S (the mtime of
# loads/.pruned), never more than a batch of unlinks.
sub _prune {
    my ($all, $now) = @_;
    my $d = dir();
    my @st = stat("$d/.pruned");
    return 0 if @st && $st[9] > $now - $PRUNE_EVERY_S && $st[9] <= $now + $FUTURE_S;
    my $n = _locked(sub { _prune_locked($all, $now) });
    return $n // 0;
}

# _locked(code) -> code's result under loads-drop/.lock, or undef when another process holds it
# (a lock left over 120 s by a killed hook is removed; the next start takes it). The prune and the
# drain share it: a drain never reads a folder a prune is still moving records out of.
sub _locked {
    my ($code) = @_;
    my $lock = drop_dir() . '/.lock';
    if (!util::write_excl($lock, "$$\n", 0600)) {
        my @l = stat $lock;
        unlink $lock if @l && $l[9] < time - 120;
        return undef;
    }
    my $n = eval { $code->() };
    unlink $lock;
    return $n;
}

sub _prune_locked {
    my ($all, $now) = @_;
    my $d = dir();
    my (%keep, %seen);
    my ($groups, $recent) = (0, 0);
    my ($gmax, $kmax) = (_seam('STORE_TEST_LOADS_GROUPS', $GROUP_MAX), _seam('STORE_TEST_LOADS_KEEP', $KEEP_MAX));
    for my $r (@$all) {
        my ($e, $k, $v, $t, $n) = @$r;
        if (_alive($k =~ /\A(\d+)-/ ? $1 : 0)) { $keep{$n} = 1; next }
        next if $e > $now + $FUTURE_S;
        if (!$seen{"$v $t"}++ && $groups++ < $gmax) { $keep{$n} = 1; next }
        $keep{$n} = 1 if $now - $e <= $WINDOW_S && $recent++ < $kmax;
    }
    my @drop = grep { !$keep{$_} } map { $_->[4] } @$all;
    my $ok = 1;
    if (@drop <= _batch()) {
        unlink "$d/$_" for @drop;
    } else {
        my $aside = drop_dir() . '/' . int($now) . "-$$";
        if (rename($d, $aside)) {
            util::mkdir_p($d);
            rename("$aside/$_", "$d/$_") for keys %keep;
        } else {
            $ok = 0;
        }
    }
    if ($ok) {
        util::write_atomic("$d/.pruned", "\n", 0600);
        utime(int($now), int($now), "$d/.pruned");
    }
    return $ok ? scalar @drop : 0;
}

# _drain(now) -> names handled: at most a batch of the oldest folder a prune moved aside; a record
# dated from a minute before the move on (written while the folder moved) goes back to loads/.
# Not while a prune holds the lock (it may not have moved its kept records back yet).
sub _drain {
    my ($now) = @_;
    my $dd = drop_dir();
    return 0 unless grep { /\A\d+-\d+\z/ } util::list_dir($dd);
    return _locked(sub { _drain_locked($now) }) // 0;
}

sub _drain_locked {
    my ($now) = @_;
    my $dd = drop_dir();
    my ($a) = sort grep { /\A\d+-\d+\z/ } util::list_dir($dd);
    return 0 unless defined $a;
    my $at = ($a =~ /\A(\d+)-/)[0];
    my $p = "$dd/$a";
    my $max = _batch();
    my @n = util::list_dir_max($p, $max);
    for my $n (@n) {
        if ($n =~ $NAME_RE && $1 >= $at - 60 && $1 <= $at + $FUTURE_S && !-e dir() . "/$n") { rename("$p/$n", dir() . "/$n"); next }
        unlink "$p/$n";
    }
    rmdir $p if @n < $max;
    return scalar @n;
}

# installed() -> this copy's install time: the mtime of its .claude-plugin/plugin.json, or undef
sub installed {
    my @st = stat(ctx::root() . '/.claude-plugin/plugin.json');
    return @st ? $st[9] : undef;
}

# _self(loads) -> (scope tag, machine) of this process: from its own load record when it has one
# (written at its first start), else measured now (the machine also when that record has none).
sub _self {
    my ($all) = @_;
    my $c = rc::claude();
    my $key = ref $c eq 'HASH' && defined $c->{pid} ? sessions::_key($c) : '';
    my $own = ctx::version();
    my ($r) = grep { $_->[1] eq $key && $_->[2] eq $own } @$all;
    if ($r) {
        my $raw = util::read_file(dir() . "/$r->[4]", 64 * 1024);
        my $j = defined $raw ? eval { jsonc::decode($raw) } : undef;
        my $m = ref $j eq 'HASH' && defined $j->{machine} && !ref $j->{machine} ? $j->{machine} : undef;
        return ($r->[3], $m // machine());
    }
    return (scope()->{tag}, machine());
}

sub skew {
    my $own = ctx::version();
    return undef unless _ver_ok($own) && rc::root_ok('handoff_root');
    my $now = util::now();
    my $loads = _loads();
    my ($tag, $mach) = _self($loads);
    my @all = grep { $_->[3] eq $tag && $_->[0] <= $now + $FUTURE_S } @$loads;
    splice(@all, $NAME_MAX) if @all > $NAME_MAX;
    my ($ri, $reads) = (undef, 0);
    for my $i (0 .. $#all) {
        last if $reads++ >= $READ_MAX;
        my $raw = util::read_file(dir() . '/' . $all[$i][4], 64 * 1024) // next;
        my $j = eval { jsonc::decode($raw) };
        next unless ref $j eq 'HASH' && _same_machine($j, $mach) && ($j->{plugin_version} // '') eq $all[$i][2];
        $ri = $i;
        last;
    }
    return undef unless defined $ri;
    my ($newest, $ref) = @{ $all[$ri] }[0, 2];
    return undef if $ref eq $own;
    return undef if $now - $newest > $WINDOW_S;
    my $inst = installed();
    return undef if defined $inst && $inst >= $newest;
    my $since = $newest;
    for my $i ($ri + 1 .. $#all) {
        last unless $all[$i][2] eq $ref;
        $since = $all[$i][0];
    }
    return { own => $own, ref => $ref, since => $since, newest => $newest };
}

sub line {
    my $s = eval { skew() } or return undef;
    return sprintf('this session runs %s; sessions started since %s run %s: /reload-plugins', $s->{own}, util::stamp($s->{since}), $s->{ref});
}

1;
