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
# the kept mismatch stashes with their paths (C-STORE D3). 2026-10-23 (owner xxxxxxxx-29): the
# protected branches line with a warning per ignored protected_branches entry.
# 2026-10-26 (CW-1): `status` without a session id (missing, empty or unsubstituted --sid):
# `session: unknown (no session id)` and the store-wide lines only; nothing is written. A
# placeholder id (`unknown`, `smoke`, `anon-*`) is taken the same way (CW-1 review).
# U-06: a warning per pattern of the user's stopped at its time bound (lib/userre.pm).
# 2026-10-27 (headless probe): `automatic compaction: not available here …` for a headless load,
# from the mod's `headless` row; `automatic compaction: by /compact …` while its `/compact` path is
# on (`compact: command`). IDLE-COMPACT-SPEC §4.1 B: the `idle compaction: …` line (who compacts an
# idle session, from the mod's `idle_mode` row) replaces the `pre-idle handoff turn: …` line.
# 2026-10-27 (SESSION-RESTART §6.1): the `restart on update` lines after the automatic relaunch
# lines: the setting and the route (the launcher's install line when a terminal session was not
# started through it), the drift, this session's last outcome, and store-wide the background
# restarts that failed after the kill and the launcher's refusals, each with its resume command.
# 0.1.2 visible defaults: the `settings values:` block after the `settings:` line (each value with
# its source and default; a warning per saved ""), also without a session id, and the user-run
# `settings reset <key> --apply` line.
# 0.1.3 (alert noise): a one-line verdict comes before the watcher line (`ok: …` or `attention: …`).
# 0.1.3 version skew: `plugin: <version> · <folder>` after the watcher lines, then `plugin notice: …`
# when sessions started since this one run another plugin version (lib/plugver.pm); with no log
# folder (a refused root) the version line still follows the refusal line.
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
    # CW-1 (Cowork check 2026-10-26): status only reads, so a missing, empty or unsubstituted
    # --sid gives the store-wide lines and `session: unknown (no session id)` instead of a
    # refusal; this session's lines are left out and nothing is written (no preamble rows, no
    # once markers, no session folder). A value that is not a session id is still refused. A
    # placeholder id (args::reserved_sid: `unknown`, `smoke`, `anon-*`) names a pool of rows
    # from many sessions, not this one, so it takes the same no-id path (CW-1 review).
    my $sid;
    if (args::no_sid($opt->{sid}) || args::reserved_sid($opt->{sid})) {
        rc::init(sid => undef, writer => 'helper', flags => settings::flags_from($opt));
    } else {
        $sid = args::init_sid($opt);
    }
    my $d = rc::sid_dir();
    my @out;
    my $brand = ctx::brand();
    if (!defined rc::watch()) {
        # the roots that refused it, with the fix for one in git (a home folder that is a dotfiles
        # repository refuses the default ~/.local/state/<plugin>/ root until it is ignored there)
        args::out('status: no log folder (' . (rc::root_reason('log_dir') // 'unset') . ')', plugin_lines(), root_lines());
        return 0;
    }
    push @out, verdict_lines($sid), watcher_lines(), plugin_lines();
    if (!defined $sid) {
        push @out, "session: unknown (no session id); this session's compactions, escalations, halt, policy and hook rows are not shown";
        push @out, sprintf('thresholds: settings only (target %s · soft max %s · min_window %s)',
                           rc::val('compact_target_tokens'), rc::val('compact_soft_max_tokens'), min_window());
        push @out, smoke_lines(), allow_lines($opt->{cwd}), user_run_lines(undef);
        push @out, store_lines($opt->{cwd}, undef, undef, undef, undef, []);
        push @out, watch_lines(undef);
        args::out(@out);
        return 0;
    }
    my $mod = _bytes_deep(rollup::stream_rows(rc::stream_path('mod')));
    my $classic = _bytes_deep(rollup::stream_rows(rc::stream_path('classic')));
    my @all = (@$mod, @$classic);

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
    my $headless = is_headless($mod);
    push @out, headless_lines($headless);

    # last 5 compactions
    my $rolls = _bytes_deep(rollup::rows($d));
    my @last = @$rolls > 5 ? @$rolls[-5 .. -1] : @$rolls;
    my $nonok = grep { defined $_->{verdict} && $_->{verdict} !~ /^ok(?:-trailer|-unclosed)?$/ } @last;
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
                       $cont, (eval { settings::num_clamped('max_auto_continues_per_hour') })[0] // rc::val('max_auto_continues_per_hour'));

    push @out, smoke_lines(), allow_lines($opt->{cwd}), user_run_lines($sid);

    # policy
    my $pol = _last($mod, 'policy');
    push @out, $pol ? sprintf('policy: mods managed only %s · hooks managed only %s',
                              ($pol->{mods_managed_only} ? 'yes' : 'no'), ($pol->{hooks_managed_only} ? 'yes' : 'no'))
                    : 'policy: no mod row yet';
    push @out, store_lines($opt->{cwd}, $d, $classic, $headless, $sid, $mod);

    my $last_row = (sort map { $_->{ts} // '' } @$classic)[-1];
    push @out, 'last hook row: ' . ($last_row // 'none');
    push @out, watch_lines($sid);
    args::out(@out);
    return 0;
}

# version / smoke (machine-wide: <watch>/version.json)
sub smoke_lines {
    my $vraw = util::read_file(rc::watch() . '/version.json');
    my $v = defined $vraw ? _bytes_deep(eval { jsonc::decode($vraw) }) : undef;
    return ('smokeDue: none' . (ref $v eq 'HASH' && $v->{lastVersion} ? " (Claude Code $v->{lastVersion})" : ''))
        unless ref $v eq 'HASH' && defined $v->{smokeDue} && $v->{smokeDue} ne '';
    my $store = ctx::store_cmd();
    return ("smokeDue: $v->{smokeDue} (Claude Code changed; "
            . (defined $store ? "run: ! " . util::text($store) . " smoke)"
               : "run the plugin's smoke command; its folder path holds both quote kinds, so no command line can name it: store_path_unquotable)"),
            '  the instruction text\'s "next window has / lacks" list was last reviewed for '
            . ($v->{previousVersion} // 'the previous version') . '; live smoke subset to re-run: AT-M1-13, AT-M2-05, AT-M4-05');
}

# The refused roots of the private store, one line each (unsafe roots, D-12). For roots in a git work tree
# and not ignored, one more line per folder to ignore: the roots, their work tree, and the two ways out
# (ignore the folder there, or set the key to a folder outside any work tree). A root under the state
# folder (~/.local/state/<plugin>, STATE-ROOT), which holds every default root, names that folder when it
# lies strictly inside the work tree: a home folder that is a git work tree (a dotfiles repository)
# refuses all of them until it is ignored. A work tree at or under the state folder (git init there)
# names the root's own path, joined by a later root under it in the same work tree (.watch under the
# handoff root); a root that is itself its work tree's top has nothing to ignore it in, so only the key
# to set. log_dir is named as a key only when it is set (unset, it follows handoff_root), unless it is
# the only key a line has.
sub root_lines {
    my @out;
    my $p = rc::paths() || {};
    my %path = (handoff_root => $p->{root}, log_dir => $p->{watch}, disposable_root => $p->{disposable});
    my $state = eval { util::dirname(paths::state_default()) };
    $state = undef if defined $state && $state eq '/';
    my $inside = sub {
        my ($real, $wt) = @_;
        my $top = $wt eq '/' ? '/' : "$wt/";
        return index($real, $top) == 0 && length($real) > length($top);
    };
    my @fix;
    for my $key (qw(handoff_root log_dir disposable_root)) {
        next if rc::root_ok($key);
        my $why = rc::root_reason($key);
        push @out, "root: $key refused (" . util::text($why) . '); copies and evidence under it are not written';
        next unless ($why // '') eq 'root-in-git' && defined $path{$key};
        my $wt = roots::check_path($path{$key})->{worktree};
        next unless defined $wt;
        my $at = $path{$key};
        my $dir = (defined $state && index("$at/", "$state/") == 0 && $inside->(util::real_path($state) // $state, $wt))
                ? $state : $at;
        my ($f) = grep { $_->{wt} eq $wt && index("$dir/", "$_->{dir}/") == 0 } @fix;
        push @fix, $f = { dir => $dir, wt => $wt } unless $f;
        push @{ $f->{paths} }, $at;
        push @{ $f->{all} }, $key;
        push @{ $f->{keys} }, $key unless $key eq 'log_dir' && (rc::val('log_dir') // '') eq '';
    }
    my $set = sub { 'set ' . join(' and ', @_) . ' in /config to ' . (@_ > 1 ? 'folders' : 'a folder') . ' outside any git work tree' };
    for my $f (@fix) {
        my $real = util::real_path($f->{dir}) // $f->{dir};
        my @keys = @{ $f->{keys} || [] };
        my $head = '  in git, not ignored: ' . join(', ', map { util::abbrev($_) } @{ $f->{paths} })
                 . ' (work tree ' . _home_form($f->{wt}) . '); to fix, ';
        if ($real eq $f->{wt}) {
            push @out, $head . $set->(@keys ? @keys : @{ $f->{all} });
            next;
        }
        my $top = $f->{wt} eq '/' ? '/' : "$f->{wt}/";
        my $line = $inside->($real, $f->{wt})
                 ? ' (the line /' . util::text(substr($real, length($top))) . '/ in ' . _home_form("$top.gitignore") . ')' : '';
        push @out, $head . 'ignore ' . util::abbrev($f->{dir}) . "/ there$line" . (@keys ? ', or ' . $set->(@keys) : '');
    }
    return @out;
}

# _home_form(real path) -> the path with the real home folder written `~` (a work tree is a real path).
sub _home_form {
    my ($p) = @_;
    my $h = util::real_path(util::home());
    if (defined $h && $h ne '' && $h ne '/') {
        return '~' if $p eq $h;
        return '~/' . util::text(substr($p, length($h) + 1)) if index($p, "$h/") == 0;
    }
    return util::abbrev($p);
}

# The lines from the settings and the store, not from this session's streams: unsafe roots,
# handoff mode, automatic relaunch (this session's jobs only with its folder d), prod reads,
# protected branches, idle compaction (with this session's idle_mode row when there is one),
# settings, queue mode, kept stashes, former-name options, notes.
# The U-06 pattern warnings read this session's hook rows (classic), so without a session id
# there are none to show.
sub store_lines {
    my ($cwd, $d, $classic, $headless, $sid, $mod) = @_;
    my @out;
    push @out, root_lines();
    push @out, legacy_lines();
    push @out, mode_lines($cwd);
    push @out, relaunch_lines($d);
    push @out, restart_lines($sid, $mod || []);
    push @out, prod_lines();
    push @out, protected_lines();
    push @out, regex_lines($classic);
    push @out, idle_lines($headless, $mod), keep_warm_lines($headless, $sid, $mod), settings_keys_line(), values_lines();
    # Q-ADAPTER QA-1: the queue adapter mode (no queue call: the setting, the file and this
    # session's last list outcome); /status is the only place that says `queue: off`. Without a
    # session id that outcome is not read, so `on` says so (CW-1 review 2)
    my $q = queue::mode_text();
    $q .= " (this session's queue state unknown: no session id)" if $q eq 'on' && !defined $d;
    push @out, 'queue: ' . $q;
    push @out, kept_lines();
    push @out, former_name_lines();
    push @out, map { "note: " . util::text($_) } @{ rc::settings()->{notes} || [] };
    return @out;
}

# STATE-ROOT (0.1.2): while handoff_root is the default, the old default ~/.claude/handoffs is read,
# never written, and never moved (D-8; `migrate --apply` copies it on request); one line says so, with
# its bucket count, or that the unsafe-root checks skipped it. The same for disposable_root and the old
# ~/.claude/trash-staging, with its dated folders. No line when there is no such folder.
sub legacy_lines {
    my @out;
    my $l = rc::legacy();
    if (defined $l) {
        my $n = 0;
        for my $repo (grep { !/^\./ && -d "$l/$_" } util::list_dir($l)) {
            $n += scalar grep { !/^\./ && -d "$l/$repo/$_" } util::list_dir("$l/$repo");
        }
        push @out, 'legacy handoff root ' . util::abbrev($l) . ": read-only, $n bucket" . ($n == 1 ? '' : 's');
    } elsif (defined rc::legacy_path() && defined rc::legacy_refused()) {
        push @out, 'legacy handoff root ' . util::abbrev(rc::legacy_path()) . ': skipped (' . util::text(rc::legacy_refused()) . ')';
    }
    my $d = rc::disposable_legacy();
    if (defined $d) {
        my $n = scalar grep { !/^\./ && -d "$d/$_" } util::list_dir($d);
        push @out, 'legacy disposable root ' . util::abbrev($d) . ": read-only, $n folder" . ($n == 1 ? '' : 's');
    } elsif (defined rc::disposable_legacy_path() && defined rc::disposable_legacy_refused()) {
        push @out, 'legacy disposable root ' . util::abbrev(rc::disposable_legacy_path()) . ': skipped ('
                   . util::text(rc::disposable_legacy_refused()) . ')';
    }
    push @out, '  migrate (user-run, above) lists what it would copy into the new folders; --apply copies; nothing is deleted' if @out && grep { /read-only/ } @out;
    return @out;
}

# 0.1.3: the watcher's one-line verdict opens the output (lib/watch/status.pm verdict): this
# session's saved copies and open alerts, or the store's over 7 days without a sid; none while
# the watcher is off.
sub verdict_lines {
    my ($sid) = @_;
    my $v = eval { require "watch.pm"; watch::verdict_line($sid) };
    return (defined $v && !ref $v) ? ($v) : ();
}

# watcher lines (WP-watch): this session's alerts only with a sid, then the store-wide counts.
# The seam returns [line] (lib/watch.pm); a plain list is taken too.
sub watch_lines {
    my ($sid) = @_;
    my @wl = eval { require "watch.pm"; watch::status_lines($sid) };
    @wl = map { ref $_ eq 'ARRAY' ? @$_ : $_ } @wl;
    return grep { defined && !ref } @wl;
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
        my @jobs = defined $d ? grep { ($_->{ev} // '') eq 'job' } @{ jobrec::read_rows(jobrec::jobs_path($d)) } : ();
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
    for my $p (defined $d ? @{ jobrec::unmatched($d) } : ()) {
        push @l, '  relaunch unmatched: ' . ($p->{task_id} // '-') . ' (no recorded job ran the bumped command)';
    }
    return @l;
}

# ---------------------------------------------------------------- restart on update
# SESSION-RESTART §6.1: read only; `claude --version` (5 s) only while the setting is on.
my %RESTART_LAST = (
    'background-work' => 'background tasks would be lost', crons => 'session crons would be lost', draft => 'a draft in the prompt box',
    present => 'someone at the prompt', remote => 'a remote client', attached => 'a client attached', 'session-rules' => 'rules set for this session',
    'session-dirs' => 'folders added in this session', worktree => 'in a worktree',
    'no-launcher' => 'not started through the launcher', 'fg-not-shipped' => 'terminal restarts not enabled in this version yet',
    'bg-not-shipped' => 'background restarts not enabled in this version yet',
    'on-hold' => 'that release is on hold', 'bypass-left' => 'a permission bypass would come back',
    'restriction-lost' => 'a restriction it was started with would be lost (a launch flag a restart does not apply again)',
    'keepset-unverified' => 'a restriction it was started with may be lost (what a restart keeps is not checked for that version yet)',
    'mode-unknown' => 'the permission mode to restart in is not known',
);
# The launcher's refusal reasons (its file contract §5), for the `launcher did not restart` line.
my %LAUNCHER_REASON = (
    'exit-code' => 'Claude Code did not exit cleanly', pattern => 'the note was not valid', proto => 'another note version',
    token => 'the note was for another launch', age => 'the note was too old', window => 'the exit came too late',
    'other-session' => 'the launch was bound to another session', bypass => 'bypass was not allowed at launch',
    'mode-changed' => 'the permission mode changed', 'launch-file' => 'a file it was started with is gone',
    cap => '3 restarts in the last hour', 'no-terminal' => 'no terminal to start it in',
    consume => 'the note could not be taken', cancelled => 'stopped with Ctrl+C',
    'start-failed' => 'the new version did not start',
);
sub _hm { my ($ms) = @_; return defined $ms && $ms =~ /\A[0-9]+\z/ ? util::hhmm(int($ms / 1000)) : '--:--' }
sub restart_lines {
    my ($sid, $mod) = @_;
    my @l;
    my $brand = ctx::brand();
    my $set = rc::val('restart_on_update') // 'off';
    my $src = rc::settings()->{source}{restart_on_update} // 'default';
    my $os = restart::os_name();
    my $route_off = 0;
    if ($os ne 'darwin' && $os ne 'linux') {
        push @l, 'restart on update: not available on Windows yet';
    } elsif ($set eq 'off') {
        push @l, 'restart on update: off' . ($src eq 'default' ? ' (default) · set restart_on_update in ~/.claude/settings.json to turn it on' : '');
    } elsif ($set eq 'shadow') {
        push @l, 'restart on update: shadow (logs would-restart, restarts nothing)';
    } else {
        my $route;
        if (($ENV{CLAUDE_CODE_SESSION_KIND} // '') eq 'bg') {
            # Before the background route ships (restriction gate, RS-P5) no `→ restarts` clause follows.
            $route_off = restart::bg_route() ? 0 : 1;
            $route = 'background session (claude respawn)'
                     . ($route_off ? ' · background restarts are not enabled in this version yet' : '');
        } else {
            my $launch = $ENV{ restart::launch_env_name() };
            my $lr = (defined $launch && $launch ne '' && defined $sid) ? restart::launcher($launch, $sid) : undef;
            if ($lr && $lr->{ok}) {
                # Until the owner ships it the route is off (fg-not-shipped): no `→ restarts` clause.
                $route_off = restart::fg_route() ? 0 : 1;
                $route = "launcher $brand-claude (proto $restart::PROTO, pid $lr->{pid})"
                         . ($route_off ? ' · terminal restarts are not enabled in this version yet' : '');
            } else {
                my $path = util::text(ctx::root()) . "/scripts/$brand-claude";
                push @l, 'restart on update: on · this session was not started through the launcher; foreground sessions need it:',
                         qq(  install: "$path" --install), "  then start sessions with: $brand-claude [your claude arguments]";
            }
        }
        push @l, "restart on update: on · $route · " . _drift_text($route_off) if defined $route;
    }
    my ($last) = reverse grep { ($_->{ev} // '') =~ /\Arefresh_(done|skipped|failed|would|start)\z/ } @$mod;
    if ($last) {
        my $t = util::hhmm(util::parse_iso($last->{ts} // '') // util::now());
        my ($ev, $why) = ($last->{ev}, $last->{why} // 'other');
        my $ft = join(' → ', grep { defined } $last->{from}, $last->{to});
        if ($ev eq 'refresh_done') { push @l, "  last: restarted $ft at $t (same session)" }
        elsif ($ev eq 'refresh_would') {
            my @it = ref $last->{items} eq 'ARRAY' ? @{ $last->{items} } : ();
            push @l, "  last: would restart $ft ($t)" . (@it ? '; running then: ' . join(', ', @it) : '');
        }
        elsif ($ev eq 'refresh_start') { push @l, "  last: restarting on $last->{to} ($t)" }
        elsif ($ev eq 'refresh_skipped') {
            my $w = $RESTART_LAST{$why} // $why;
            $w .= ' (' . join(', ', @{ $last->{types} }) . ')' if ref $last->{types} eq 'ARRAY' && @{ $last->{types} };
            push @l, "  last: waiting, $w (as of $t)";
        } else {
            my $retry = (grep { $_ eq $why } qw(exit-not-run exit-refused respawn-refused not-respawned)) ? '; one more try at the next compaction' : '';
            push @l, "  last: failed, $why ($t)$retry";
        }
    }
    my $now = restart::now_ms();
    for my $f (restart::failed_bg(rc::watch(), $now, 1)) {
        push @l, "  restart of background session $f->{short} failed ($f->{code}, " . _hm($f->{at}) . "). Start it again with: claude respawn $f->{short}   or look at it with: claude attach $f->{short}";
    }
    for my $r (restart::refusals()) {
        next unless defined $r->{sid} && $now - $r->{at} * 1000 < $restart::REPORT_MS;
        my $why = $LAUNCHER_REASON{ $r->{reason} };
        push @l, '  launcher did not restart session ' . substr($r->{sid}, 0, 8) . " ($r->{reason}" . (defined $why ? ": $why" : '')
                 . ', ' . util::hhmm($r->{at}) . "). Resume with: claude --resume $r->{sid}";
    }
    return @l;
}

# _drift_text(off) -> `Claude Code X running, Y installed → restarts at the next compaction` (with
# off, a route not enabled yet: no arrow clause), or `up to date (X)`, or `installed version
# unknown`.
sub _drift_text {
    my ($off) = @_;
    my $run = rc::exec_version() // rc::cc_version();
    my $bin = restart::claude_bin();
    my $r = defined $bin ? util::run([$bin, '--version'], timeout_ms => 5000) : { exit => -1, out => '' };
    my ($inst) = ($r->{exit} == 0 ? $r->{out} : '') =~ /\A\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\s|\z)/;
    return 'installed version unknown' unless defined $inst && restart::is_ver($run // '');
    return "up to date ($run)" unless restart::vcmp($inst, $run) > 0;
    return "Claude Code $run running, $inst installed" . ($off ? '' : ' → restarts at the next compaction');
}

# ---------------------------------------------------------------- watcher (W-BETA A)
# The first line: the watcher state, the size of its logs and the number of sessions; with
# `off` what stays written. The first-run notice line while its marker is missing (the mod
# claims it at session.start; a session where the mod never ran shows it here).
# 0.1.3 version skew: this session's plugin copy (its version and folder), then the notice when
# sessions started since run another version or (0.1.4 V-1) an install replaced this copy
# (lib/plugver.pm); also without a session id.
sub plugin_lines {
    my @l = ('plugin: ' . ctx::version() . ' · ' . util::abbrev(ctx::root()));
    my $n = plugver::line();
    push @l, "plugin notice: $n" if defined $n;
    return @l;
}

sub watcher_lines {
    my $w = settings::trim(lc(rc::val('watcher') // 'shadow'));
    my $brand = ctx::brand();
    return ('watcher: off · existing logs kept (nothing deleted) · core files still written: copies check, '
            . 'background list, heal counters, rollups, liveness') if $w eq 'off';
    my ($bytes, $sids) = _watch_size(rc::watch());
    my @l = ("watcher: shadow · logs " . _size($bytes) . " in $sids sessions · share: /$brand:report · off: watcher = false in /config");
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
    my $ht = settings::trim(lc(rc::val('handoff_turn') // 'halt'));
    my $h = settings::whole('handoff_turn_max_tokens', rc::val('handoff_turn_max_tokens') // 64000);
    $h = $c->{handoff_tokens_min} if $h < $c->{handoff_tokens_min};
    $h = $c->{handoff_tokens_max} if $h > $c->{handoff_tokens_max};
    my $reserve = $ht eq 'off' ? $c->{reserve_no_handoff} : $c->{reserve_base} + $h;
    my $a = $need + $c->{native_offset} + $reserve;
    my $b = _ceil($need / $c->{soft_ratio} - 1e-9);
    return $a > $b ? $a : $b;
}

# 2026-10-27 (headless probe): the load is headless when the mod's last `headless` row comes
# after this session's last `session` start row: Claude Code runs it headless (`claude -p`, the
# Agent SDK, or an app or editor built on it) and rejects a plugin's compaction call there, so
# the mod gives no nudge. A later interactive load of the same session (its own start row) ends
# it. Returns '' (not headless), `command` (the mod compacts by running `/compact`, the row's
# `compact: command`) or `none` (that path is off, or a row from before it had the field).
sub is_headless {
    my ($mod) = @_;
    my ($start, $headless, $compact) = (-1, -1, 'none');
    for my $i (0 .. $#$mod) {
        my $ev = $mod->[$i]{ev} // '';
        $start = $i if $ev eq 'session' && ($mod->[$i]{phase} // '') eq 'start';
        next unless $ev eq 'headless';
        $headless = $i;
        $compact = ($mod->[$i]{compact} // '') eq 'command' ? 'command' : 'none';
    }
    return $headless > $start ? $compact : '';
}

# The line for a headless load. Only what was seen live is said: Claude Code rejects the call
# under `claude -p` and the SDK; an app or editor is named as a possible host, not as tested. The
# plugin does not turn Claude Code's own automatic compaction on or off, whatever its setting.
sub headless_lines {
    my ($headless) = @_;
    return () unless $headless;
    return ('automatic compaction: by /compact; Claude Code runs this session headless (claude -p, the Agent SDK, '
            . "or an app or editor built on it), where it rejects a plugin's compaction call, so the plugin runs /compact "
            . 'at a turn end at or above the target and shapes it as usual, with no nudge, handoff turn or continue; '
            . "Claude Code's own automatic compaction is not affected") if $headless eq 'command';
    return ('automatic compaction: not available here; Claude Code runs this session headless (claude -p, the Agent SDK, '
            . "or an app or editor built on it), where it rejects a plugin's compaction call and its /compact did not "
            . "work for the plugin, so the plugin does not nudge or start compactions; Claude Code's own automatic "
            . 'compaction is not affected');
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

# The commands the user types (with the leading !), with the real plugin folder. Without a
# session id the reconcile line is left out: it works on this session first (CW-1). `migrate` only while an
# old default folder is read (STATE-ROOT).
sub user_run_lines {
    my ($sid) = @_;
    my $store = ctx::store_cmd() // return ();
    $store = util::text($store);
    return ('user-run commands (type them yourself, with the leading !):',
            map { "  ! $store $_" } ('smoke', 'project init', 'project copy', 'watch prune',
                                     (defined $sid ? ("reconcile --sid $sid --orphans --full") : ()), 'report',
                                     'settings reset <key> --apply',
                                     # STATE-ROOT: only while an old default folder is read (a dry run; --apply copies)
                                     (defined rc::legacy() || defined rc::disposable_legacy() ? ('migrate') : ())));
}

# ---------------------------------------------------------------- prod reads (S-SETTINGS B)
my %SRC = (settings => 'settings file', default => 'default', safe => 'safe value');
sub prod_lines {
    my $r = rc::settings();
    my $p = eval { settings::prod($r) } || { reads => 'forbid', user => 0, invalid => [] };
    my $src = $SRC{ $r->{source}{unattended_prod_reads} // 'default' } // 'default';
    my $shipped = scalar(@{ $p->{classes} || [] }) - ($p->{user} // 0);
    # D-72: the setting as /config shows it (false = forbid, true = allow)
    my $reads = settings::switch_form('unattended_prod_reads', $p->{reads}) // 'false';
    my @l = ("unattended_prod_reads: $reads ($src) · production patterns: "
             . ($shipped > 0 ? 'prod-token' : 'none') . ' + ' . ($p->{user} // 0) . ' yours');
    for my $i (@{ $p->{invalid} || [] }) {
        push @l, $i->{key} eq 'prod_patterns' ? "  config: prod_patterns #$i->{index} invalid, dropped"
                                               : "  config: $i->{key} invalid, false used";
    }
    return @l;
}

# ---------------------------------------------------------------- protected branches (owner xxxxxxxx-29)
# The user's add-only protected_branches entries in use beside the shipped list, and one warning
# per ignored (invalid) entry by its position, never its text.
sub protected_lines {
    my $r = rc::settings();
    my $p = eval { settings::protected($r) } || { user => 0, invalid => [] };
    my $src = $SRC{ $r->{source}{protected_branches} // 'default' } // 'default';
    my @l = ('protected branches: the shipped list + ' . ($p->{user} // 0) . " yours ($src)");
    push @l, "  warning: protected_branches #$_->{index} invalid, ignored (the shipped list still applies)" for @{ $p->{invalid} || [] };
    return @l;
}

# ---------------------------------------------------------------- the user's patterns (U-06)
# One warning per pattern of the user's that this session stopped at its time bound
# (lib/userre.pm, `regex_timeout` rows), by key and position, never the pattern, with what the
# plugin did instead.
my %REGEX_SAFE = (secret_extra_rules => 'counted as a hit of its kind on what it checked', prod_patterns => 'counted as production',
                  protected_branches => 'counted as protected', ticket_pattern => 'no ticket used',
                  relaunch_allow => 'not allowlisted (asks)', deny_class_patterns => 'not used for the class');
my %REGEX_WHY = (timeout => 'stopped after its time limit', load => 'stopped while the machine was busy',
                 budget => 'not run (the time for your patterns was used up)', error => 'could not run');
my %REGEX_RANK = (timeout => 4, budget => 3, load => 2, error => 1);
sub regex_lines {
    my ($rows) = @_;
    my (%why, @order);
    for my $r (grep { ($_->{ev} // '') eq 'regex_timeout' } @{ $rows || [] }) {
        my ($k, $i, $w) = ($r->{key} // '', $r->{index} // '', $r->{why} // '');
        next unless $REGEX_SAFE{$k} && $i =~ /\A[0-9]{1,3}\z/;
        push @order, "$k.$i" unless exists $why{"$k.$i"};
        # one line per pattern: its most telling row (a slow pattern over a busy machine)
        $why{"$k.$i"} = $w if !defined $why{"$k.$i"} || ($REGEX_RANK{$w} // 0) > ($REGEX_RANK{ $why{"$k.$i"} } // 0);
    }
    my @l;
    for my $ki (@order) {
        my ($k, $i) = $ki =~ /\A(.+)\.([0-9]+)\z/;
        my $w = $why{$ki};
        push @l, "warning: $k #$i " . ($REGEX_WHY{$w} // 'stopped') . "; $REGEX_SAFE{$k}" . ($w eq 'timeout' ? ' (make the pattern simpler)' : '');
    }
    return @l;
}

# ---------------------------------------------------------------- idle compaction (IA-4, IDLE-COMPACT §4.1 B) and SK-7
# Who compacts an idle session (IDLE-COMPACT-SPEC §4.1, lane B): Claude Code, the plugin or
# nobody, and the pre-idle handoff turn. The source is this session's last `idle_mode` row (the
# mod's own merged reading: `native` vetoed / compaction-off / on / unknown, `plugin_turn`,
# `plugin_compact`, `compact_min`, `cache_s`), which the mod writes at load and whenever the policy
# changes for the session id (a `/clear` gets its own). With no such row (no load or turn end of
# this session yet, no session id, or a row from before the plugin's own idle compaction), the
# line is read the same way from the user settings file and the helper's environment
# (`autoCompactEnabled` false, DISABLE_COMPACT or DISABLE_AUTO_COMPACT: automatic compaction off;
# `idleCompaction` false alone: Claude Code's own idle compaction off; a file that is not JSON:
# unknown; O-9 "unreadable means check what happened"), and says so. While Claude Code's own idle
# compaction is on (or unknown) a neutral note says it runs in sessions without the plugin too, and
# how to keep it to the plugin's; when the user file says `"idleCompaction": false` but the
# session reads it on, another note says a project, local, --settings or managed value turned it
# back on. The test seam (STORE_TEST_IDLE_CACHE_S) gets a line while it is set.
sub _json_false { my ($v) = @_; return jsonc::is_bool($v) && !$$v ? 1 : 0 }
# An environment flag as Claude Code reads one (deps.ts envTruthy).
sub _env_true { my ($v) = @_; return defined $v && $v =~ /\A\s*(?:1|true|yes|on)\s*\z/i ? 1 : 0 }
# CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS as native reads it (deps.ts compactMinOf): a positive integer
# gives max(100,000, v), anything else 200,000.
sub _compact_min {
    my $v = $ENV{CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS} // '';
    $v =~ s/\A\s+|\s+\z//g;
    return 200000 unless $v =~ /\A[0-9]{1,15}\z/ && $v > 0;
    return $v < 100000 ? 100000 : $v + 0;
}
# STORE_TEST_IDLE_CACHE_S as the mod reads it (deps.ts cacheSOf): an integer from 120 to 3600, else none.
sub _cache_s {
    my $v = $ENV{STORE_TEST_IDLE_CACHE_S} // '';
    $v =~ s/\A\s+|\s+\z//g;
    return undef unless $v =~ /\A[0-9]{1,6}\z/;
    return $v >= 120 && $v <= 3600 ? $v + 0 : undef;
}
sub _thousands { my ($n) = @_; 1 while $n =~ s/\A(\d+)(\d{3})/$1,$2/; return $n }
# Claude Code's own idle compaction as the user settings file and the helper's environment say:
# (native, the file says "idleCompaction": false).
sub _user_native {
    my $file = settings::config_dir() . '/settings.json';
    my ($native, $vetoed) = ('on', 0);
    if (-e util::to_bytes($file)) {
        my $raw = util::read_file($file);
        my $j = defined $raw ? eval { jsonc::decode($raw) } : undef;
        if (ref $j ne 'HASH') { $native = 'unknown' }
        else {
            $vetoed = _json_false($j->{idleCompaction});
            if (_json_false($j->{autoCompactEnabled})) { $native = 'compaction-off' }
            elsif ($vetoed) { $native = 'vetoed' }
        }
    }
    $native = 'compaction-off' if _env_true($ENV{DISABLE_COMPACT}) || _env_true($ENV{DISABLE_AUTO_COMPACT});
    return ($native, $vetoed);
}
my $OWN_ON = "Claude Code's own (your settings allow it; Claude Code decides per account whether it runs)";
my $OWN_OFF = 'Claude Code\'s own is off: "idleCompaction": false';
my $FAILED = "the plugin's failed twice in this session; it is back once the plugin reloads";
# The line for one policy (native, plugin_turn, plugin_compact), as the §4.1 B table words it.
sub idle_line {
    my ($native, $pt, $pc, $min, $headless, $compact_opt) = @_;
    my $m = _thousands($min // _compact_min());
    my $p = 'idle compaction: ';
    my $turn49 = 'the pre-idle handoff turn at 49 min';
    if ($native eq 'vetoed') {
        return $p . "by the plugin, about 54 min after the last request at $m tokens or more ($OWN_OFF); below that, "
               . ($pt eq 'on' ? $turn49 : 'none (idle_handoff_turn: false)') if $pc eq 'on';
        return $p . "none for now ($FAILED) → " . ($pt eq 'on' ? $turn49 : 'no pre-idle handoff turn') if $pc eq 'failed';
        return $p . "none for now (the plugin's /compact waited in the queue and did not start in time; it is back once the plugin reloads)"
               . ' → no pre-idle handoff turn (headless session)' if $pc eq 'queued';
        return $p . "none ($OWN_OFF; the plugin's does not run in a headless session yet); no pre-idle handoff turn (headless session)"
            if $headless;
        return $p . "none ($OWN_OFF; the plugin's: idle_compact: false) → $turn49" if $pt eq 'on';
        return $p . "none ($OWN_OFF; the plugin's: idle_compact: false); no pre-idle handoff turn (idle_handoff_turn: false)";
    }
    if ($native eq 'compaction-off') {
        return $p . 'none (automatic compaction is off: "autoCompactEnabled": false or DISABLE_AUTO_COMPACT)'
               . ($pt eq 'on' ? " → $turn49" : $headless ? '; no pre-idle handoff turn (headless session)'
                  : '; no pre-idle handoff turn (idle_handoff_turn: false)');
    }
    my $who = $native eq 'unknown' ? 'unknown (the settings could not be read)' : $OWN_ON;
    my $check = ' → the plugin checks at 55.5 min and, if Claude Code did not compact, ';
    if ($pt eq 'check') {
        return $p . $who . $check . "compacts itself at $m tokens or more; below that, it runs its handoff turn" if $pc eq 'check';
        # a row of a build before lane B: the compaction while agents run only
        return $p . $who . $check . 'runs its handoff turn, or compacts itself while agents run' if $pc eq 'agents';
        return $p . $who . $check . "runs its handoff turn; it does not compact itself for now ($FAILED)" if $pc eq 'failed';
        return $p . $who . $check . 'runs its handoff turn; it does not compact itself (idle_compact: false)';
    }
    return $p . $who . " → the plugin checks at 55.5 min only to compact itself at $m tokens or more if Claude Code did not"
           . ' (no handoff turn: idle_handoff_turn: false)' if $pc eq 'check';
    my $why = $headless ? 'headless session'
            : $pc eq 'failed' ? "idle_handoff_turn: false; $FAILED"
            : $compact_opt eq 'off' ? 'idle_handoff_turn and idle_compact: false' : 'idle_handoff_turn: false';
    return $p . $who . "; the plugin does not check and does not compact ($why)";
}
sub idle_lines {
    my ($headless, $mod) = @_;
    my $r = rc::settings();
    my $turn_opt = lc($r->{values}{idle_handoff_turn} // 'auto');
    my $compact_opt = lc($r->{values}{idle_compact} // 'auto');
    my ($user_native, $user_vetoed) = _user_native();
    my $row = ref $mod eq 'ARRAY' ? _last($mod, 'idle_mode') : undef;
    # A row without plugin_compact was written before the plugin's own idle compaction.
    undef $row unless ref $row eq 'HASH' && defined $row->{plugin_compact} && defined $row->{native} && defined $row->{plugin_turn};
    my ($native, $pt, $pc, $min, $cache);
    if ($row) {
        ($native, $pt, $pc, $min, $cache) = @$row{qw(native plugin_turn plugin_compact compact_min cache_s)};
    } else {
        # As the mod's policy reads it (idle.ts policy, idleSwitches): a headless load has neither path.
        $native = $user_native;
        my $turn_on = $turn_opt eq 'auto' && !$headless;
        my $compact_on = $compact_opt eq 'auto' && !$headless;
        my $live = $native eq 'on' || $native eq 'unknown';
        $pt = $live ? ($turn_on ? 'check' : 'off') : ($turn_on ? 'on' : 'off');
        $pc = $native eq 'compaction-off' ? 'off' : $compact_on ? ($live ? 'check' : 'on') : 'off';
        ($min, $cache) = (_compact_min(), _cache_s());
    }
    $min = undef unless defined $min && !ref $min && $min =~ /\A[0-9]{1,15}\z/;
    my $line = idle_line($native, $pt, $pc, $min, $headless, $compact_opt);
    $line .= ' (from your user settings; the session decides at its next turn end)' unless $row;
    my @out = ($line);
    if ($native eq 'on' || $native eq 'unknown') {
        my $brand = ctx::brand();
        push @out, "note: Claude Code's own idle compaction also runs in sessions where $brand is not enabled. To keep idle "
                   . "compaction to $brand sessions, set \"idleCompaction\": false in "
                   . util::abbrev(settings::config_dir() . '/settings.json') . "; $brand then compacts idle sessions itself.";
    }
    push @out, 'note: your user settings say "idleCompaction": false, but a project, local, --settings or managed value turns '
               . "Claude Code's own back on in this session." if $row && $native eq 'on' && $user_vetoed;
    push @out, "idle timers: test scale, cache $cache s (STORE_TEST_IDLE_CACHE_S)" if defined $cache && !ref $cache && $cache =~ /\A[0-9]{1,6}\z/;
    return @out;
}

# Keep-warm (D-14, 2026-10-30; the mod's keepwarm.ts): on or off by keep_warm_hours (0 = off), and,
# with a session id, this session's current idle gap from its last keep_warm_start, keep_warm_ping
# and keep_warm_stop rows: warming with the pings that kept the cache warm so far, or not warming
# (with the last warmed gap's pings and its stop reason, or the last gap refused before its first
# ping for want of an idle path: `no-idle-path`, a stop row with no start row; a newer gap with no
# row yet reads as that one did, hence "the last"). A headless session never warms.
sub keep_warm_lines {
    my ($headless, $sid, $mod) = @_;
    my ($h) = eval { settings::num_clamped('keep_warm_hours') };
    $h = 6 unless defined $h;
    return ('keep-warm: off (keep_warm_hours: 0)') unless $h > 0;
    my $on = "keep-warm: on (up to $h h of an idle gap, only while this session's own background jobs run, on the one-hour cache)";
    return ("$on; not in a headless session") if $headless;
    return ($on) unless defined $sid && ref $mod eq 'ARRAY';
    my ($pings, $state, $why) = (0, 'none', undef);
    for my $r (@$mod) {
        my $ev = $r->{ev} // '';
        if ($ev eq 'keep_warm_start') { ($pings, $state, $why) = (0, 'warming', undef) }
        elsif ($ev eq 'keep_warm_ping') { $pings++ if $state eq 'warming' && ($r->{result} // '') eq 'warm' }
        elsif ($ev eq 'keep_warm_stop' && $state eq 'warming') { ($state, $why) = ('stopped', $r->{why}) }
        # A gap no idle path could take over: its one stop row, with no start row before it.
        elsif ($ev eq 'keep_warm_stop' && ($r->{why} // '') eq 'no-idle-path') { ($pings, $state, $why) = (0, 'refused', 'no-idle-path') }
    }
    my $n = $pings == 1 ? '1 ping' : "$pings pings";
    return ("$on · this gap: warming, $n so far") if $state eq 'warming';
    return ("$on · this gap: not warming (the last refused gap: stopped before its first ping: no-idle-path, no idle compaction or handoff turn to take it over)")
        if $state eq 'refused';
    $why = 'other' unless defined $why && !ref $why && $why =~ /\A[a-z0-9-]{1,24}\z/;
    return ("$on · this gap: not warming (the last warmed gap: $n, stopped: $why)") if $state eq 'stopped';
    return ("$on · this gap: not warming");
}

# SK-7 (owner xxxxxxxx-12/-13/-14): the six 2026-10-23 keys as values the user can check, never
# the ticket pattern or a secret rule's text.
sub settings_keys_line {
    my $r = rc::settings();
    my $v = $r->{values} || {};
    my $rp = ($v->{resume_proceed} // '') eq 'confirm' ? 'false' : 'true';
    my $tr = eval { settings::ticket_re($r) } || {};
    my $tk = $tr->{invalid} ? 'invalid (default used)' : $tr->{custom} ? 'custom' : 'default';
    my $sx = eval { settings::secret_extra($r) } || {};
    my $nx = scalar(@{ $sx->{rules} || [] }) + scalar(@{ $sx->{names} || [] });
    my @n = map { my ($x) = eval { settings::num_clamped($_, $r) }; defined $x ? $x : '?' }
            qw(handoff_reuse_window_min evidence_total_max_mb watch_quota_mb);
    return (sprintf('settings: resume_proceed %s (%s) · handoff_reuse_window_min %s · ticket_pattern %s · secret_extra_rules %d · evidence_total_max_mb %s · watch_quota_mb %s',
                    $rp, $r->{source}{resume_proceed} // 'default', $n[0], $tk, $nx, $n[1], $n[2]));
}

# 0.1.2 visible defaults (spec Behaviour 1-2): every effective value, store-wide (also without
# a session id). A key whose value is not its default gets one line with its source and default
# (a value equal to its default counts as at its default wherever it comes from); the keys at
# their defaults share one or two `at default:` lines. Then a warning per saved "" and for an ambiguous options key.
our $AT_DEFAULT_PER_LINE = 22;
sub values_lines {
    my $rows = eval { settings::effective_rows(rc::settings()) } || [];
    return () unless @$rows;
    my @set = grep { !$_->{at_default} } @$rows;
    my @def = grep { $_->{at_default} } @$rows;
    my @l = (sprintf('settings values: %d not at default, %d at default', scalar @set, scalar @def));
    push @l, "  $_->{key} " . settings::row_text($_) for @set;
    my $per = @def > $AT_DEFAULT_PER_LINE ? int((@def + 1) / 2) : scalar @def;
    while (my @part = splice(@def, 0, $per || 1)) { push @l, '  at default: ' . join(' · ', map { "$_->{key}=$_->{value}" } @part) }
    push @l, settings::value_warnings($rows, ctx::store_cmd());
    return @l;
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
