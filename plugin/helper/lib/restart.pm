package restart;
# lib/restart.pm: restart on update, the helper's part.
# The setting `restart_on_update` (a consent key); the session file of the relaunch
# permission mode; the gate (launcher, cap, mode and the other checks); the
# two notes of the terminal route, in the launcher's file contract (protocol 1,
# tests/launcher/README.md: launch note `restart.note` written as `restart.note.tmp` then
# renamed, `sid` bound once with O_EXCL); the carry note `<watch>/<sid>/restart.json`;
# the claim in the new load; the background route's detached `claude respawn`
# and its cancel; the scan for background restarts that failed after the kill and for the
# launcher's refusals. Rows and replies hold no argv, path, model or env value.
use strict;
use warnings;
use utf8;
use POSIX ();
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);

our $PROTO = 1;
# The ship gate of the terminal route: the plugin's own
# /exit, then the launcher's relaunch. A trial run ended with: with an item the plugin
# cannot see, the exit dialog stays open and blocks queued input, so the route stays off
# until it ships. 0: an `on` session that passes every gate on that route logs
# `refresh_skipped {why: fg-not-shipped}` and goes on as if the setting were shadow. Test seam:
# STORE_TEST_RESTART_FG=1 in test mode.
our $FG_ROUTE = 0;
sub fg_route { return 1 if $FG_ROUTE; return util::test_mode() && ($ENV{STORE_TEST_RESTART_FG} // '') eq '1' ? 1 : 0 }
# The ship gate of the background route: off until the respawn-restriction
# gate (`restriction-lost`) is in and a full trial on this helper's own `restart respawn`
# passes. 0: an `on` background session that passes every gate logs `refresh_skipped {why:
# bg-not-shipped}` and goes on as if the setting were shadow. Test seam: STORE_TEST_RESTART_BG=1
# in test mode.
our $BG_ROUTE = 0;
sub bg_route { return 1 if $BG_ROUTE; return util::test_mode() && ($ENV{STORE_TEST_RESTART_BG} // '') eq '1' ? 1 : 0 }

# os_name() -> $^O; in test mode STORE_TEST_OS stands in for it (AT-RS-25: MSWin32).
sub os_name { return util::test_mode() && ($ENV{STORE_TEST_OS} // '') ne '' ? $ENV{STORE_TEST_OS} : $^O }

# The launcher must be an ancestor of this claude within this many processes.
our $ANCESTOR_MAX = 8;
# The launcher's own cap (contract §5: 3 relaunches in 3600 s).
our ($CAP_N, $CAP_S) = (3, 3600);
# A carry note older than this is not claimed; a `sent` one is a failure.
our $CLAIM_MAX_MS = 600000;
# A non-zero respawn result this old whose note is still `sent` is a failure after the kill
# (before the kill the mod's watchdog settles the note within seconds).
our $AFTERKILL_MS = 60000;
# /status lists failed background restarts and launcher refusals this recent.
our $REPORT_MS = 7 * 86400 * 1000;
# A read of the last turn may be stamped up to this much before that turn's start (its
# UserPromptSubmit comes before turn.start; a perl without Time::HiRes keeps whole seconds).
our $MODE_SLACK_MS = 1000;
# The respawn client's output kept, and its time bound.
our $OUT_MAX = 65536;
our $RESPAWN_MS = 180000;
# A Claude Code cache file larger than this is not read (as deps.ts SERVED_MAX_CHARS).
our $HOLD_MAX = 8000000;

# R5: the names `/restart` removes from the respawn client's environment (`$st`, Claude Code
# 2.1.311), besides CLAUDE_JOB_DIR and every CLAUDE_BG_* (the prefix rule covers its twelve).
our @ST = qw(CLAUDE_CODE_SESSION_KIND CLAUDE_CODE_SESSION_NAME CLAUDE_CODE_RESUME_INTERRUPTED_TURN
             CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS CLAUDE_CODE_RESUME_PROMPT
             CLAUDE_CODE_RESUME_SHOWS_CUT_OFF_CALLS CLAUDE_CODE_RESUME_REASON CLAUDE_CODE_RESUME_SOURCE_ALIVE
             CLAUDE_CODE_RELAUNCH_HOME_TRUST);
# @B6: the respawn client's failure codes (and its no-op), found in its output; the specific ones
# first, the generic spawn failure last.
our @B6 = qw(job_respawn_kill_unconfirmed cwd_gone crashed_during_spawn in_flight_spawn_failed
             resume_session_live_elsewhere stopped_during_respawn already_alive job_respawn_spawn_failed);

# What a restart of a background job keeps of its respawnFlags (Claude Code 2.1.312, the
# sanitizer that reads them back, whose warning is "stripped respawnFlags token(s) that a restart
# does not re-apply"). A flag that takes a value is kept with its value (@KEEP_VAL; @KEEP_VAR
# takes the following words too); a flag without one is kept by name (@KEEP_BOOL). Every other
# flag word is dropped, with the words after it up to the next flag. `-m` is dropped too.
# tools/respawn-keepset checks these lists and the walk against every installed Claude Code.
# The version that wrote state.json ran the same sanitizer before it stored the flags, so on a
# version with this keep-set the check refuses nothing; it guards against a later version that
# keeps less (version skew), which is why the target must be one whose keep-set was checked.
our @KEEP_VAL = qw(--model -m --permission-mode --inherit-permission-mode --proactivity --agent --agents --routine
                   --effort --fast-mode --add-dir --mcp-config --settings --setting-sources --managed-settings
                   --client-data-url --system-prompt --system-prompt-file --append-system-prompt
                   --append-system-prompt-file --system-prompt-snapshot --append-subagent-system-prompt
                   --append-subagent-system-prompt-file --fallback-model --advisor --channels --watch-artifact
                   --watch-artifact-no-autoreact --permission-prompt-tool --permission-prompts --allowed-tools
                   --allowedTools --disallowed-tools --disallowedTools --tools --session-id --debug-file -n --name
                   --autocompact --betas --file --max-budget-usd --max-thinking-tokens --max-turns --task-budget
                   --plan-mode-instructions --plugin-dir --plugin-dir-no-mcp --plugin-url --rewind-files --thinking
                   --thinking-display --remote-control-session-name-prefix --json-schema);
our @KEEP_VAR = qw(--allowed-tools --allowedTools --disallowed-tools --disallowedTools --tools --mcp-config --betas
                   --add-dir --file --channels);
our @KEEP_BOOL = qw(--dangerously-skip-permissions --allow-dangerously-skip-permissions --strict-mcp-config
                    --dangerously-allow-browser-network-access --restricted --disable-slash-commands
                    --include-unsupported-models --verbose --reply-on-resume --ide --chrome --no-chrome --bare
                    --safe-mode --brief --remote-control --rc --local --unsandboxed --personal --allow-other-models);
# Dropped flags that restrict nothing: session selection, the model's short form (the session
# keeps its model in --model), debug output, screen and prompt display. Any other dropped flag
# counts as a restriction the respawned session would lose, unknown ones included.
our @DROP_OK = qw(-c --continue -r --resume --fork-session -m -d --debug --ax-screen-reader --prompt-suggestions
                  --exclude-dynamic-system-prompt-sections);
# The Claude Code versions whose sanitizer tools/respawn-keepset found equal to the lists above
# (its sets and its walk). A restart onto any other version may keep less: there a job whose
# respawnFlags hold a flag outside @LOSS_OK refuses `keepset-unverified`.
our @KEEPSET_CHECKED = qw(2.1.311 2.1.312);
# Flags whose loss can never widen what the session may do: the dropped flags above that restrict
# nothing, the model and its effort, the name, the session id, debug output, the bypass flags
# (lost, the session asks more, not less). A --permission-mode counts only with a value other
# than plan or dontAsk (lost, the session starts in default, which is not wider).
our @LOSS_OK = (@DROP_OK, qw(--model --effort -n --name --session-id --debug-file --verbose --reply-on-resume
                              --dangerously-skip-permissions --allow-dangerously-skip-permissions));
my %KEEP_VAL = map { $_ => 1 } @KEEP_VAL;
my %KEEP_VAR = map { $_ => 1 } @KEEP_VAR;
my %KEEP_BOOL = map { $_ => 1 } @KEEP_BOOL;
my %DROP_OK = map { $_ => 1 } @DROP_OK;
my %KEEPSET_CHECKED = map { $_ => 1 } @KEEPSET_CHECKED;
my %LOSS_OK = map { $_ => 1 } @LOSS_OK;

# Permission modes from the narrowest ("more restrictive" first): plan and dontAsk are both
# below default and are not ordered against each other (narrower() answers undef for that pair).
my %MODE_RANK = (plan => 0, dontAsk => 0, default => 1, acceptEdits => 2, auto => 3, bypassPermissions => 4);

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
# a model never starts with `-` (the launcher's is_model: it could read as a flag)
sub is_model  { my ($v) = @_; return defined $v && !ref $v && ($v eq '' || $v =~ m{\A(?!-)[A-Za-z0-9._:/\[\]-]{1,100}\z}) ? 1 : 0 }
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

# runtime_dir() -> <cache>/<plugin> as the launcher makes it (contract §1: $XDG_CACHE_HOME when
# it is an absolute path, else $HOME/.cache; trailing `/` removed), or undef when HOME is not an
# absolute path either.
sub runtime_dir {
    my $base = $ENV{XDG_CACHE_HOME};
    if (!defined $base || $base !~ m{\A/}) {
        my $h = $ENV{HOME};
        return undef unless defined $h && $h =~ m{\A/};
        $h =~ s{/+\z}{};
        $base = "$h/.cache";
    }
    $base =~ s{(?<=.)/+\z}{};
    $base = '' if $base eq '/';
    return "$base/" . (ctx::brand() // 'plugin');
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
# The lock of the carry note's read-modify-writes (set, respawn, respawn-cancel and the detached
# respawn's own check), so a cancel and the respawn's armed -> sent never overwrite each other.
sub lock_path   { return "$_[0]/restart.lock" }
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

# ---------------------------------------------------------------- the session file
# <watch>/<sid>/restart-mode.json (0600): the newest main Stop's permission_mode and effort level
# with its time, and the transcript path the hooks noted. Only names the patterns allow are
# kept; the path stays in this private file and never enters a row. (PostCompact, PreCompact and
# SessionEnd inputs carry no permission_mode on Claude Code 2.1.312.)
sub read_mode { my ($d) = @_; return defined $d ? (_json_file(mode_path($d)) // {}) : {} }

sub _write_mode {
    my ($d, $m) = @_;
    my @k = qw(v stop_mode stop_effort stop_at transcript);
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

# note_post(sid_dir, payload): a main PostCompact notes the transcript path; its input has
# no permission_mode (not on 2.1.312).
sub note_post {
    my ($d, $p) = @_;
    return 0 unless defined $d && ref $p eq 'HASH' && !defined $p->{agent_id};
    my $t = _payload_transcript($p) // return 0;
    my $m = read_mode($d);
    return 1 if ($m->{transcript} // '') eq $t;
    $m->{transcript} = $t;
    _write_mode($d, $m);
    return 1;
}

# narrower(a, b) -> the more restrictive of two modes, or undef for plan against dontAsk (not
# ordered: plan stops edits the rules allow, dontAsk refuses what the rules do not allow).
sub narrower {
    my ($x, $y) = @_;
    return undef unless is_mode($x) && is_mode($y);
    return $x if $x eq $y;
    my ($rx, $ry) = ($MODE_RANK{$x}, $MODE_RANK{$y});
    return undef if $rx == $ry;
    return $rx < $ry ? $x : $y;
}

# relaunch_mode(%a) -> (mode, effort, undef) or (undef, undef, 'mode-unknown'):
# the newest permission_mode of a main hook input: the session file's Stop
# (any process of this session) and the mod's own reads of this load (`seen`: Stop,
# UserPromptSubmit, PermissionRequest), when it is from the last main turn or later (`turn_at`:
# the start of this load's last main turn; with no turn in this load, the load's start, so a read
# an earlier process made never counts as the last turn's: that process may have run in a wider
# mode than this one was launched in). Otherwise, and when no `turn_at` is given, the narrower of
# the launch mode (`launch`: launcher.json launch_mode, an empty one counts as default) and the
# newest read, so a restart never widens past either. None read at all, or plan against dontAsk:
# mode-unknown. The effort is the Stop's. a: sid_dir, seen_mode, seen_at, turn_at, launch.
sub relaunch_mode {
    my (%a) = @_;
    my $m = read_mode($a{sid_dir});
    my @c;
    push @c, [$m->{stop_mode}, 0 + $m->{stop_at}] if is_mode($m->{stop_mode}) && is_ms($m->{stop_at});
    push @c, [$a{seen_mode}, 0 + $a{seen_at}] if is_mode($a{seen_mode}) && is_ms($a{seen_at});
    my ($new) = sort { $b->[1] <=> $a->[1] } @c;
    return (undef, undef, 'mode-unknown') unless $new;
    my $e = $m->{stop_effort};
    $e = undef unless defined $e && $EFFORT{$e};
    my $turn = is_ms($a{turn_at}) ? 0 + $a{turn_at} : undef;
    return ($new->[0], $e, undef) if defined $turn && $new->[1] + $MODE_SLACK_MS >= $turn;
    my $launch = is_mode($a{launch}) ? $a{launch} : 'default';
    my $r = narrower($launch, $new->[0]) // return (undef, undef, 'mode-unknown');
    return ($r, $e, undef);
}

# ---------------------------------------------------------------- the launcher
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
    my ($bound, $by) = bound_sid($dir);
    my $rebind = defined $bound && $bound ne $sid;
    return $bad->('other-session') if $rebind && !rebindable($by, $c);
    return { ok => 1, token => $token, pid => 0 + $pid, lj => $lj, dir => $dir, rebind => ($rebind ? 1 : 0) };
}

# bound_sid(launch) -> (the session id in <launch>/sid ('' for an unreadable or linked file),
# its binder {pid, lstart} from the second line or undef), or () when there is no such file.
sub bound_sid {
    my ($dir) = @_;
    my $f = "$dir/sid";
    return () unless -e $f || -l $f;
    return ('', undef) if -l $f || !-f $f;
    my $raw = util::read_file($f, 512) // return ('', undef);
    my ($s, $rest) = $raw =~ /\A([^\n]*)(?:\n(.*))?/s;
    my $by;
    if (defined $rest && $rest =~ /\A([1-9][0-9]{0,9}) ([^\n]{1,64})\n?\z/) { $by = { pid => 0 + $1, lstart => $2 } }
    return ($s // '', $by);
}

# rebindable(binder, claude) -> 1 when the claude process that bound the launch folder is this
# one (a `/clear` or `/resume` changed the session id in the launcher's own child) or is gone (the
# launcher's earlier child, before a relaunch; the ancestor check has just shown this claude is the first one
# under the launcher). A file with no binder line is never taken over.
sub rebindable {
    my ($by, $c) = @_;
    return 0 unless $by && defined $c && defined $c->{pid};
    return 1 if $by->{pid} == $c->{pid} && defined $c->{lstart} && $by->{lstart} eq $c->{lstart};
    return identity::alive($by->{pid}, $by->{lstart}) ? 0 : 1;
}

# bind_text(sid, claude) -> the `sid` file: the session id, then this claude's pid and start time.
sub bind_text {
    my ($sid, $c) = @_;
    my $l = defined $c && defined $c->{pid} && defined $c->{lstart} && $c->{lstart} =~ /\A[^\n]{1,64}\z/
            ? "$c->{pid} $c->{lstart}\n" : '';
    return "$sid\n$l";
}

# stamps(launch, now_s) -> relaunches in the last $CAP_S seconds (the launcher's `stamps` file).
sub stamps {
    my ($dir, $now) = @_;
    my $raw = util::read_file("$dir/stamps", 65536) // return 0;
    return scalar grep { /\A[1-9][0-9]{0,10}\z/ && $now - $_ < $CAP_S } split /\n/, $raw;
}

# launcher_why(lr, mode, now_s) -> the launcher check's helper part on the exact note: bypass only when the
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

# ---------------------------------------------------------------- background
# job(job_dir, sid, mode, to) -> {ok => 1, short} or {why}: a background session's job folder
# whose state.json names this session (`job-unknown` otherwise); its respawnFlags a list
# whose restrictions a restart keeps (`restriction-lost`: a flag the keep-set drops, or no list
# at all, which Claude Code reads as none and respawns with no flag), and, on a target `to` whose
# keep-set was not checked, no flag outside @LOSS_OK (`keepset-unverified`); no bypass the relaunch
# mode has left (`bypass-left`): `--dangerously-skip-permissions`, or `--permission-mode
# bypassPermissions` (`=` form too), while the mode is not bypassPermissions.
# `--allow-dangerously-skip-permissions` alone is carried, as /restart carries it.
sub job {
    my ($jd, $sid, $mode, $to) = @_;
    return { why => 'job-unknown' } unless defined $jd && $jd =~ m{\A/} && -d $jd;
    (my $dir = $jd) =~ s{(?<=.)/+\z}{};
    my $short = util::basename($dir);
    return { why => 'job-unknown' } unless is_short($short);
    my $st = _json_file("$dir/state.json", 4 * 1024 * 1024) // return { why => 'job-unknown' };
    return { why => 'job-unknown' } unless defined $st->{sessionId} && !ref $st->{sessionId} && $st->{sessionId} eq $sid;
    # a restriction in the job's flags that a restart would not apply again
    return { why => 'restriction-lost' } if respawn_drops($st->{respawnFlags});
    return { why => 'keepset-unverified' } if !keepset_checked($to) && risky_flags($st->{respawnFlags});
    return { why => 'bypass-left' } if defined $mode && $mode ne 'bypassPermissions' && bypass_flags($st->{respawnFlags});
    return { ok => 1, short => $short, flags_mode => flags_mode($st->{respawnFlags}) };
}

# keepset_checked(version) -> 1 for a version in @KEEPSET_CHECKED
sub keepset_checked { my ($v) = @_; return is_ver($v) && $KEEPSET_CHECKED{$v} ? 1 : 0 }

# risky_flags(respawnFlags) -> the flag names whose loss may widen the session, in order: every
# flag word outside @LOSS_OK, a --permission-mode of plan or dontAsk or with no value; `?` for
# respawnFlags that are not a list of strings.
sub risky_flags {
    my ($f) = @_;
    return ('?') unless ref $f eq 'ARRAY' && !grep { !defined $_ || ref $_ } @$f;
    my @a = @$f;
    my @r;
    for my $i (0 .. $#a) {
        next unless $a[$i] =~ /\A-/;
        my $eq = index($a[$i], '=');
        my $name = $eq < 0 ? $a[$i] : substr($a[$i], 0, $eq);
        if ($name eq '--permission-mode') {
            my $v = $eq < 0 ? $a[$i + 1] : substr($a[$i], $eq + 1);
            push @r, $name unless defined $v && $v =~ /\A(?:default|acceptEdits|auto|bypassPermissions)\z/;
            next;
        }
        push @r, $name unless $LOSS_OK{$name};
    }
    return @r;
}

# respawn_drops(respawnFlags) -> the names of the flags a restart of the job would drop that may
# restrict the session (every dropped flag but @DROP_OK, unknown ones included), in order; an
# empty list when it keeps every restriction. respawnFlags that are missing or not a list of
# strings count as one unknown flag (`?`). The walk is Claude Code 2.1.309-2.1.312's (the Sets
# are 2.1.311's and 2.1.312's): a flag word starting with `-`; `--name=value` keeps a @KEEP_VAL
# flag (and only the name of a @KEEP_BOOL one); a @KEEP_VAL flag in its space form takes the next
# word as its value (a @KEEP_VAR flag every following word up to the next flag) and is dropped
# when no word follows; a dropped flag takes the following words up to the next flag with it; a
# word that is not a flag's is dropped (a prompt).
sub respawn_drops {
    my ($f) = @_;
    return ('?') unless ref $f eq 'ARRAY' && !grep { !defined $_ || ref $_ } @$f;
    my @a = @$f;
    my @lost;
    for (my $i = 0; $i < @a; $i++) {
        my $w = $a[$i];
        next unless $w =~ /\A-/;
        my $eq = index($w, '=');
        my $name = $eq < 0 ? $w : substr($w, 0, $eq);
        my $kept;
        if ($eq >= 0) {
            $kept = $name ne '-m' && ($KEEP_VAL{$name} || $KEEP_BOOL{$name});
        } elsif ($KEEP_VAL{$name}) {
            $kept = $name ne '-m' && $i + 1 < @a;
            $i++ if $i + 1 < @a;
            if ($kept && $KEEP_VAR{$name}) { $i++ while $i + 1 < @a && $a[$i + 1] !~ /\A-/ }
        } else {
            $kept = $KEEP_BOOL{$name};
        }
        if (!$kept) {
            push @lost, $name unless $DROP_OK{$name};
            $i++ while $i + 1 < @a && $a[$i + 1] !~ /\A-/;
        }
    }
    return @lost;
}

# flags_mode(respawnFlags) -> the last --permission-mode value (`=` form too), or undef. Claude
# Code patches it as the mode changes, so it is the mode the respawn would start in.
sub flags_mode {
    my ($f) = @_;
    my @a = ref $f eq 'ARRAY' ? grep { defined && !ref } @$f : (defined $f && !ref $f) ? split(/\s+/, $f) : ();
    my $m;
    for my $i (0 .. $#a) {
        if ($a[$i] =~ /\A--permission-mode=(.*)\z/s) { $m = $1 }
        elsif ($a[$i] eq '--permission-mode' && defined $a[$i + 1]) { $m = $a[$i + 1] }
    }
    return $m;
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

# ---------------------------------------------------------------- hold, background work, transcript
# claude_json() -> Claude Code's own config file: <CLAUDE_CONFIG_DIR>/.claude.json, else
# $HOME/.claude.json (as deps.ts servedHint).
sub claude_json {
    my $d = $ENV{CLAUDE_CONFIG_DIR};
    $d = util::home() if !defined $d || $d eq '';
    $d =~ s{(?<=.)/+\z}{};
    return "$d/.claude.json";
}

# hold(to) -> undef, 'on-hold' or 'version-unknown' (/restart's above_max_version): the
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

# background(sid_dir) -> (why, types) from the newest Stop sidecar slot: any task listed is
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
# <sid>.jsonl (/restart's saving_off, not_written, gone).
sub transcript_ok {
    my ($d, $sid) = @_;
    my $t = read_mode($d)->{transcript};
    return 0 unless defined $t && !ref $t && util::basename($t) eq "$sid.jsonl";
    return (-f $t && -s _ > 0) ? 1 : 0;
}

# ---------------------------------------------------------------- the gate (helper part)
# gate(%a) -> {ok, why, setting, route, mode, effort, job_short, token, types, items, launcher}.
# a: sid, sid_dir, setting, route (fg|bg), launch, job_dir, from, to, model, seen_mode, seen_at,
# turn_at (the mod's reads), now (ms). First failure wins, in this order: off,
# unsupported-os, the route (no-launcher, launcher-invalid:*, job-unknown, restriction-lost,
# keepset-unverified), mode-unknown, note-pattern, bypass-not-available, launch-file, launcher-cap,
# bypass-left, background-work, crons, transcript, on-hold, version-unknown, then the ship gates
# fg-not-shipped and bg-not-shipped (not for shadow).
# Shadow (the trial data of the terminal route's ship decision): the launcher's checks and
# background work do not refuse; `launcher` says what the launcher check found (`ok` or its why) and `items` lists
# the background task types the newest Stop listed (items Claude Code's exit dialog would count).
sub gate {
    my (%a) = @_;
    my %r = (ok => 0, why => undef, setting => $a{setting}, route => $a{route}, mode => undef, effort => undef,
             job_short => undef, token => undef, types => [], items => [], launcher => undef);
    my $no = sub { $r{why} = $_[0]; return \%r };
    return $no->('off') unless ($a{setting} // 'off') =~ /\A(?:on|shadow)\z/;
    my $shadow = $a{setting} eq 'shadow';
    my $os = os_name();
    return $no->('unsupported-os') unless $os eq 'darwin' || $os eq 'linux';
    my $d = $a{sid_dir} // return $no->('no-watch');
    my ($lr, $jr);
    if (($a{route} // '') eq 'bg') {
        $jr = job($a{job_dir}, $a{sid}, undef, $a{to});
        return $no->($jr->{why}) unless $jr->{ok};
        $r{job_short} = $jr->{short};
    } else {
        $r{route} = 'fg';
        $lr = launcher($a{launch}, $a{sid});
        $r{launcher} = $lr->{ok} ? 'ok' : $lr->{why};
        if (!$lr->{ok}) {
            return $no->($lr->{why}) unless $shadow;
            $lr = undef;
        }
        $r{token} = $lr->{token} if $lr;
    }
    my $launch_mode = $lr && is_mode($lr->{lj}{launch_mode}) ? $lr->{lj}{launch_mode} : undef;
    my ($mode, $effort, $mwhy) = relaunch_mode(sid_dir => $d, seen_mode => $a{seen_mode}, seen_at => $a{seen_at},
                                               turn_at => $a{turn_at}, launch => $launch_mode);
    return $no->($mwhy) if defined $mwhy;
    ($r{mode}, $r{effort}) = ($mode, $effort);
    my $now_s = int(($a{now} // now_ms()) / 1000);
    if (($r{route} // '') eq 'fg') {
        return $no->('note-pattern') unless is_sid($a{sid}) && is_ver($a{from}) && is_ver($a{to}) && is_model($a{model} // '')
                                             && is_effort($effort // '') && is_mode($mode);
        if ($lr) {
            my $w = launcher_why($lr, $mode, $now_s);
            return $no->($w) if defined $w;
        }
    } else {
        # `bypass-left` against the relaunch mode; the respawn reads the job's flags again and
        # checks them against the mode they hold then (a Shift+Tab during the grace).
        $jr = job($a{job_dir}, $a{sid}, $mode, $a{to});
        return $no->($jr->{why}) unless $jr->{ok};
    }
    my ($bw, $types) = background($d);
    if (defined $bw) {
        if ($shadow && $bw eq 'background-work') { $r{items} = $types }
        else { $r{types} = $types; return $no->($bw) }
    }
    return $no->('transcript') unless transcript_ok($d, $a{sid});
    my $h = hold($a{to});
    return $no->($h) if defined $h;
    return $no->('fg-not-shipped') if $r{route} eq 'fg' && $a{setting} eq 'on' && !fg_route();
    return $no->('bg-not-shipped') if $r{route} eq 'bg' && $a{setting} eq 'on' && !bg_route();
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
    return _write_launch_file($dir, 'restart.note', l_text($n));
}

# _write_launch_file(launch, name, data): `<name>.tmp` (O_EXCL, 0600), then renamed `<name>`: the
# only names the launcher's cleanup knows (contract §1, §6).
sub _write_launch_file {
    my ($dir, $name, $data) = @_;
    my $tmp = "$dir/$name.tmp";
    unlink $tmp;
    my $fh;
    sysopen($fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600) or die "create $name: $!\n";
    my $off = 0;
    while ($off < length $data) {
        my $w = syswrite($fh, $data, length($data) - $off, $off);
        die "write $name: $!\n" unless defined $w;
        $off += $w;
    }
    close($fh) or die "close $name: $!\n";
    rename($tmp, "$dir/$name") or do { my $e = $!; unlink $tmp; die "rename $name: $e\n" };
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
# note (fg) and the carry note, both `armed`. The setting read again
# here must be `on` (`off` otherwise: a `shadow` arms nothing), and the terminal route needs its
# ship gate (`fg-not-shipped`), a second check behind the gate's. a: sid, sid_dir, setting,
# route, nonce, from, to, continue, mode, effort, model, launch, job_short, load_id, now (ms).
sub arm {
    my (%a) = @_;
    my $d = $a{sid_dir} // return { ok => 0, why => 'no-watch' };
    return { ok => 0, why => 'off' } unless ($a{setting} // 'off') eq 'on';
    return { ok => 0, why => 'note-pattern' }
        unless is_sid($a{sid}) && is_hex16($a{nonce}) && is_ver($a{from}) && is_ver($a{to}) && is_mode($a{mode})
               && is_effort($a{effort} // '') && is_model($a{model} // '') && is_ms($a{now});
    my $route = ($a{route} // '') eq 'bg' ? 'bg' : 'fg';
    return { ok => 0, why => 'fg-not-shipped' } if $route eq 'fg' && !fg_route();
    return { ok => 0, why => 'bg-not-shipped' } if $route eq 'bg' && !bg_route();
    my ($token, $dir);
    if ($route eq 'fg') {
        my $lr = launcher($a{launch}, $a{sid});
        return { ok => 0, why => $lr->{why} } unless $lr->{ok};
        ($token, $dir) = ($lr->{token}, $lr->{dir});
        # The binding (contract §2, §6): once with O_EXCL; rewritten for this session when the
        # claude that bound it is this one under another session id (`/clear`, `/resume`) or is
        # gone (before a relaunch), and for this claude when the file names an earlier one.
        my $c = rc::claude();
        my $text = bind_text($a{sid}, $c);
        if (!util::write_excl("$dir/sid", $text, 0600)) {
            my ($b, $by) = bound_sid($dir);
            my $same = defined $b && $b eq $a{sid};
            return { ok => 0, why => 'launcher-invalid:other-session' } unless $same || rebindable($by, $c);
            my $raw = util::read_file("$dir/sid", 512) // '';
            _write_launch_file($dir, 'sid', $text) if $raw ne $text && (!$same || rebindable($by, $c));
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
# first (the `go` that the launcher acts on is the first write). l and c: `written`,
# `absent`, `mismatch` (another nonce or session) or `final` (the note already ended). The two
# states the launcher acts on are checked again behind the gate and the arm, nothing written
# when they fail: `exiting` and `go` need the terminal route's ship gate (`fg-not-shipped`), and
# `exiting` (written before the plugin's /exit) the setting still `on` (`off`). a: sid,
# sid_dir, setting, nonce, state, now (ms), exiting_at (ms, optional), launch (fg).
sub set_state {
    my (%a) = @_;
    my $state = $a{state} // '';
    return { ok => 0, l => 'absent', c => 'absent', why => 'usage' } unless $C_STATE{$state} && is_hex16($a{nonce}) && is_ms($a{now});
    if ($state eq 'exiting' || $state eq 'go') {
        return { ok => 0, l => 'absent', c => 'absent', why => 'fg-not-shipped' } unless fg_route();
        return { ok => 0, l => 'absent', c => 'absent', why => 'off' } if $state eq 'exiting' && ($a{setting} // 'off') ne 'on';
    }
    my $d = $a{sid_dir};
    return _set_state(%a) unless defined $d;
    return lock::with(lock_path($d), { sid => $a{sid}, actor => 'restart' }, sub { _set_state(%a) }, wait_ms => 1000);
}

sub _set_state {
    my (%a) = @_;
    my ($l, $c) = ('absent', 'absent');
    my $state = $a{state};
    my $now = $a{now};
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
# carry note by renaming it to restart.claimed-<load_id>.json (one winner). fg: route fg,
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
# that session's; with take each one read is deleted (the next load of that session reports it),
# and so is any session's older than $REPORT_MS (the cache folder is not cleaned by the system).
sub refusals {
    my (%o) = @_;
    my $rt = defined $o{launch} && $o{launch} =~ m{\A/} ? util::dirname($o{launch} =~ s{(?<=.)/+\z}{}r) : runtime_dir();
    return () unless defined $rt && !defined private_dir($rt);
    my $now_s = int(util::now());
    my @out;
    for my $f (util::list_dir($rt)) {
        next unless $f =~ /\Alast-refusal-[0-9a-f]{16}\z/;
        my $p = "$rt/$f";
        next if -l $p || !-f $p;
        my $raw = util::read_file($p, 4096) // next;
        my %v = $raw =~ /^(proto|reason|sid|at)=([^\n]*)$/mg;
        next unless ($v{proto} // '') eq "$PROTO" && ($v{reason} // '') =~ /\A[a-z][a-z-]{0,31}\z/ && ($v{at} // '') =~ /\A[0-9]{1,11}\z/;
        if ($o{take} && ($now_s - $v{at}) * 1000 >= $REPORT_MS) {
            unlink $p;
            next;
        }
        my $sid = is_sid($v{sid}) ? $v{sid} : undef;
        next if defined $o{sid} && (!defined $sid || $sid ne $o{sid});
        push @out, { sid => $sid, reason => $v{reason}, at => 0 + $v{at} };
        unlink $p if $o{take};
    }
    return sort { $b->{at} <=> $a->{at} } @out;
}

# ---------------------------------------------------------------- the background respawn
# claude_bin() -> `claude` from PATH, else $HOME/.local/bin/claude when executable
sub claude_bin {
    my $c = util::which('claude');
    return $c if defined $c;
    my $h = util::home() . '/.local/bin/claude';
    return -x $h ? $h : undef;
}

# code_of(output, rc) -> the first @B6 code the respawn client's output names; `other` for a
# non-zero rc without one, undef for rc 0 without one.
sub code_of {
    my ($out, $rc) = @_;
    for my $c (@B6) { return $c if index($out // '', $c) >= 0 }
    return $rc ? 'other' : undef;
}

# respawn(%a) -> {ok, pid, why}: starts `claude respawn <short>` detached, the way /restart starts
# it (R5): the helper forks; that child forks the grandchild and exits at once, so the grandchild
# is no descendant of the worker; the grandchild calls setsid (its own session and process
# group, no terminal), takes stdin from /dev/null, writes restart-respawn.pid (its pid, which is
# also its process group, with its start time and the nonce, for respawn-cancel) before anything
# else, and only then answers the helper. Right before the client runs it reads the carry note
# once more and stops unless the note is still `sent` with its nonce (a cancel, or a failure the
# mod settled, since the call). Then it drops every R5 name from its environment, runs the client
# as its own child (stdout and stderr captured, at most $OUT_MAX bytes) and waits; it writes
# restart-respawn.out (0600), restart-respawn.json {nonce, rc, code, at} and, on a non-zero rc,
# one `refresh_failed {route: bg, why: respawn-failed, code}` row. Before any of it, the job's
# state.json is read again: this session's, and no bypass in its respawnFlags that the mode
# they hold now (the last --permission-mode, which Claude Code keeps current; else the
# gate's relaunch mode) has left (`bypass-left`), and the keep-set checks against the target (`to`).
# First of all, a second check behind the gate's and the arm's: the background route's ship gate
# (`bg-not-shipped`) and the setting read again (`off` unless it is `on`, so turning it off during
# the grace stops the respawn). a: sid, sid_dir, setting, short, nonce, to, job_dir, mode, wait_ms
# (test mode only: wait that long for the result file before replying).
sub respawn {
    my (%a) = @_;
    return { ok => 0, why => 'bg-not-shipped' } unless bg_route();
    return { ok => 0, why => 'off' } unless ($a{setting} // 'off') eq 'on';
    my $d = $a{sid_dir} // return { ok => 0, why => 'no-watch' };
    return { ok => 0, why => 'usage' } unless is_short($a{short}) && is_hex16($a{nonce}) && is_mode($a{mode});
    my $claude = claude_bin() // return { ok => 0, why => 'no-claude' };
    my $jr = job($a{job_dir}, $a{sid}, undef, $a{to});
    return { ok => 0, why => $jr->{why} } unless $jr->{ok} && $jr->{short} eq $a{short};
    my $fm = $jr->{flags_mode};
    $jr = job($a{job_dir}, $a{sid}, is_mode($fm) ? $fm : $a{mode}, $a{to});
    return { ok => 0, why => $jr->{why} } unless $jr->{ok};
    # the carry note becomes `sent` in the call that starts the respawn
    my $sent = lock::with(lock_path($d), { sid => $a{sid}, actor => 'restart' }, sub {
        my $c = read_c($d);
        return 0 unless $c && ($c->{nonce} // '') eq $a{nonce} && ($c->{route} // '') eq 'bg' && ($c->{state} // '') eq 'armed';
        $c->{state} = 'sent';
        $c->{at} = now_ms();
        write_c($d, $c);
        return 1;
    }, wait_ms => 1000);
    return { ok => 0, why => 'no-note' } unless $sent;
    unlink result_path($d), out_path($d), pid_path($d);
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
        # the pid record first, so a cancel from here on finds this process group
        # (the helper above may be stopped by its time bound at any moment)
        my $rec = eval {
            util::write_atomic(pid_path($d), jsonc::encode_bytes(jsonc::obj(nonce => $a{nonce}, pid => 0 + $$,
                                             lstart => identity::start_time($$))) . "\n", 0600);
            1;
        };
        POSIX::_exit(1) unless $rec;
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
    if (util::test_mode() && is_ms($a{wait_ms})) {
        my $t0 = util::clock_ms();
        util::sleep_ms(50) while !-e result_path($d) && util::clock_ms() - $t0 < $a{wait_ms};
    }
    return { ok => 1, pid => 0 + $g };
}

sub _grandchild {
    my (%a) = @_;
    $SIG{HUP} = 'IGNORE';
    my $d = $a{sid_dir};
    # Test seam: a pause between the pid record and the note check (a cancel in that gap).
    util::sleep_ms(0 + $ENV{STORE_TEST_RESPAWN_PAUSE_MS}) if util::test_mode() && is_ms($ENV{STORE_TEST_RESPAWN_PAUSE_MS});
    my $go = eval {
        lock::with(lock_path($d), { sid => $a{sid}, actor => 'restart' }, sub {
            my $c = read_c($d);
            return ($c && ($c->{nonce} // '') eq $a{nonce} && ($c->{state} // '') eq 'sent') ? 1 : 0;
        }, wait_ms => 1000, log => 0);
    };
    if (!$go) {
        unlink pid_path($d);
        return;
    }
    delete $ENV{$_} for @ST, 'CLAUDE_JOB_DIR';
    delete $ENV{$_} for grep { /\ACLAUDE_BG_/ } keys %ENV;
    my ($rc, $out) = _capture([$a{claude}, 'respawn', $a{short}], $RESPAWN_MS);
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

# respawn_cancel(sid_dir, nonce, state) -> {ok, killed, note}: first the carry note: this nonce's
# background note still `armed` or `sent` becomes `state` (`cancelled`, or `failed` for the mod's
# failures), so a detached respawn that has not reached its own check of the note never runs the
# client (`note` 1 when written); then TERM to the grandchild's process group when its record
# holds this nonce and that process still runs with the start time recorded.
sub respawn_cancel {
    my ($d, $nonce, $state) = @_;
    $state = 'cancelled' unless defined $state && $state eq 'failed';
    return { ok => 1, killed => 0, note => 0 } unless defined $d && is_hex16($nonce);
    my $note = eval {
        lock::with(lock_path($d), { sid => rc::sid(), actor => 'restart' }, sub {
            my $c = read_c($d);
            return 0 unless $c && ($c->{nonce} // '') eq $nonce && ($c->{route} // '') eq 'bg'
                            && ($c->{state} // '') =~ /\A(?:armed|sent)\z/;
            $c->{state} = $state;
            $c->{at} = now_ms();
            write_c($d, $c);
            return 1;
        }, wait_ms => 1000);
    } ? 1 : 0;
    my $p = _json_file(pid_path($d), 4096);
    return { ok => 1, killed => 0, note => $note } unless $p && ($p->{nonce} // '') eq $nonce && ($p->{pid} // '') =~ /\A[1-9][0-9]*\z/;
    my $pid = $p->{pid};
    # a start time this call cannot read never authorises the TERM (alive_verified)
    return { ok => 1, killed => 0, note => $note } unless identity::alive_verified($pid, $p->{lstart});
    my $n = kill('TERM', -$pid);
    $n += kill('TERM', $pid);
    unlink pid_path($d);
    return { ok => 1, killed => $n ? 1 : 0, note => $note };
}

# ---------------------------------------------------------------- after-kill scan
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
