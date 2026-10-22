# cmd/status.pl: `status --sid S` (MOD-SPEC §11; BUILD-PLAN §3.1). Owner: WP-core
# (+ watch.status_lines). Lines: effective thresholds (clamped marked), last 5
# compactions (seat_state, trigger, verdict, copy path), open escalations, halt
# state and continues this hour, smokeDue with the user-run smoke line, policy
# flags, unsafe roots, the handoff-root mode (MOD-SPEC §11 Block C, D-12), automatic
# relaunch (Dev-1, DP-2), settings notes, then the watcher's open alerts. Never content.
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

    # thresholds
    my $eff = _last($mod, 'config_effective');
    if ($eff) {
        my %cl;
        for my $r (grep { ($_->{ev} // '') eq 'config_clamped' } @$mod) { $cl{ $r->{key} } = $r->{configured} if defined $r->{key} }
        my @parts;
        for my $k (qw(target soft_max window native_trigger)) {
            next unless defined $eff->{$k};
            my $v = $eff->{$k};
            $v .= " (clamped from $cl{$k})" if exists $cl{$k};
            push @parts, "$k $v";
        }
        my $state = $eff->{disabled} ? " · plugin compactions off ($eff->{disabled})" : '';
        push @out, 'thresholds: ' . join(' · ', @parts) . $state;
    } else {
        push @out, sprintf('thresholds: no mod row yet (settings: target %s · soft max %s)',
                           rc::val('compact_target_tokens'), rc::val('compact_soft_max_tokens'));
    }
    push @out, 'triggers: off (triggers-off)' if grep { ($_->{ev} // '') eq 'triggers_off' } @$mod;

    # last 5 compactions
    my $rolls = _bytes_deep(rollup::rows($d));
    my @last = @$rolls > 5 ? @$rolls[-5 .. -1] : @$rolls;
    my $nonok = grep { defined $_->{verdict} && $_->{verdict} !~ /^ok(-trailer)?$/ } @last;
    push @out, sprintf('compactions: %d in this session; last %d (%d not ok):', scalar @$rolls, scalar @last, $nonok);
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
my %RELAUNCH_STATE = (on => 'active for read-only jobs', shadow => 'shadow (reports would-relaunch, runs nothing)', off => 'off');
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
    push @l, '  relaunch_allow: ' . scalar(@{ $rl->{allow} }) . ' patterns, no effect in this version (read-only jobs only)'
        if @{ $rl->{allow} };
    push @l, "  config: $_->{key} invalid, " . ($_->{key} eq 'relaunch_auto' ? 'off used' : 'pattern dropped') for @{ $rl->{invalid} };
    push @l, "  config: $_->{key} $_->{configured} clamped to $_->{used}" for @{ $rl->{clamped} };
    for my $p (@{ jobrec::unmatched($d) }) {
        push @l, '  relaunch unmatched: ' . ($p->{task_id} // '-') . ' (no recorded job ran the bumped command)';
    }
    return @l;
}

exit(args::main(\&run, @ARGV));
