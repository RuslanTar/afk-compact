# cmd/status.pl: `status --sid S` (MOD-SPEC §11; BUILD-PLAN §3.1). Owner: WP-core
# (+ watch.status_lines). Lines: effective thresholds (clamped marked), last 5
# compactions (seat_state, trigger, verdict, copy path), open escalations, halt
# state and continues this hour, smokeDue with the user-run smoke line, policy
# flags, unsafe roots, the handoff-root mode (MOD-SPEC §11 Block C, D-12), automatic
# relaunch (Dev-1, DP-2), settings notes, then the watcher's open alerts. Never content.
# 2026-10-22: the first line is the watcher line (W-BETA A) with the first-run notice when its
# marker is missing; the min_window sentence (P5-FOLD A3); the allow rule, the stale-rule check
# and the user-run lines with the real plugin folder (PKG-RUNTIME A.6; read only, nothing is
# written); relaunch_allow active (S-SETTINGS C); the unattended_prod_reads line (S-SETTINGS B);
# the kept mismatch stashes with their paths (C-STORE D3).
use strict;
use warnings;
use utf8;

package cmd_status;

our @ESCALATIONS = qw(copy_failed copy_mismatch copy_late verdict_mismatch root_in_git precompact_marker_orphan
                      sessionstart_ambiguous scope_leak layers_missing bypass_suspected mod_off resume_undelivered
                      halt thrash self_call_hook_ran keyset_change order_anomaly trigger_unknown version_change
                      version_hint compaction_unresolved lock_stale watch_error lane_unknown config_ambiguous
                      relaunch_unmatched jobs_caller_refused);

# Status lines are text (MOD-SPEC §2.6 text encoding): rows and state files are decoded JSON
# (characters), byte paths are decoded where they join a line, and args::out encodes once.
sub _bytes_deep {
    my ($x) = @_;
    return [map { _bytes_deep($_) } @$x] if ref $x eq 'ARRAY';
    return { map { (util::text($_) => _bytes_deep($x->{$_})) } keys %$x } if ref $x eq 'HASH';
    return ref $x ? $x : util::text($x);
}

sub _last {
    my ($rows, $ev) = @_;
    for my $r (reverse @$rows) { return $r if ($r->{ev} // '') eq $ev }
    return undef;
}

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid root log-dir cwd)]);
    my $sid = args::init_sid($opt);
    my $d = rc::sid_dir();
    my @out;
    my $brand = ctx::brand();
    if (!defined $d) {
        args::out('status: no log folder (' . (rc::root_reason('log_dir') // 'unset') . ')');
        return 0;
    }
    my $mod = _bytes_deep(rollup::stream_rows(rc::stream_path('mod')));
    my $classic = _bytes_deep(rollup::stream_rows(rc::stream_path('classic')));
    my @all = (@$mod, @$classic);
    push @out, watcher_lines();

    # thresholds
    my $eff = _last($mod, 'config_effective');
    if ($eff) {
        my %cl;
        for my $r (grep { ($_->{ev} // '') eq 'config_clamped' } @$mod) { $cl{ $r->{key} } = $r->{configured} if defined $r->{key} }
        my @parts;
        for my $k (qw(target soft_max window native_trigger)) {
            next unless defined $eff->{$k};
            my $v = $eff->{$k};
            next if !ref $v && $v =~ /\A-/;    # a raw negative value is never shown (P5-FOLD A3)
            $v .= " (clamped from $cl{$k})" if exists $cl{$k};
            push @parts, "$k $v";
        }
        my $mw = (defined $eff->{min_window} && !ref $eff->{min_window} && $eff->{min_window} =~ /\A(?:\d+|never)\z/)
               ? $eff->{min_window} : min_window();
        push @parts, "min_window $mw";
        my $small = ($eff->{disabled} // '') eq 'trigger-disabled-small-window';
        my $state = ($eff->{disabled} && !$small) ? " · plugin compactions off ($eff->{disabled})" : '';
        push @out, 'thresholds: ' . join(' · ', @parts) . $state;
        push @out, small_window_line($eff->{window}, $mw) if $small;
    } else {
        push @out, sprintf('thresholds: no mod row yet (settings: target %s · soft max %s · min_window %s)',
                           rc::val('compact_target_tokens'), rc::val('compact_soft_max_tokens'), min_window());
    }
    push @out, 'triggers: off (triggers-off)' if grep { ($_->{ev} // '') eq 'triggers_off' } @$mod;

    # last 5 compactions
    my $rolls = _bytes_deep(rollup::rows($d));
    my @last = @$rolls > 5 ? @$rolls[-5 .. -1] : @$rolls;
    my $nonok = grep { defined $_->{verdict} && $_->{verdict} !~ /^ok(-trailer)?$/ } @last;
    # a kept rollup size that disagrees with the boundary row joined by nonce (PKG-RUNTIME E.2)
    my $jc = grep { $_->{join_conflict} } @$rolls;
    push @out, sprintf('compactions: %d in this session; last %d (%d not ok)%s:', scalar @$rolls, scalar @last, $nonok,
                       ($jc ? " · join_conflict $jc" : ''));
    for my $r (reverse @last) {
        push @out, sprintf('  %s · %s · %s · %s · %s · copy %s', $r->{ts} // '-', $r->{actor} // '-', $r->{seat_state} // '-',
                           $r->{trigger} // '-', $r->{verdict} // '-',
                           defined $r->{copy_path} ? util::abbrev(rc::root() . "/" . util::fsb($r->{copy_path})) : ($r->{copy} // 'none'));
    }

    # escalations
    my %n;
    for my $r (@all) { my $e = $r->{ev} // ''; $n{$e}++ if grep { $_ eq $e } @ESCALATIONS }
    # The classic saver has no mod stream: its EXISTS sha-differs (a second summary under one
    # nonce, which is not saved) counts as copy_mismatch; the mod logs its own for writer mod.
    $n{copy_mismatch} += grep { ($_->{ev} // '') eq 'copy' && ($_->{result} // '') eq 'mismatch' && ($_->{writer} // '') ne 'mod' } @$classic;
    my @esc = map { "$_ $n{$_}" } grep { $n{$_} } @ESCALATIONS;
    push @out, 'escalations: ' . (@esc ? join(', ', @esc) : 'none');

    # halt and continues (the mod writes halt.json as {active, reason, since})
    my $hraw = util::read_file("$d/halt.json");
    my $h = defined $hraw ? _bytes_deep(eval { jsonc::decode($hraw) }) : undef;
    my $halted = ref $h eq 'HASH' && ($h->{active} || $h->{halted}) ? 1 : 0;
    my $now = util::now();
    my $cont = grep { ($_->{ev} // '') eq 'continue' && ($_->{result} // '') eq 'submitted'
                      && $now - (util::parse_iso($_->{ts} // '') // 0) <= 3600 } @$mod;
    push @out, sprintf('halt: %s · continues this hour: %d of %s',
                       ($halted ? 'on (' . ($h->{reason} // 'unknown') . ')' : 'off'),
                       $cont, rc::val('max_auto_continues_per_hour'));

    # version / smoke
    my $vraw = util::read_file(rc::watch() . '/version.json');
    my $v = defined $vraw ? _bytes_deep(eval { jsonc::decode($vraw) }) : undef;
    if (ref $v eq 'HASH' && defined $v->{smokeDue} && $v->{smokeDue} ne '') {
        my $store = ctx::store_cmd();
        push @out, "smokeDue: $v->{smokeDue} (Claude Code changed; "
                   . (defined $store ? "run: ! " . util::text($store) . " smoke)"
                      : "run the plugin's smoke command; its folder path holds both quote kinds, so no command line can name it: store_path_unquotable)");
        push @out, '  the instruction text\'s "next window has / lacks" list was last reviewed for '
                   . ($v->{previousVersion} // 'the previous version') . '; live smoke subset to re-run: AT-M1-13, AT-M2-05, AT-M4-05';
    } else {
        push @out, 'smokeDue: none' . (ref $v eq 'HASH' && $v->{lastVersion} ? " (Claude Code $v->{lastVersion})" : '');
    }
    push @out, allow_lines($opt->{cwd}), user_run_lines($sid);

    # policy
    my $pol = _last($mod, 'policy');
    push @out, $pol ? sprintf('policy: mods managed only %s · hooks managed only %s',
                              ($pol->{mods_managed_only} ? 'yes' : 'no'), ($pol->{hooks_managed_only} ? 'yes' : 'no'))
                    : 'policy: no mod row yet';

    # unsafe roots
    for my $key (qw(handoff_root log_dir disposable_root)) {
        push @out, "root: $key refused (" . util::text(rc::root_reason($key)) . '); copies and evidence under it are not written'
            unless rc::root_ok($key);
    }
    push @out, mode_lines($opt->{cwd});
    push @out, relaunch_lines($d);
    push @out, prod_lines();
    push @out, idle_lines(), settings_keys_line();
    # Q-ADAPTER QA-1: the queue adapter mode (no queue call: the setting, the file and this
    # session's last list outcome); /status is the only place that says `queue: off`
    push @out, 'queue: ' . queue::mode_text();
    push @out, kept_lines($sid);
    push @out, former_name_lines();
    push @out, map { "note: " . util::text($_) } @{ rc::settings()->{notes} || [] };

    my $last_row = (sort map { $_->{ts} // '' } @$classic)[-1];
    push @out, 'last hook row: ' . ($last_row // 'none');

    # watcher lines (WP-watch)
    # The seam returns [line] (lib/watch.pm); a plain list is taken too.
    my @wl = eval { require "watch.pm"; watch::status_lines($sid) };
    @wl = map { ref $_ eq 'ARRAY' ? @$_ : $_ } @wl;
    push @out, grep { defined && !ref } @wl;
    args::out(@out);
    return 0;
}

# Block C (D-12): the mode line; when declared but not accepted, the accept route (the
# /config row or editing settings.json by hand: the typed mod command waits for PR-2,
# DP-5); the ignored and .gitignore-drift notes; the exports in this worktree.
sub mode_lines {
    my ($cwd) = @_;
    my $m = rc::mode($cwd);
    my @l = ("handoff mode: $m->{mode} ($m->{reason})");
    my $root = util::text($m->{root_rel} // ($m->{decl} && $m->{decl}{root}) // $repomode::DEFAULT_ROOT);
    if ($m->{declared} && !$m->{accepted}) {
        push @l, '  this repository asks for repo mode; to accept it, add ' . util::text($m->{main_checkout} // $m->{toplevel})
                 . ' to repo_roots in /config (or in your settings file by hand)';
    }
    push @l, "  exports in $root are git-ignored; they will not be committed" if $m->{ignored};
    push @l, "  $root/.gitignore lacks the generated lines; the plugin never edits it" if $m->{gitignore_drift};
    push @l, "  exports in this worktree: $m->{exports} under $root" if $m->{declared} && defined $m->{root_rel};
    push @l, 'handoff_root must stay outside the repository; repo mode only exports into it' if $m->{declared} && $m->{store_inside};
    push @l, "  repo_roots: stale entry " . util::text($_) . " (not a folder)" for @{ $m->{stale} || [] };
    return @l;
}

# Dev-1 (DP-2, DP-24 (a)): automatic relaunch needs a job's output file; the source is the
# Bash result text (P-D1-6), checked against the task-file layout. The state follows
# relaunch_auto; this session's jobs without a confirmed output path ask. Then pending
# relaunches no recorded job matched.
my %RELAUNCH_STATE = (on => 'active (read-only jobs and allowlisted jobs)', shadow => 'shadow (reports would-relaunch, runs nothing)', off => 'off');
sub relaunch_lines {
    my ($d) = @_;
    my $rl = settings::relaunch(rc::settings());
    my @l;
    my $src = $jobrec::OUTPUT_PATH_SOURCE;
    my $state = $src eq 'none' ? 'inactive (no output path)' : $RELAUNCH_STATE{ $rl->{auto} } // 'off';
    push @l, "automatic relaunch: $state · relaunch_auto $rl->{auto}";
    if ($src ne 'none') {
        my @jobs = grep { ($_->{ev} // '') eq 'job' } @{ jobrec::read_rows(jobrec::jobs_path($d)) };
        my $with = grep { defined $_->{output_path} } @jobs;
        my $differs = grep { ($_->{output_path_check} // '') eq 'differs' } @jobs;
        my $line = $src eq 'layout' ? '  output path: from the task-file layout'
                 : '  output path: from the Bash result text, checked against the task-file layout';
        $line .= ' · this session ' . scalar(@jobs) . " jobs, $with with an output path" if @jobs;
        $line .= ", $differs differ from the layout" if $differs;
        push @l, $line;
    }
    # S-SETTINGS C (Q-J1-1): the allowlist is active; it acts only while relaunch_auto is on
    push @l, '  relaunch_allow: ' . scalar(@{ $rl->{allow} }) . ' patterns, '
              . ($rl->{auto} eq 'on' ? 'active' : "not used while relaunch_auto is $rl->{auto}")
        if @{ $rl->{allow} };
    push @l, "  config: $_->{key} invalid, " . ($_->{key} eq 'relaunch_auto' ? 'off used' : 'pattern dropped') for @{ $rl->{invalid} };
    push @l, "  config: $_->{key} $_->{configured} clamped to $_->{used}" for @{ $rl->{clamped} };
    for my $p (@{ jobrec::unmatched($d) }) {
        push @l, '  relaunch unmatched: ' . ($p->{task_id} // '-') . ' (no recorded job ran the bumped command)';
    }
    return @l;
}

# ---------------------------------------------------------------- watcher (W-BETA A)
# The first line: the watcher state, the size of its logs and the number of sessions; with
# `off` what stays written. The first-run notice line while its marker is missing (the mod
# claims it at session.start; a session where the mod never ran shows it here).
sub watcher_lines {
    my $w = lc(rc::val('watcher') // 'shadow');
    $w =~ s/^\s+|\s+$//g;
    my $brand = ctx::brand();
    return ('watcher: off · existing logs kept (nothing deleted) · core files still written: copies check, '
            . 'background list, heal counters, rollups, liveness') if $w eq 'off';
    my ($bytes, $sids) = _watch_size(rc::watch());
    my @l = ("watcher: shadow · logs " . _size($bytes) . " in $sids sessions · share: /$brand:report · off: watcher = off in /config");
    my $n = notice::spec();
    push @l, "notice: $n->{text}" unless notice::shown(rc::watch(), $n->{id});
    return @l;
}

# _watch_size(dir) -> (bytes of every file under it, sessions with a stream file); no symlink is
# followed; at most 100,000 entries are counted
sub _watch_size {
    my ($dir) = @_;
    my ($bytes, %sid, $n) = (0);
    my @stack = ($dir);
    while (@stack && ($n // 0) < 100_000) {
        my $d = pop @stack;
        for my $e (util::list_dir($d)) {
            $n++;
            my $p = "$d/$e";
            next if -l $p;
            if (-d _) { push @stack, $p; next }
            $bytes += -s _ // 0 if -f _;
            $sid{$1} = 1 if $d eq $dir && $e =~ /\A([0-9A-Za-z][0-9A-Za-z._-]*?)(?:\.classic|\.alerts)?\.jsonl\z/;
        }
    }
    return ($bytes, scalar keys %sid);
}

sub _size {
    my ($b) = @_;
    return "$b B" if $b < 1024;
    return sprintf('%d KB', int($b / 1024 + 0.5)) if $b < 1024 * 1024;
    return sprintf('%.1f MB', $b / (1024 * 1024)) if $b < 1024 * 1024 * 1024;
    return sprintf('%.1f GB', $b / (1024 * 1024 * 1024));
}

# ---------------------------------------------------------------- min_window (P5-FOLD A3)
# The smallest window that keeps plugin compactions on with these settings, from the shared
# clamp constants (spec `clamp`, the same object the mod and the watcher read; these literals
# are its fallback): max(soft_needed + native_offset + reserve, ceil(soft_needed / soft_ratio)),
# soft_needed = ceil(min_target * target_den / target_num); `never` when compact_target_tokens
# is below min_target or compact_soft_max_tokens below soft_needed.
our %CLAMP_FALLBACK = (native_offset => 33000, min_target => 120000, reserve_base => 52000, reserve_no_handoff => 100000,
                       window_floor => 100000, soft_ratio => 0.8, target_num => 2, target_den => 3,
                       handoff_tokens_min => 20000, handoff_tokens_max => 150000);
sub clamp_constants {
    my $c = spec::has('clamp') ? eval { spec::get('clamp') } : undef;
    my %k = %CLAMP_FALLBACK;
    if (ref $c eq 'HASH') {
        for my $x (keys %CLAMP_FALLBACK) { $k{$x} = $c->{$x} if defined $c->{$x} && !ref $c->{$x} && $c->{$x} =~ /\A\d+(?:\.\d+)?\z/ && $c->{$x} > 0 }
    }
    return \%k;
}

sub _ceil { my ($x) = @_; my $i = int($x); return $i < $x ? $i + 1 : $i }

sub min_window {
    my $c = clamp_constants();
    my $target = rc::val('compact_target_tokens') // 0;
    my $soft = rc::val('compact_soft_max_tokens') // 0;
    my $need = _ceil($c->{min_target} * $c->{target_den} / $c->{target_num});
    return 'never' if $target < $c->{min_target} || $soft < $need;
    my $ht = lc(rc::val('handoff_turn') // 'halt');
    $ht =~ s/^\s+|\s+$//g;
    my $h = rc::val('handoff_turn_max_tokens') // 64000;
    $h = $c->{handoff_tokens_min} if $h < $c->{handoff_tokens_min};
    $h = $c->{handoff_tokens_max} if $h > $c->{handoff_tokens_max};
    my $reserve = $ht eq 'off' ? $c->{reserve_no_handoff} : $c->{reserve_base} + $h;
    my $a = $need + $c->{native_offset} + $reserve;
    my $b = _ceil($need / $c->{soft_ratio} - 1e-9);
    return $a > $b ? $a : $b;
}

# The disabled-for-a-small-window sentence; never a negative number.
sub small_window_line {
    my ($win, $mw) = @_;
    my $w = (defined $win && !ref $win && $win =~ /\A\d+\z/) ? $win : undef;
    return 'plugin compactions off: no window turns them on with these settings (compact_target_tokens or compact_soft_max_tokens too low)'
        if $mw eq 'never';
    return defined $w ? "plugin compactions off: window $w is below $mw, the smallest for these settings"
                      : "plugin compactions off: the window is below $mw, the smallest for these settings";
}

# ---------------------------------------------------------------- allow rule (PKG-RUNTIME A.6)
# The rule for default mode with the absolute current folder, and one line per older plugin
# folder that an allow rule in the user's or the project's settings still names. Read only:
# nothing is written and no settings file is edited (D-2).
sub allow_lines {
    my ($cwd) = @_;
    my $store = ctx::store_cmd();
    my $root = ctx::root();
    return ('allow rule (default mode): none (the plugin folder path holds both quote kinds: store_path_unquotable)')
        unless defined $store;
    my @l = ('allow rule (default mode): Bash(' . util::text($store) . ' wait *)');
    my %cur = map { ($_ => 1) } grep { defined && $_ ne '' } ($root, $ENV{CLAUDE_PLUGIN_ROOT}, util::real_path($ENV{CLAUDE_PLUGIN_ROOT} // ''));
    my %old;
    for my $f (_allow_files($cwd)) {
        for my $old (_rule_folders($f)) { $old{$old} = 1 unless $cur{$old} || $cur{ util::real_path($old) // '' } }
    }
    push @l, 'allow rule for an older plugin folder: ' . util::abbrev($_) . '; current: ' . util::abbrev($root) for sort keys %old;
    return @l;
}

sub _allow_files {
    my ($cwd) = @_;
    my @f;
    my $cfg = $ENV{CLAUDE_CONFIG_DIR};
    push @f, "$cfg/settings.json" if defined $cfg && $cfg ne '';
    push @f, util::home() . '/.claude/settings.json';
    $cwd //= do { require Cwd; Cwd::getcwd() };
    my @proj = grep { defined } ($cwd);
    my $g = defined $cwd ? eval { git::where($cwd, 1000) } : undef;
    push @proj, $g->{toplevel} if ref $g eq 'HASH' && defined $g->{toplevel};
    for my $p (@proj) { push @f, "$p/.claude/settings.json", "$p/.claude/settings.local.json" }
    my %seen;
    return grep { !$seen{$_}++ && -f $_ && !-l $_ } @f;
}

# _rule_folders(settings file) -> the plugin folders its permissions.allow entries name before
# the launcher path part (/scripts/ and the launcher's file name)
sub _rule_folders {
    my ($f) = @_;
    my $raw = util::read_file($f, 4 * 1024 * 1024) // return ();
    my $j = eval { jsonc::decode($raw) };
    return () unless ref $j eq 'HASH' && ref $j->{permissions} eq 'HASH' && ref $j->{permissions}{allow} eq 'ARRAY';
    my $tail = '/' . $ctx::LAUNCHER_DIR . '/' . ctx::brand() . '-store';
    my @out;
    for my $e (@{ $j->{permissions}{allow} }) {
        next if ref $e || !defined $e;
        my $s = $e;
        utf8::encode($s) if utf8::is_utf8($s);
        my $pos = 0;
        while ((my $i = index($s, $tail, $pos)) >= 0) {
            my $before = substr($s, 0, $i);
            $before =~ s/\A.*["'(\s]//s;
            push @out, $before if $before =~ m{\A/};
            $pos = $i + length $tail;
        }
    }
    return @out;
}

# The commands the user types (with the leading !), with the real plugin folder.
sub user_run_lines {
    my ($sid) = @_;
    my $store = ctx::store_cmd() // return ();
    $store = util::text($store);
    return ('user-run commands (type them yourself, with the leading !):',
            map { "  ! $store $_" } ('smoke', 'project init', 'project copy', 'watch prune',
                                     "reconcile --sid $sid --orphans --full", 'report'));
}

# ---------------------------------------------------------------- prod reads (S-SETTINGS B)
my %SRC = (settings => 'settings file', default => 'default', safe => 'safe value');
sub prod_lines {
    my $r = rc::settings();
    my $p = eval { settings::prod($r) } || { reads => 'forbid', user => 0, invalid => [] };
    my $src = $SRC{ $r->{source}{unattended_prod_reads} // 'default' } // 'default';
    my $shipped = scalar(@{ $p->{classes} || [] }) - ($p->{user} // 0);
    my @l = ("unattended_prod_reads: $p->{reads} ($src) · production patterns: "
             . ($shipped > 0 ? 'prod-token' : 'none') . ' + ' . ($p->{user} // 0) . ' yours');
    for my $i (@{ $p->{invalid} || [] }) {
        push @l, $i->{key} eq 'prod_patterns' ? "  config: prod_patterns #$i->{index} invalid, dropped"
                                               : "  config: $i->{key} invalid, forbid used";
    }
    return @l;
}

# ---------------------------------------------------------------- pre-idle turn (IA-4) and SK-7
# IA-4 (idle D3, owner 2026-10-23 02:4x; reworded by owner xxxxxxxx-17, "Check outcome at
# 55.5m"): when the plugin's own pre-idle handoff turn runs. `idle_handoff_turn: auto` with Claude
# Code's idle compaction off (`idleCompaction`, or its precondition `autoCompactEnabled`, false in
# the user settings file): at 49 minutes. Native on, or a file that cannot be read as JSON (O-9:
# "unreadable means check what happened"): the plugin checks at 55.5 minutes and runs its turn
# only when native did not compact (not while agents run, owner xxxxxxxx-38). A missing file or
# key is on, as the mod reads the merged settings (deps.nativeIdle). This line reads the user file
# only; the mod's own reading is the one that arms the timer.
sub _json_false { my ($v) = @_; return jsonc::is_bool($v) && !$$v ? 1 : 0 }
sub idle_lines {
    my $r = rc::settings();
    my $mode = lc($r->{values}{idle_handoff_turn} // 'auto');
    return ('pre-idle handoff turn: off (idle_handoff_turn: off)') if $mode eq 'off';
    my $file = settings::config_dir() . '/settings.json';
    my $native = 'on';
    if (-e util::to_bytes($file)) {
        my $raw = util::read_file($file);
        my $j = defined $raw ? eval { jsonc::decode($raw) } : undef;
        if (ref $j ne 'HASH') { $native = 'unknown' }
        elsif (_json_false($j->{idleCompaction}) || _json_false($j->{autoCompactEnabled})) { $native = 'off' }
    }
    return ('pre-idle handoff turn: auto (native idle compaction off → the plugin\'s turn at 49 min)') if $native eq 'off';
    return ('pre-idle handoff turn: auto (native idle compaction ' . ($native eq 'on' ? 'on' : 'unreadable')
            . ' → the plugin checks at 55.5 min and runs its turn only if native did not compact)');
}

# SK-7 (owner xxxxxxxx-12/-13/-14): the six 2026-10-23 keys as values the user can check, never
# the ticket pattern or a secret rule's text.
sub settings_keys_line {
    my $r = rc::settings();
    my $v = $r->{values} || {};
    my $rp = ($v->{resume_proceed} // '') eq 'confirm' ? 'confirm' : 'auto';
    my $tr = eval { settings::ticket_re($r) } || {};
    my $tk = $tr->{invalid} ? 'invalid (default used)' : $tr->{custom} ? 'custom' : 'default';
    my $sx = eval { settings::secret_extra($r) } || {};
    my $nx = scalar(@{ $sx->{rules} || [] }) + scalar(@{ $sx->{names} || [] });
    my @n = map { my ($x) = eval { settings::num_clamped($_, $r) }; defined $x ? $x : '?' }
            qw(handoff_reuse_window_min evidence_total_max_mb watch_quota_mb);
    return (sprintf('settings: resume_proceed %s (%s) · handoff_reuse_window_min %s · ticket_pattern %s · secret_extra_rules %d · evidence_total_max_mb %s · watch_quota_mb %s',
                    $rp, $r->{source}{resume_proceed} // 'default', $n[0], $tk, $nx, $n[1], $n[2]));
}

# Rename order (ruling xxxxxxxx-32, 2026-10-23): options saved in the settings file under the
# plugin's former name are not read. One line per such key, with its option count and the key
# to move them to (the key this plugin reads now, else `<name>@…`); read-only, never a value.
sub former_name_lines {
    my $r = rc::settings();
    my $now = defined $r->{config_key} && $r->{config_key} ne 'ambiguous' ? $r->{config_key} : ctx::brand() . '@…';
    return map {
        my ($k, $n) = @$_;
        sprintf('warning: %d plugin %s saved under the old name "%s" %s not read; move %s to "%s" in /config',
                $n, ($n == 1 ? ('option', util::text($k), 'is', 'it') : ('options', util::text($k), 'are', 'them')), util::text($now));
    } eval { settings::former_name_keys() };
}

# ---------------------------------------------------------------- kept stashes (C-STORE D3)
# Stashes kept after a real copy mismatch (pending/*.mismatch.md, redacted, never deleted by
# the plugin), in every session folder: the count and the paths (at most 10 shown).
our $KEPT_SHOW = 10;
sub kept_lines {
    my ($sid) = @_;
    my $w = rc::watch() // return ();
    my @kept;
    for my $s (util::list_dir($w)) {
        next if $s =~ /\A\./ || !-d "$w/$s/pending";
        push @kept, map { "$w/$s/pending/$_" } grep { /\.(?:post|mod)\.mismatch\.md\z/ } util::list_dir("$w/$s/pending");
    }
    return () unless @kept;
    @kept = sort @kept;
    my @l = ('kept mismatch stashes: ' . scalar(@kept) . ' (redacted; the plugin never deletes them)');
    push @l, map { '  ' . util::abbrev($_) } @kept[0 .. ($#kept < $KEPT_SHOW - 1 ? $#kept : $KEPT_SHOW - 1)];
    push @l, '  (+' . (@kept - $KEPT_SHOW) . ' more)' if @kept > $KEPT_SHOW;
    return @l;
}

exit(args::main(\&run, @ARGV));
