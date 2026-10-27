package restart;
# lib/restart.pm: restart on update (SESSION-RESTART), the helper's part. Owner: WP-core.
# The setting `restart_on_update` (D1, a consent key); the session file of the fresh permission
# mode (D10); the gate (G3, G3a, G3b, G4, G5b, G7, G12 and the mode checks of G10, §4.1); the
# two notes of the terminal route, in the launcher's file contract (protocol 1,
# tests/launcher/README.md: launch note `restart.note` written as `restart.note.tmp` then
# renamed, `sid` bound once with O_EXCL); the carry note `<watch>/<sid>/restart.json` (§5.1);
# the claim in the new load (§5.2); the background route's detached `claude respawn` (§2.2 step 3)
# and its cancel; the scan for background restarts that failed after the kill (§2.3) and for the
# launcher's refusals (§3.5). Rows and replies hold no argv, path, model or env value.
use strict;
use warnings;
use utf8;
use POSIX ();
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);

our $PROTO = 1;
# The ship gate of live probe RS-P1 (SESSION-RESTART D3, §3.4, §8.4 step 1): the terminal route
# (the plugin's own /exit, the launcher relaunches) stays off until RS-P1 passes, including its
# exit-dialog run. 0: an `on` session that passes every gate on that route logs
# `refresh_skipped {why: fg-not-shipped}` and goes on as if the setting were shadow. Flip to 1
# once RS-P1 passes. Test seam: STORE_TEST_RESTART_FG=1 in test mode.
our $FG_ROUTE = 0;
sub fg_route { return 1 if $FG_ROUTE; return util::test_mode() && ($ENV{STORE_TEST_RESTART_FG} // '') eq '1' ? 1 : 0 }

# G3: the launcher must be an ancestor of this claude within this many processes.
our $ANCESTOR_MAX = 8;
# G3a: the launcher's own cap (contract §5: 3 relaunches in 3600 s).
our ($CAP_N, $CAP_S) = (3, 3600);
# §5.2, §2.3: a carry note older than this is not claimed; a `sent` one is a failure.
our $CLAIM_MAX_MS = 600000;
# §2.3: a non-zero respawn result this old whose note is still `sent` is a failure after the kill
# (before the kill the mod's watchdog settles the note within seconds).
our $AFTERKILL_MS = 60000;
# /status lists failed background restarts and launcher refusals this recent.
our $REPORT_MS = 7 * 86400 * 1000;
# D10: the PostCompact record may read up to this much earlier than the compaction's start (a perl
# without Time::HiRes keeps whole seconds).
our $MODE_SLACK_MS = 1000;
# §2.2 step 3: the respawn client's output kept, and its time bound.
our $OUT_MAX = 65536;
our $RESPAWN_MS = 180000;
# G5b: a Claude Code cache file larger than this is not read (as deps.ts SERVED_MAX_CHARS).
our $HOLD_MAX = 8000000;

# R5: the names `/restart` removes from the respawn client's environment (`$st`, Claude Code
# 2.1.311), besides CLAUDE_JOB_DIR and every CLAUDE_BG_* (the prefix rule covers its twelve).
our @ST = qw(CLAUDE_CODE_SESSION_KIND CLAUDE_CODE_SESSION_NAME CLAUDE_CODE_RESUME_INTERRUPTED_TURN
             CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS CLAUDE_CODE_RESUME_PROMPT
             CLAUDE_CODE_RESUME_SHOWS_CUT_OFF_CALLS CLAUDE_CODE_RESUME_REASON CLAUDE_CODE_RESUME_SOURCE_ALIVE
             CLAUDE_CODE_RELAUNCH_HOME_TRUST);
# B6: the respawn client's failure codes (and its no-op), found in its output; the specific ones
# first, the generic spawn failure last.
our @B6 = qw(job_respawn_kill_unconfirmed cwd_gone crashed_during_spawn in_flight_spawn_failed
             resume_session_live_elsewhere stopped_during_respawn already_alive job_respawn_spawn_failed);

our @MODES = qw(acceptEdits auto bypassPermissions default dontAsk plan);
our @EFFORTS = qw(low medium high xhigh max);
my %MODE = map { $_ => 1 } @MODES;
my %EFFORT = map { $_ => 1 } @EFFORTS;
our @L_STATES = qw(armed exiting go cancelled);
our @C_STATES = qw(armed exiting go sent cancelled failed reported);
my %L_STATE = map { $_ => 1 } @L_STATES;
my %C_STATE = map { $_ => 1 } @C_STATES;
# States a note never leaves (a later transition is refused).
my %L_FINAL = (cancelled => 1);
my %C_FINAL = (cancelled => 1, failed => 1, reported => 1);

# ---------------------------------------------------------------- patterns (contract §4)
sub is_sid    { my ($v) = @_; return defined $v && !ref $v && $v =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/ ? 1 : 0 }
sub is_hex16  { my ($v) = @_; return defined $v && !ref $v && $v =~ /\A[0-9a-f]{16}\z/ ? 1 : 0 }
sub is_ver    { my ($v) = @_; return defined $v && !ref $v && length($v) <= 32 && $v =~ /\A[0-9]+\.[0-9]+\.[0-9]+\z/ ? 1 : 0 }
sub is_model  { my ($v) = @_; return defined $v && !ref $v && ($v eq '' || $v =~ m{\A[A-Za-z0-9._:/\[\]-]{1,100}\z}) ? 1 : 0 }
sub is_effort { my ($v) = @_; return defined $v && !ref $v && ($v eq '' || $EFFORT{$v}) ? 1 : 0 }
sub is_mode   { my ($v) = @_; return defined $v && !ref $v && $MODE{$v} ? 1 : 0 }
sub is_short  { my ($v) = @_; return defined $v && !ref $v && $v =~ /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/ ? 1 : 0 }
sub is_ms     { my ($v) = @_; return defined $v && !ref $v && $v =~ /\A[1-9][0-9]{0,15}\z/ ? 1 : 0 }

# vcmp(a, b) -> -1, 0 or 1 for two x.y.z versions
sub vcmp {
    my ($a, $b) = @_;
    my @x = split /\./, $a;
    my @y = split /\./, $b;
    for my $i (0 .. 2) { my $c = ($x[$i] // 0) <=> ($y[$i] // 0); return $c if $c }
    return 0;
}

sub now_ms { return int(util::now() * 1000) }

# ---------------------------------------------------------------- names and folders
# The launch env name, as tools/build's launch_env(): the plugin name in upper case, `-` as `_`,
# then `_LAUNCH` (the launcher exports it; the mod reads it from launch.gen.ts).
sub launch_env_name {
    (my $n = uc(ctx::brand() // '')) =~ s/-/_/g;
    return $n . '_LAUNCH';
}

# runtime_dir() -> <base>/<plugin>-<uid> as the launcher makes it ($XDG_RUNTIME_DIR, else
# $TMPDIR, else /tmp; trailing `/` removed), or undef when the base is not absolute.
sub runtime_dir {
    my $base = $ENV{XDG_RUNTIME_DIR};
    $base = $ENV{TMPDIR} if !defined $base || $base eq '';
    $base = '/tmp' if !defined $base || $base eq '';
    $base =~ s{(?<=.)/+\z}{};
    return undef unless $base =~ m{\A/};
    $base = '' if $base eq '/';
    return "$base/" . (ctx::brand() // 'plugin') . "-$<";
}

# private_dir(path) -> undef for a folder that is not a symlink, is owned by this uid and has
# mode 0700; else the reason (`relative`, `symlink`, `missing`, `owner`, `mode`).
sub private_dir {
    my ($p) = @_;
    return 'relative' unless defined $p && $p =~ m{\A/};
    return 'symlink' if -l $p;
    my @st = stat $p;
    return 'missing' unless @st && -d _;
    return 'owner' unless $st[4] == $<;
    return 'mode' unless ($st[2] & 07777) == 0700;
    return undef;
}

sub carry_path  { return "$_[0]/restart.json" }
sub mode_path   { return "$_[0]/restart-mode.json" }
sub result_path { return "$_[0]/restart-respawn.json" }
sub out_path    { return "$_[0]/restart-respawn.out" }
sub pid_path    { return "$_[0]/restart-respawn.pid" }

sub _json_file {
    my ($path, $max) = @_;
    return undef if -l $path;
    my $raw = util::read_file($path, $max) // return undef;
    my $j = eval { jsonc::decode($raw) };
    return ref $j eq 'HASH' ? $j : undef;
}

# ---------------------------------------------------------------- the session file (D10, G12)
# <watch>/<sid>/restart-mode.json (0600): the newest main Stop's permission_mode and effort level
# with its time, the newest main PostCompact's permission_mode with its time, and the transcript
# path the hooks noted. Only names the patterns allow are kept; the path stays in this private
# file and never enters a row.
sub read_mode { my ($d) = @_; return defined $d ? (_json_file(mode_path($d)) // {}) : {} }

sub _write_mode {
    my ($d, $m) = @_;
    my @k = qw(v stop_mode stop_effort stop_at post_mode post_at transcript);
    $m->{v} = 1;
    util::write_atomic(mode_path($d), jsonc::encode_bytes(jsonc::obj(map { ($_ => $m->{$_}) } @k)) . "\n", 0600);
}

sub _payload_mode {
    my ($p) = @_;
    my $m = $p->{permission_mode};
    return is_mode($m) ? $m : undef;
}

sub _payload_transcript {
    my ($p) = @_;
    my $t = $p->{transcript_path};
    return (defined $t && !ref $t && $t =~ m{\A/} && $t !~ /[\n\r]/ && length($t) <= 4096) ? $t : undef;
}

# note_stop(sid_dir, payload): a main Stop (no agent_id) keeps its mode, effort and transcript.
sub note_stop {
    my ($d, $p) = @_;
    return 0 unless defined $d && ref $p eq 'HASH' && !defined $p->{agent_id};
    my $m = read_mode($d);
    $m->{stop_mode} = _payload_mode($p);
    my $e = ref $p->{effort} eq 'HASH' ? $p->{effort}{level} : undef;
    $m->{stop_effort} = (defined $e && $EFFORT{$e}) ? $e : undef;
    $m->{stop_at} = now_ms();
    my $t = _payload_transcript($p);
    $m->{transcript} = $t if defined $t;
    _write_mode($d, $m);
    return 1;
}

# note_post(sid_dir, payload): a main PostCompact keeps the fresh mode with its time (D10).
sub note_post {
    my ($d, $p) = @_;
    return 0 unless defined $d && ref $p eq 'HASH' && !defined $p->{agent_id};
    my $m = read_mode($d);
    $m->{post_mode} = _payload_mode($p);
    $m->{post_at} = now_ms();
    my $t = _payload_transcript($p);
    $m->{transcript} = $t if defined $t;
    _write_mode($d, $m);
    return 1;
}

# fresh_mode(sid_dir, since_ms) -> (mode, effort, undef) or (undef, undef, why): the PostCompact
# mode of the compaction that opened the moment (at or after since), equal to the newest main
# Stop's (D10: `mode-unknown`, `mode-changed`).
sub fresh_mode {
    my ($d, $since) = @_;
    my $m = read_mode($d);
    my $post = $m->{post_mode};
    return (undef, undef, 'mode-unknown') unless is_mode($post) && is_ms($m->{post_at}) && is_ms($since)
                                                 && $m->{post_at} + $MODE_SLACK_MS >= $since;
    return (undef, undef, 'mode-unknown') unless is_mode($m->{stop_mode});
    return (undef, undef, 'mode-changed') unless $m->{stop_mode} eq $post;
    my $e = $m->{stop_effort};
    return ($post, (defined $e && $EFFORT{$e}) ? $e : undef, undef);
}

# ---------------------------------------------------------------- the launcher (G3, G3a)
# launcher(launch, sid) -> {ok => 1, token, pid, lj} or {why => 'no-launcher' |
# 'launcher-invalid:<reason>'}: the launch folder as the launcher made it (absolute, private,
# `L-<token>` in a private runtime folder), its launcher.json of protocol 1 with that token, the
# launcher alive and an ancestor of this claude with no other claude between them, and the
# folder bound to no other session.
sub launcher {
    my ($launch, $sid) = @_;
    return { why => 'no-launcher' } unless defined $launch && $launch ne '';
    my $bad = sub { return { why => "launcher-invalid:$_[0]" } };
    return $bad->('relative') unless $launch =~ m{\A/};
    (my $dir = $launch) =~ s{(?<=.)/+\z}{};
    my $why = private_dir($dir);
    return $bad->($why) if defined $why;
    my $rt = util::dirname($dir);
    $why = private_dir($rt);
    return $bad->("runtime-$why") if defined $why;
    my ($token) = util::basename($dir) =~ /\AL-([0-9a-f]{16})\z/;
    return $bad->('name') unless defined $token;
    my $lj = _json_file("$dir/launcher.json", 65536) // return $bad->('no-launcher-json');
    return $bad->('proto') unless defined $lj->{proto} && !ref $lj->{proto} && "$lj->{proto}" eq "$PROTO";
    return $bad->('token') unless defined $lj->{token} && !ref $lj->{token} && $lj->{token} eq $token;
    my $pid = $lj->{pid};
    return $bad->('pid') unless defined $pid && !ref $pid && $pid =~ /\A[1-9][0-9]*\z/;
    return $bad->('dead') unless kill(0, $pid) || $!{EPERM};
    my $c = rc::claude();
    my $up = identity::launcher_above($c->{pid}, $pid, $ANCESTOR_MAX);
    return $bad->($up) unless $up eq 'ok';
    my $bound = bound_sid($dir);
    return $bad->('other-session') if defined $bound && $bound ne $sid;
    return { ok => 1, token => $token, pid => 0 + $pid, lj => $lj, dir => $dir };
}

# bound_sid(launch) -> the session id in <launch>/sid ('' for an unreadable or linked file), or
# undef when there is none.
sub bound_sid {
    my ($dir) = @_;
    my $f = "$dir/sid";
    return undef unless -e $f || -l $f;
    return '' if -l $f || !-f $f;
    my $raw = util::read_file($f, 256) // return '';
    my ($s) = $raw =~ /\A([^\n]*)/;
    return $s // '';
}

# stamps(launch, now_s) -> relaunches in the last $CAP_S seconds (the launcher's `stamps` file).
sub stamps {
    my ($dir, $now) = @_;
    my $raw = util::read_file("$dir/stamps", 65536) // return 0;
    return scalar grep { /\A[1-9][0-9]{0,10}\z/ && $now - $_ < $CAP_S } split /\n/, $raw;
}

# launcher_why(lr, mode, now_s) -> G3a's helper part on the exact note: bypass only when the
# launch made it available (`bypass-not-available`), every launch file a readable regular file
# (`launch-file`), and fewer than $CAP_N relaunches in the hour (`launcher-cap`); undef when all
# hold.
sub launcher_why {
    my ($lr, $mode, $now) = @_;
    my $lj = $lr->{lj};
    my $bypass_ok = jsonc::is_bool($lj->{bypass_ok}) ? ($lj->{bypass_ok} ? 1 : 0) : 0;
    return 'bypass-not-available' if $mode eq 'bypassPermissions' && !$bypass_ok;
    for my $f (@{ ref $lj->{file_flags} eq 'ARRAY' ? $lj->{file_flags} : [] }) {
        return 'launch-file' unless defined $f && !ref $f && $f =~ m{\A/} && -f $f && -r _;
    }
    return 'launcher-cap' if stamps($lr->{dir}, $now) >= $CAP_N;
    return undef;
}

# ---------------------------------------------------------------- background (G3, G3b)
# job(job_dir, sid, mode) -> {ok => 1, short} or {why}: a background session's job folder whose
# state.json names this session (`job-unknown` otherwise); its respawnFlags hold no bypass the
# fresh mode has left (`bypass-left`, B7): `--dangerously-skip-permissions`, or
# `--permission-mode bypassPermissions` (`=` form too), while the mode is not bypassPermissions.
# `--allow-dangerously-skip-permissions` alone is carried, as /restart carries it.
sub job {
    my ($jd, $sid, $mode) = @_;
    return { why => 'job-unknown' } unless defined $jd && $jd =~ m{\A/} && -d $jd;
    (my $dir = $jd) =~ s{(?<=.)/+\z}{};
    my $short = util::basename($dir);
    return { why => 'job-unknown' } unless is_short($short);
    my $st = _json_file("$dir/state.json", 4 * 1024 * 1024) // return { why => 'job-unknown' };
    return { why => 'job-unknown' } unless defined $st->{sessionId} && !ref $st->{sessionId} && $st->{sessionId} eq $sid;
    return { why => 'bypass-left' } if defined $mode && $mode ne 'bypassPermissions' && bypass_flags($st->{respawnFlags});
    return { ok => 1, short => $short };
}

sub bypass_flags {
    my ($f) = @_;
    my @a = ref $f eq 'ARRAY' ? grep { defined && !ref } @$f : (defined $f && !ref $f) ? split(/\s+/, $f) : ();
    for my $i (0 .. $#a) {
        return 1 if $a[$i] eq '--dangerously-skip-permissions';
        return 1 if $a[$i] eq '--permission-mode=bypassPermissions';
        return 1 if $a[$i] eq '--permission-mode' && ($a[$i + 1] // '') eq 'bypassPermissions';
    }
    return 0;
}

# ---------------------------------------------------------------- G5b, G7, G12
# claude_json() -> Claude Code's own config file: <CLAUDE_CONFIG_DIR>/.claude.json, else
# $HOME/.claude.json (as deps.ts servedHint).
sub claude_json {
    my $d = $ENV{CLAUDE_CONFIG_DIR};
    $d = util::home() if !defined $d || $d eq '';
    $d =~ s{(?<=.)/+\z}{};
    return "$d/.claude.json";
}

# hold(to) -> undef, 'on-hold' or 'version-unknown' (G5b, /restart's above_max_version): the
# cached `tengu_max_version_config.external`; set and older than `to` holds it. An unreadable
# file or a value that is not a version refuses too: an unknown hold is never skipped.
sub hold {
    my ($to) = @_;
    my $f = claude_json();
    return 'version-unknown' if -l $f || !-f $f || (-s _) > $HOLD_MAX;
    my $j = _json_file($f, $HOLD_MAX + 1) // return 'version-unknown';
    my $g = $j->{cachedGrowthBookFeatures};
    return undef unless defined $g;
    return 'version-unknown' unless ref $g eq 'HASH';
    my $c = $g->{tengu_max_version_config};
    return undef unless defined $c;
    return 'version-unknown' unless ref $c eq 'HASH';
    my $x = $c->{external};
    return undef unless defined $x;
    return 'version-unknown' unless is_ver($x);
    return vcmp($to, $x) > 0 ? 'on-hold' : undef;
}

# background(sid_dir) -> (why, types) from the newest Stop sidecar slot (G7): any task listed is
# in flight (`background-work`, with its type words), a session cron (`crons`); no slot: none.
sub background {
    my ($d) = @_;
    my $slot = sidecar::newest($d) // return (undef, []);
    my @tasks = @{ ref $slot->{tasks} eq 'ARRAY' ? $slot->{tasks} : [] };
    if (@tasks) {
        my %t = map { ((ref $_ eq 'HASH' && defined $_->{type}) ? $_->{type} : 'other') => 1 } @tasks;
        return ('background-work', [sort keys %t]);
    }
    return ('crons', []) if @{ ref $slot->{crons} eq 'ARRAY' ? $slot->{crons} : [] };
    return (undef, []);
}

# transcript_ok(sid_dir, sid) -> 1 when the noted transcript exists, is not empty and is
# <sid>.jsonl (G12, /restart's saving_off, not_written, gone).
sub transcript_ok {
    my ($d, $sid) = @_;
    my $t = read_mode($d)->{transcript};
    return 0 unless defined $t && !ref $t && util::basename($t) eq "$sid.jsonl";
    return (-f $t && -s _ > 0) ? 1 : 0;
}

# ---------------------------------------------------------------- the gate (§4.1, helper part)
# gate(%a) -> {ok, why, setting, route, mode, effort, job_short, token, types}. a: sid, sid_dir,
# setting, route (fg|bg), launch, job_dir, from, to, model, since (ms), now (ms). First failure
# wins, in this order: off, unsupported-os, the route (no-launcher, launcher-invalid:*,
# job-unknown), mode-unknown, mode-changed, note-pattern, bypass-not-available, launch-file,
# launcher-cap, bypass-left, background-work, crons, transcript, on-hold, version-unknown, then
# fg-not-shipped (the RS-P1 ship gate, not for shadow).
sub gate {
    my (%a) = @_;
    my %r = (ok => 0, why => undef, setting => $a{setting}, route => $a{route}, mode => undef, effort => undef,
             job_short => undef, token => undef, types => []);
    my $no = sub { $r{why} = $_[0]; return \%r };
    return $no->('off') unless ($a{setting} // 'off') =~ /\A(?:on|shadow)\z/;
    return $no->('unsupported-os') unless $^O eq 'darwin' || $^O eq 'linux';
    my $d = $a{sid_dir} // return $no->('no-watch');
    my ($lr, $jr);
    if (($a{route} // '') eq 'bg') {
        $jr = job($a{job_dir}, $a{sid}, undef);
        return $no->($jr->{why}) unless $jr->{ok};
        $r{job_short} = $jr->{short};
    } else {
        $r{route} = 'fg';
        $lr = launcher($a{launch}, $a{sid});
        return $no->($lr->{why}) unless $lr->{ok};
        $r{token} = $lr->{token};
    }
    my ($mode, $effort, $mwhy) = fresh_mode($d, $a{since});
    return $no->($mwhy) if defined $mwhy;
    ($r{mode}, $r{effort}) = ($mode, $effort);
    my $now_s = int(($a{now} // now_ms()) / 1000);
    if ($lr) {
        return $no->('note-pattern') unless is_sid($a{sid}) && is_ver($a{from}) && is_ver($a{to}) && is_model($a{model} // '')
                                             && is_effort($effort // '') && is_mode($mode);
        my $w = launcher_why($lr, $mode, $now_s);
        return $no->($w) if defined $w;
    } else {
        $jr = job($a{job_dir}, $a{sid}, $mode);
        return $no->($jr->{why}) unless $jr->{ok};
    }
    my ($bw, $types) = background($d);
    if (defined $bw) { $r{types} = $types; return $no->($bw) }
    return $no->('transcript') unless transcript_ok($d, $a{sid});
    my $h = hold($a{to});
    return $no->($h) if defined $h;
    return $no->('fg-not-shipped') if $lr && $a{setting} eq 'on' && !fg_route();
    $r{ok} = 1;
    return \%r;
}

# ---------------------------------------------------------------- the notes
# The launch note (contract §4): exactly these 12 keys, one per line.
our @L_KEYS = qw(proto state token sid nonce at exiting_at from to model effort mode);

sub l_text {
    my ($n) = @_;
    return join('', map { "$_=" . ($n->{$_} // '') . "\n" } @L_KEYS);
}

# parse_l(text) -> the note's values when it has the 12 keys once each and every value on its
# pattern, else undef.
sub parse_l {
    my ($t) = @_;
    return undef unless defined $t && $t ne '' && $t !~ /\r/;
    my %n;
    my @lines = split /\n/, $t;
    return undef if @lines > 24;
    for my $l (@lines) {
        my ($k, $v) = $l =~ /\A([a-z_]+)=(.*)\z/ or return undef;
        return undef if exists $n{$k};
        $n{$k} = $v;
    }
    return undef unless keys(%n) == @L_KEYS && !grep { !exists $n{$_} } @L_KEYS;
    return undef unless $n{proto} eq "$PROTO" && $L_STATE{ $n{state} } && is_hex16($n{token}) && is_sid($n{sid})
                        && is_hex16($n{nonce}) && $n{at} =~ /\A[1-9][0-9]{0,10}\z/
                        && ($n{exiting_at} eq '' || $n{exiting_at} =~ /\A[1-9][0-9]{0,13}\z/)
                        && is_ver($n{from}) && is_ver($n{to}) && is_model($n{model}) && is_effort($n{effort})
                        && is_mode($n{mode});
    return \%n;
}

# write_l(launch, note): `restart.note.tmp`, then renamed `restart.note` (contract §6).
sub write_l {
    my ($dir, $n) = @_;
    my $tmp = "$dir/restart.note.tmp";
    unlink $tmp;
    my $fh;
    sysopen($fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600) or die "create launch note: $!\n";
    my $data = l_text($n);
    my $off = 0;
    while ($off < length $data) {
        my $w = syswrite($fh, $data, length($data) - $off, $off);
        die "write launch note: $!\n" unless defined $w;
        $off += $w;
    }
    close($fh) or die "close launch note: $!\n";
    rename($tmp, "$dir/restart.note") or do { my $e = $!; unlink $tmp; die "rename launch note: $e\n" };
    return 1;
}

sub read_l {
    my ($dir) = @_;
    my $f = "$dir/restart.note";
    return undef if -l $f || !-f $f;
    return parse_l(util::read_file($f, 4096));
}

our @C_KEYS = qw(v route state sid nonce from to at exiting_at continue launch_token job_short load_id);

sub read_c { my ($d) = @_; return defined $d ? _json_file(carry_path($d), 65536) : undef }

sub write_c {
    my ($d, $c) = @_;
    $c->{v} = 1;
    my $o = jsonc::obj(map { ($_ => ($_ eq 'continue' ? jsonc::bool($c->{$_}) : $c->{$_})) } @C_KEYS);
    util::write_atomic(carry_path($d), jsonc::encode_bytes($o) . "\n", 0600);
    return 1;
}

# arm(%a) -> {ok, why}: binds the launch folder to this session (fg: `<launch>/sid` once,
# O_EXCL; another session's id refuses `launcher-invalid:other-session`), then writes the launch
# note (fg) and the carry note, both `armed` (§3.4 step 1, §2.2 step 1). a: sid, sid_dir,
# route, nonce, from, to, continue, mode, effort, model, launch, job_short, load_id, now (ms).
sub arm {
    my (%a) = @_;
    my $d = $a{sid_dir} // return { ok => 0, why => 'no-watch' };
    return { ok => 0, why => 'note-pattern' }
        unless is_sid($a{sid}) && is_hex16($a{nonce}) && is_ver($a{from}) && is_ver($a{to}) && is_mode($a{mode})
               && is_effort($a{effort} // '') && is_model($a{model} // '') && is_ms($a{now});
    my $route = ($a{route} // '') eq 'bg' ? 'bg' : 'fg';
    my ($token, $dir);
    if ($route eq 'fg') {
        my $lr = launcher($a{launch}, $a{sid});
        return { ok => 0, why => $lr->{why} } unless $lr->{ok};
        ($token, $dir) = ($lr->{token}, $lr->{dir});
        if (!util::write_excl("$dir/sid", "$a{sid}\n", 0600)) {
            my $b = bound_sid($dir);
            return { ok => 0, why => 'launcher-invalid:other-session' } unless defined $b && $b eq $a{sid};
        }
        write_l($dir, { proto => $PROTO, state => 'armed', token => $token, sid => $a{sid}, nonce => $a{nonce},
                        at => int($a{now} / 1000), exiting_at => '', from => $a{from}, to => $a{to},
                        model => $a{model} // '', effort => $a{effort} // '', mode => $a{mode} });
    } else {
        return { ok => 0, why => 'job-unknown' } unless is_short($a{job_short});
    }
    write_c($d, { route => $route, state => 'armed', sid => $a{sid}, nonce => $a{nonce}, from => $a{from}, to => $a{to},
                  at => 0 + $a{now}, exiting_at => undef, continue => $a{continue} ? 1 : 0,
                  launch_token => $token, job_short => ($route eq 'bg' ? $a{job_short} : undef),
                  load_id => (defined $a{load_id} && $a{load_id} =~ /\A[0-9a-f]{1,32}\z/ ? $a{load_id} : undef) });
    return { ok => 1, why => undef, token => $token };
}

# set_state(%a) -> {ok, l, c}: one state change of both notes with this nonce, the launch note
# first (§3.4: the `go` that the launcher acts on is the first write). l and c: `written`,
# `absent`, `mismatch` (another nonce or session) or `final` (the note already ended). a: sid,
# sid_dir, nonce, state, now (ms), exiting_at (ms, optional), launch (fg).
sub set_state {
    my (%a) = @_;
    my ($l, $c) = ('absent', 'absent');
    my $state = $a{state} // '';
    my $now = $a{now};
    return { ok => 0, l => $l, c => $c, why => 'usage' } unless $C_STATE{$state} && is_hex16($a{nonce}) && is_ms($now);
    my $ex = is_ms($a{exiting_at}) ? 0 + $a{exiting_at} : undef;
    if (defined $a{launch} && $a{launch} ne '' && $L_STATE{$state}) {
        (my $dir = $a{launch}) =~ s{(?<=.)/+\z}{};
        if (!defined private_dir($dir)) {
            my $n = read_l($dir);
            if (!$n) { $l = (-e "$dir/restart.note") ? 'mismatch' : 'absent' }
            elsif ($n->{nonce} ne $a{nonce} || $n->{sid} ne $a{sid}) { $l = 'mismatch' }
            elsif ($L_FINAL{ $n->{state} } && $state ne $n->{state}) { $l = 'final' }
            else {
                $n->{state} = $state;
                $n->{at} = int($now / 1000);
                $n->{exiting_at} = $ex if defined $ex;
                write_l($dir, $n);
                $l = 'written';
            }
        }
    }
    my $d = $a{sid_dir};
    my $cn = read_c($d);
    if ($cn) {
        if (($cn->{nonce} // '') ne $a{nonce} || ($cn->{sid} // '') ne $a{sid}) { $c = 'mismatch' }
        elsif ($C_FINAL{ $cn->{state} // '' } && $state ne $cn->{state}) { $c = 'final' }
        else {
            $cn->{state} = $state;
            $cn->{at} = 0 + $now;
            $cn->{exiting_at} = $ex if defined $ex;
            write_c($d, $cn);
            $c = 'written';
        }
    }
    return { ok => 1, l => $l, c => $c };
}

# claim(%a) -> {claimed, why, route, from, to, continue, nonce, refused}: the new load takes the
# carry note (§5.2) by renaming it to restart.claimed-<load_id>.json (one winner). fg: route fg,
# state exiting or go, the launch folder `L-<launch_token>` and its restart.used holding this
# nonce and session (the launcher consumed this very note). bg: route bg, a background session,
# state sent. Both: this session and under $CLAIM_MAX_MS old. A `sent` note (or an fg note left in
# exiting or go) past that age is `not-confirmed`, settled `failed`. `refused` lists the
# launcher's refusals for this session (last-refusal-*, deleted once read).
sub claim {
    my (%a) = @_;
    my %r = (claimed => 0, why => 'none', route => undef, from => undef, to => undef, continue => 0, nonce => undef, at => undef);
    $r{refused} = [refusals(sid => $a{sid}, launch => $a{launch}, take => 1)];
    my $d = $a{sid_dir} // return \%r;
    my $c = read_c($d) // return \%r;
    return \%r unless ($c->{sid} // '') eq $a{sid} && is_hex16($c->{nonce});
    @r{qw(route from to nonce)} = @$c{qw(route from to nonce)};
    $r{continue} = $c->{continue} ? 1 : 0;
    $r{at} = is_ms($c->{at}) ? 0 + $c->{at} : undef;
    my $age = $a{now} - ($c->{at} // 0);
    my $route = $c->{route} // '';
    my $state = $c->{state} // '';
    my $ok;
    if ($route eq 'fg') {
        my $dir = defined $a{launch} ? $a{launch} =~ s{(?<=.)/+\z}{}r : undef;
        my $tok = defined $c->{launch_token} && !ref $c->{launch_token} ? $c->{launch_token} : '';
        my $used = defined $dir && !defined private_dir($dir) ? parse_used("$dir/restart.used") : undef;
        $ok = ($state eq 'exiting' || $state eq 'go') && defined $dir && util::basename($dir) eq "L-$tok"
              && $used && $used->{nonce} eq $c->{nonce} && $used->{sid} eq $a{sid};
    } elsif ($route eq 'bg') {
        $ok = $state eq 'sent' && $a{bg};
    }
    if ($ok && $age >= 0 && $age < $CLAIM_MAX_MS) {
        my $id = defined $a{load_id} && $a{load_id} =~ /\A[0-9a-f]{1,32}\z/ ? $a{load_id} : 'load';
        if (rename(carry_path($d), "$d/restart.claimed-$id.json")) {
            @r{qw(claimed why)} = (1, undef);
            return \%r;
        }
        $r{why} = 'taken';
        return \%r;
    }
    my $open = ($route eq 'bg' && $state eq 'sent') || ($route eq 'fg' && ($state eq 'exiting' || $state eq 'go'));
    if ($open && $age >= $CLAIM_MAX_MS) {
        $c->{state} = 'failed';
        $c->{at} = 0 + $a{now};
        write_c($d, $c);
        $r{why} = 'not-confirmed';
        return \%r;
    }
    $r{why} = 'no-proof';
    return \%r;
}

# parse_used(path) -> {nonce, sid} of a consumed launch note, or undef
sub parse_used {
    my ($f) = @_;
    return undef if -l $f || !-f $f;
    my $raw = util::read_file($f, 4096) // return undef;
    my ($nonce) = $raw =~ /^nonce=([0-9a-f]{16})$/m;
    my ($sid) = $raw =~ /^sid=([0-9a-f-]{36})$/m;
    return defined $nonce && defined $sid ? { nonce => $nonce, sid => $sid } : undef;
}

# refusals(sid => S|undef, launch => DIR|undef, take => 0|1) -> ({sid, reason, at}…) from the
# launcher's last-refusal-<token> files (contract §2: proto, reason, sid, at; no values) in the
# runtime folder (the launch folder's parent, else runtime_dir()), newest first. With sid only
# that session's; with take each one read is deleted (the next load of that session reports it).
sub refusals {
    my (%o) = @_;
    my $rt = defined $o{launch} && $o{launch} =~ m{\A/} ? util::dirname($o{launch} =~ s{(?<=.)/+\z}{}r) : runtime_dir();
    return () unless defined $rt && !defined private_dir($rt);
    my @out;
    for my $f (util::list_dir($rt)) {
        next unless $f =~ /\Alast-refusal-[0-9a-f]{16}\z/;
        my $p = "$rt/$f";
        next if -l $p || !-f $p;
        my $raw = util::read_file($p, 4096) // next;
        my %v = $raw =~ /^(proto|reason|sid|at)=([^\n]*)$/mg;
        next unless ($v{proto} // '') eq "$PROTO" && ($v{reason} // '') =~ /\A[a-z][a-z-]{0,31}\z/ && ($v{at} // '') =~ /\A[0-9]{1,11}\z/;
        my $sid = is_sid($v{sid}) ? $v{sid} : undef;
        next if defined $o{sid} && (!defined $sid || $sid ne $o{sid});
        push @out, { sid => $sid, reason => $v{reason}, at => 0 + $v{at} };
        unlink $p if $o{take};
    }
    return sort { $b->{at} <=> $a->{at} } @out;
}

# ---------------------------------------------------------------- the background respawn
# claude_bin() -> `claude` from PATH, else $HOME/.local/bin/claude when executable (§2.2 step 3)
sub claude_bin {
    my $c = util::which('claude');
    return $c if defined $c;
    my $h = util::home() . '/.local/bin/claude';
    return -x $h ? $h : undef;
}

# code_of(output, rc) -> the first B6 code the respawn client's output names; `other` for a
# non-zero rc without one, undef for rc 0 without one.
sub code_of {
    my ($out, $rc) = @_;
    for my $c (@B6) { return $c if index($out // '', $c) >= 0 }
    return $rc ? 'other' : undef;
}

# respawn(%a) -> {ok, pid, why}: starts `claude respawn <short>` detached, the way /restart starts
# it (R5): the helper forks; that child forks the grandchild and exits at once, so the grandchild
# is no descendant of the worker; the grandchild calls setsid (its own session and process
# group, no terminal), takes stdin from /dev/null, drops every R5 name from its environment, runs
# the client as its own child (stdout and stderr captured, at most $OUT_MAX bytes) and waits.
# Then it writes restart-respawn.out (0600), restart-respawn.json {nonce, rc, code, at} and, on a
# non-zero rc, one `refresh_failed {route: bg, why: respawn-failed, code}` row. The reply holds
# the grandchild's pid, which is also its process group; restart-respawn.pid keeps it with its
# start time and the nonce for respawn-cancel. a: sid, sid_dir, short, nonce, to, wait_ms (test
# mode only: wait that long for the result file before replying).
sub respawn {
    my (%a) = @_;
    my $d = $a{sid_dir} // return { ok => 0, why => 'no-watch' };
    return { ok => 0, why => 'usage' } unless is_short($a{short}) && is_hex16($a{nonce});
    my $claude = claude_bin() // return { ok => 0, why => 'no-claude' };
    # §2.2 step 3: the carry note becomes `sent` in the call that starts the respawn
    my $c = read_c($d);
    return { ok => 0, why => 'no-note' } unless $c && ($c->{nonce} // '') eq $a{nonce} && ($c->{route} // '') eq 'bg'
                                                && ($c->{state} // '') eq 'armed';
    $c->{state} = 'sent';
    $c->{at} = now_ms();
    write_c($d, $c);
    unlink result_path($d), out_path($d);
    pipe(my $r, my $w) or return { ok => 0, why => 'pipe' };
    my $kid = fork();
    return { ok => 0, why => 'fork' } unless defined $kid;
    if ($kid == 0) {
        close $r;
        my $g = fork();
        POSIX::_exit(defined $g ? 0 : 1) if !defined $g || $g;
        POSIX::setsid();
        open(STDIN, '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        syswrite($w, "$$\n");
        close $w;
        _grandchild(%a, claude => $claude, sid_dir => $d);
        POSIX::_exit(0);
    }
    close $w;
    my $line = <$r>;
    close $r;
    waitpid($kid, 0);
    my ($g) = ($line // '') =~ /\A([0-9]+)/;
    return { ok => 0, why => 'fork' } unless $g;
    util::write_atomic(pid_path($d), jsonc::encode_bytes(jsonc::obj(nonce => $a{nonce}, pid => 0 + $g,
                                     lstart => identity::start_time($g))) . "\n", 0600);
    if (util::test_mode() && is_ms($a{wait_ms})) {
        my $t0 = util::clock_ms();
        util::sleep_ms(50) while !-e result_path($d) && util::clock_ms() - $t0 < $a{wait_ms};
    }
    return { ok => 1, pid => 0 + $g };
}

sub _grandchild {
    my (%a) = @_;
    $SIG{HUP} = 'IGNORE';
    delete $ENV{$_} for @ST, 'CLAUDE_JOB_DIR';
    delete $ENV{$_} for grep { /\ACLAUDE_BG_/ } keys %ENV;
    my ($rc, $out) = _capture([$a{claude}, 'respawn', $a{short}], $RESPAWN_MS);
    my $d = $a{sid_dir};
    my $code = code_of($out, $rc);
    eval { util::write_atomic(out_path($d), $out, 0600) };
    eval {
        util::write_atomic(result_path($d), jsonc::encode_bytes(jsonc::obj(nonce => $a{nonce}, rc => $rc, code => $code,
                                                                            at => now_ms())) . "\n", 0600);
    };
    eval { rc::emit('refresh_failed', [route => 'bg', why => 'respawn-failed', to => $a{to}, code => $code], stream => 'mod') }
        if $rc != 0;
}

# _capture(argv, timeout_ms) -> (exit code, output): stdout and stderr of the child, at most
# $OUT_MAX bytes kept (the rest read and dropped); past the time bound the child's group gets TERM.
sub _capture {
    my ($argv, $timeout) = @_;
    pipe(my $r, my $w) or return (-1, '');
    my $pid = fork();
    return (-1, '') unless defined $pid;
    if ($pid == 0) {
        close $r;
        open(STDOUT, '>&', $w) or POSIX::_exit(126);
        open(STDERR, '>&', $w) or POSIX::_exit(126);
        { no warnings 'exec'; exec { $argv->[0] } @$argv; }
        POSIX::_exit(127);
    }
    close $w;
    my $out = '';
    my $t0 = util::clock_ms();
    my $rin = '';
    vec($rin, fileno($r), 1) = 1;
    while (1) {
        my $left = $timeout - (util::clock_ms() - $t0);
        if ($left <= 0) { kill 'TERM', $pid; last }
        my $n = select(my $rout = $rin, undef, undef, $left / 1000);
        if ($n < 0) { next if $!{EINTR}; last }
        next if $n == 0;
        my $got = sysread($r, my $buf, 65536);
        last if !defined $got || $got == 0;
        $out .= substr($buf, 0, $OUT_MAX - length $out) if length($out) < $OUT_MAX;
    }
    close $r;
    waitpid($pid, 0);
    my $st = $?;
    return (($st & 127) ? 128 + ($st & 127) : ($st >> 8), $out);
}

# respawn_result(sid_dir) -> {nonce, rc, code, at} of the detached helper, or undef
sub respawn_result { my ($d) = @_; return defined $d ? _json_file(result_path($d), 4096) : undef }

# respawn_cancel(sid_dir, nonce) -> {ok, killed}: TERM to the grandchild's process group when its
# record holds this nonce and that process still runs with the start time recorded (§2.2 step 4).
sub respawn_cancel {
    my ($d, $nonce) = @_;
    my $p = defined $d ? _json_file(pid_path($d), 4096) : undef;
    return { ok => 1, killed => 0 } unless $p && ($p->{nonce} // '') eq $nonce && ($p->{pid} // '') =~ /\A[1-9][0-9]*\z/;
    my $pid = $p->{pid};
    return { ok => 1, killed => 0 } unless identity::alive($pid, $p->{lstart});
    my $n = kill('TERM', -$pid);
    $n += kill('TERM', $pid);
    unlink pid_path($d);
    return { ok => 1, killed => $n ? 1 : 0 };
}

# ---------------------------------------------------------------- after-kill scan (§2.3)
# failed_bg(watch, now_ms, include_reported) -> ({sid, short, to, code, at}…): background carry
# notes whose restart failed with nobody left in the session: still `sent` past $CLAIM_MAX_MS, or
# with a non-zero respawn result older than $AFTERKILL_MS (`reported` ones too for /status,
# within $REPORT_MS).
sub failed_bg {
    my ($w, $now, $reported) = @_;
    return () unless defined $w && -d $w;
    my @out;
    for my $e (util::list_dir($w)) {
        next unless is_sid($e);
        my $d = "$w/$e";
        next unless -f carry_path($d);
        my $c = read_c($d) // next;
        next unless ($c->{route} // '') eq 'bg' && ($c->{sid} // '') eq $e;
        my $st = $c->{state} // '';
        next unless $st eq 'sent' || ($reported && $st eq 'reported');
        my $at = is_ms($c->{at}) ? $c->{at} : 0;
        my $res = respawn_result($d);
        $res = undef unless $res && ($res->{nonce} // '') eq ($c->{nonce} // '');
        my $bad_rc = $res && ($res->{rc} // 0) != 0 && is_ms($res->{at}) && $now - $res->{at} >= $AFTERKILL_MS;
        my $stale = $now - $at >= $CLAIM_MAX_MS;
        next unless $st eq 'reported' ? $now - $at < $REPORT_MS : ($bad_rc || $stale);
        my $code = $res && defined $res->{code} && $res->{code} =~ /\A[a-z_]{1,40}\z/ ? $res->{code} : 'not-confirmed';
        push @out, { sid => $e, short => (is_short($c->{job_short}) ? $c->{job_short} : 'job-unknown'),
                     to => (is_ver($c->{to}) ? $c->{to} : undef), code => $code,
                     at => ($res && is_ms($res->{at})) ? $res->{at} : $at, dir => $d, note => $c };
    }
    return sort { $b->{at} <=> $a->{at} } @out;
}

# report_failed(watch, now_ms) -> the failures failed_bg finds still `sent`, each marked
# `reported` (once per note: the load that reports it writes the transcript line).
sub report_failed {
    my ($w, $now) = @_;
    my @out;
    for my $f (failed_bg($w, $now, 0)) {
        my $c = $f->{note};
        $c->{state} = 'reported';
        $c->{at} = 0 + $now;
        next unless eval { write_c($f->{dir}, $c); 1 };
        push @out, { short => $f->{short}, to => $f->{to}, code => $f->{code} };
    }
    return @out;
}

1;
