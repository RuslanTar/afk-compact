# cmd/hook.pl: `hook <Event>`, the classic command-hook entry (MOD-SPEC §1.3, §3.2, §3.4,
# §5.3, §5.4, §7; BUILD-PLAN §3.3). Owner: WP-core (+ watch.on_hook / watch.on_stop).
# Always exits 0. Prints nothing, or exactly the event's documented output: PreCompact
# the fallback text, SessionStart(compact) one hookSpecificOutput JSON line. An internal
# error writes one `watch_error {stage, error_class}` row and prints nothing.
use strict;
use warnings;
use utf8;

package cmd_hook;

# how core calls the watcher, shared with the `reconcile` CLI (lib/watchcall.pm)
require watchcall;

our %EVENTS = map { $_ => 1 } qw(PreCompact PostCompact SessionStart SessionEnd Stop SubagentStop StopFailure PermissionDenied);
our %KEYSET_EVENTS = map { $_ => 1 } qw(PreCompact PostCompact SessionStart);
# One writer per row kind (ROOT-RULINGS F2-5): core writes stop_failure and
# permission_denied with their computed classes; the watcher reads those rows from the
# stream and is not called for these events, so it cannot write a second row.
our %CORE_ROWS_ONLY = map { $_ => 1 } qw(StopFailure PermissionDenied);
# the classic stream tail _turn_kind read (copy rows for the pending-record check)
our $LAST_CLASSIC;

sub _error_class { return watchcall::error_class(@_) }

sub _watch_ctx { return watchcall::ctx(@_) }

# Run a watcher seam with stdout closed off (nothing it does may reach stdout).
sub _watch_call { return watchcall::call(@_) }

# Stop (8 s hook timeout): one budget for the whole process, counted from the helper's start
# (main.pl, before its libraries compile), on the real clock (STORE_TEST_NOW fixes the clock,
# never a budget). 0.1.3 hook speed: well under half the timeout, so a host slowed by load still
# ends the hook itself: the turn's records first, then reconcile (keeping room for the watcher),
# the cross-session finish pass, the GSD scan cache, and the watcher with what is left (its
# sweep keeps no offset it did not finish: the next Stop reads on). The reserve is for writing
# the rows and exiting.
our $STOP_BUDGET_MS = 3500;
our $STOP_RESERVE_MS = 300;
our $RECONCILE_MS = 2000;
our $WATCH_MIN_MS = 1000;
our $WATCH_HARD_S = 3;
our $GSD_WARM_LAG = 1 << 20;
our $GSD_WARM_MS = 300;
our $GSD_WARM_MIN_MS = 50;
our $T_START;
# What this Stop's phases took and what the budget cut, for its `stop_timing` row.
our %STOP;

# SessionStart (5 s hook timeout): the compact block is measured within this budget from
# hook start, so it is printed and claimed before the hook is killed.
our $SESSION_COMPACT_MS = 3500;
# SessionEnd (5 s hook timeout): after its final reconcile and the finish pass, the watcher's end
# pass (lib/watch/rules.pm a01_end) takes at most END_WATCH_MS and ends by END_BY_MS from the
# helper's start (at least 100 ms).
our $END_WATCH_MS = 1000;
our $END_BY_MS = 4200;
our $T0;

# U-06 (lib/userre.pm): [seconds one of the user's own patterns may run, seconds this hook may
# spend in all their children, the most that budget grows to for large texts], the budget at
# most a fifth of the event's hook timeout (hooks.json: PreCompact 5, PostCompact 15,
# SessionStart 5, SessionEnd 5, Stop 8, SubagentStop 3, StopFailure 2, PermissionDenied 2). The
# two that scan evidence files (PostCompact's sweep, Stop's reconcile) get room for a large one.
our %REGEX_S = (PreCompact => [0.5, 1], PostCompact => [1, 2, 6], SessionStart => [0.5, 1], SessionEnd => [0.5, 1],
                Stop => [1, 1.5, 3], SubagentStop => [0.3, 0.6], StopFailure => [0.25, 0.4], PermissionDenied => [0.25, 0.4]);

# The helper's start: main.pl's mark when it is not in the future, else now. Test seam
# (STORE_TEST_MODE only): STORE_TEST_HOOK_START_AGO_MS moves main.pl's mark back, as a host
# slowed by load would have spent that long starting (without the mark it moves nothing).
sub _start_ms {
    my $now = util::clock_ms();
    return $now unless defined $main::T_START_MS && $main::T_START_MS =~ /\A\d+\z/ && $main::T_START_MS <= $now;
    my $s = $main::T_START_MS;
    my $ago = util::test_mode() ? ($ENV{STORE_TEST_HOOK_START_AGO_MS} // '') : '';
    $s -= $ago if $ago =~ /\A[0-9]{1,6}\z/;
    return $s;
}

# The Stop budget in ms. Test seam (STORE_TEST_MODE only): STORE_TEST_STOP_BUDGET_MS widens it,
# never narrows it, for a case whose subject is a phase's own work, not the budget (HS-03: the
# GSD catch-up, which a loaded host would otherwise leave no time).
sub _stop_budget {
    my $w = util::test_mode() ? ($ENV{STORE_TEST_STOP_BUDGET_MS} // '') : '';
    return ($w =~ /\A[0-9]{1,6}\z/ && $w > $STOP_BUDGET_MS) ? 0 + $w : $STOP_BUDGET_MS;
}

# _stop_left(cap, keep) -> ms of the Stop budget still free after the reserve and `keep` ms
# held for what follows, at most `cap`, never below 0.
sub _stop_left {
    my ($cap, $keep) = @_;
    my $l = _stop_budget() - $STOP_RESERVE_MS - ($keep // 0) - (util::clock_ms() - ($T_START // util::clock_ms()));
    $l = $cap if defined $cap && $l > $cap;
    return $l < 0 ? 0 : int $l;
}

# The cross-session finish of an ended session (lib/orphans.pm, called in that session's context
# after its final reconcile, with what is left of the pass): the watcher's end pass for it, as its
# own SessionEnd would have run it (its held A-01s; lib/watch/rules.pm a01_end). The `reconcile`
# CLI's finish pass runs the same one (lib/watchcall.pm finished).
sub _finished_watch { local $watchcall::END_WATCH_MS = $END_WATCH_MS; return watchcall::finished(@_) }

sub run {
    my ($event) = @_;
    $T_START = _start_ms();
    %STOP = ();
    my $t0 = $T0 = util::clock_ms();
    my $raw = do { local $/; <STDIN> };
    return 0 unless defined $event && $EVENTS{$event};
    userre::limits(@{ $REGEX_S{$event} });
    my $p = defined $raw && $raw =~ /\S/ ? eval { jsonc::decode($raw) } : undef;
    my $sid = ref $p eq 'HASH' ? $p->{session_id} : undef;
    if (ref $p ne 'HASH' || !args::valid_sid($sid)) {
        eval {
            rc::init(sid => 'unknown', writer => 'classic');
            rc::emit('watch_error', [stage => "hook.$event", error_class => 'payload']);
        };
        return 0;
    }
    # root checks (git check-ignore) share one short budget: PreCompact's fallback makes no
    # git call of its own and must print well inside its 5 s timeout
    local $roots::DEADLINE = $t0 + ($event eq 'PreCompact' ? 500 : 1500);
    rc::init(sid => $sid, writer => 'classic');
    rc::note_transcript($p->{transcript_path});
    my $out = '';
    my $extra = {};
    my $ok = eval {
        rc::preamble();
        keyset::check($event, $p) if $KEYSET_EVENTS{$event};
        my $h = __PACKAGE__->can('on_' . $event);
        ($out, $extra) = $h->($p);
        1;
    };
    if (!$ok) {
        my $e = $@;
        $out = '';
        eval { rc::emit('watch_error', [stage => "hook.$event", error_class => _error_class($e)]) };
    }
    if ($event eq 'Stop') {
        # Relative seconds (watch.on_stop reads a small value as "from now" on its own clock):
        # at most the 3 s hard stop of WATCH W9, less when the start or reconcile used the budget.
        my $left = _stop_left($WATCH_HARD_S * 1000, 0) / 1000;
        $left = 0.2 if $left < 0.2;
        util::trace(sprintf('stop-watch-window %d', $left * 1000));
        my $w0 = util::clock_ms();
        # the stashes reconcile left for the next Stop (their A-01 waits with them, lib/watch/rules.pm)
        my $waits = ref $extra eq 'HASH' && ref $extra->{reconcile} eq 'HASH' ? $extra->{reconcile}{waits} : undef;
        # 0.1.4: reconcile could not take the session lock (another reconciler held it): no waits
        my $busy = ref $extra eq 'HASH' && ref $extra->{reconcile} eq 'HASH' && $extra->{reconcile}{busy} ? 1 : 0;
        _watch_call('watch.on_stop', sub { watch::on_stop(_watch_ctx($event, { payload => $p, copy_waits => $waits || {}, reconcile_busy => $busy }), $left) });
        eval { _stop_row($t0, $w0, $left) };
    } elsif ($event eq 'SessionEnd') {
        my $l = $END_BY_MS - (util::clock_ms() - $T_START);
        $l = $END_WATCH_MS if $l > $END_WATCH_MS;
        $l = 100 if $l < 100;
        _watch_call('watch.on_hook', sub { watch::on_hook($event, $p, _watch_ctx($event, $extra), $l / 1000) });
    } elsif (!$CORE_ROWS_ONLY{$event}) {
        _watch_call('watch.on_hook', sub { watch::on_hook($event, $p, _watch_ctx($event, $extra)) });
    }
    if (defined $out && length $out) {
        utf8::encode($out) if utf8::is_utf8($out);
        print STDOUT $out;
    }
    return 0;
}

# ------------------------------------------------------------------ PreCompact (MOD-SPEC §3.2)
sub on_PreCompact {
    my ($p) = @_;
    my $sid = rc::sid();
    my $ci = $p->{custom_instructions};
    my $trigger = (defined $p->{trigger} && $p->{trigger} =~ /^(manual|auto)$/) ? $p->{trigger} : 'unknown';
    my $d = detect::instructions((defined $ci && !ref $ci) ? $ci : undef, $sid);
    if ($d->{found} && $d->{has_record}) {
        rc::emit('precompact_shaped', [nonce => $d->{nonce}, trigger => $trigger]);
        return ('', { instructions => $d });
    }
    rc::emit('precompact_marker_orphan', [nonce => $d->{nonce}, trigger => $trigger]) if $d->{found};
    # Fallback: nonce, dispatch record, assembly and print only (no checkpoint, sweep,
    # git, GSD or queue call; S-04).
    my $nonce = nonce::draw($sid);
    my $prev = rc::root_ok('handoff_root') ? copies::prev_copy($sid, undef) : undef;
    my $prev_abbrev = defined $prev ? util::abbrev($prev) : undef;
    my $qc = rc::val('queue_cmd');
    my $queue = (defined $qc && !ref $qc && $qc ne '') ? 1 : 0;
    my $text = assemble::classic_fallback(nonce => $nonce, auto => ($trigger eq 'auto'), previous_copy => $prev_abbrev, queue => $queue);
    my @tags = (($trigger eq 'auto' ? ('auto') : ()), (defined $prev ? ('chain') : ()), ($queue ? ('queue') : ()));
    my $bytes = do { my $c = $text; utf8::encode($c); length $c };
    if (defined(my $w = rc::watch())) {
        # A record that cannot be written (an unwritable root or watch dir) must not cost
        # the shaping: the fallback text is still printed (MOD-SPEC §3.2).
        my $ok = eval {
            my $c = rc::claude();
            my $rec = dispatch::record(nonce => $nonce, session_id => $sid, actor => 'unknown', trigger => $trigger,
                                       channel => 'classic', resume_pref => 'sessionstart', midturn => 0, tags => \@tags,
                                       instructions_sha8 => substr(sha::hex256($text), 0, 8), instructions_bytes => $bytes,
                                       cc_version => rc::cc_version(), cc_version_src => rc::cc_version_src(), load_id => undef, pid => $c->{pid}, pid_lstart => $c->{lstart});
            dispatch::write($w, $sid, $rec);
            rc::emit('dispatch', [nonce => $nonce, trigger => $trigger, agent_id => undef, compaction_seq => undef, channel => 'classic',
                                  resume_pref => 'sessionstart', midturn => jsonc::false(), tags => \@tags, instructions_bytes => $bytes]);
            1;
        };
        rc::emit('watch_error', [stage => 'hook.PreCompact.dispatch', error_class => _error_class($@)]) unless $ok;
    }
    rc::emit('precompact_fallback', [nonce => $nonce, trigger => $trigger, bytes => $bytes, chain => jsonc::bool(defined $prev),
                                     orphan => jsonc::bool($d->{found})]);
    return ($text, { instructions => $d, fallback_nonce => $nonce });
}

# ------------------------------------------------------------------ PostCompact (MOD-SPEC §5.3)
sub on_PostCompact {
    my ($p) = @_;
    # SESSION-RESTART D10: the fresh permission mode of this compaction, with its time
    eval { restart::note_post(rc::sid_dir(), $p) };
    my $r = postcompact::run($p);
    return ('', { detect => $r });
}

# ------------------------------------------------------------------ SessionStart (MOD-SPEC §3.4, §5.6 C1h, §7)
sub on_SessionStart {
    my ($p) = @_;
    my $sid = rc::sid();
    my $src = (defined $p->{source} && $p->{source} =~ /^(startup|resume|clear|compact|fork)$/) ? $p->{source} : 'other';
    # P5-FOLD A7: the scratchpad path goes to the private sidecar only, never into a row
    my $sp = (defined $p->{scratchpad_dir} && !ref $p->{scratchpad_dir} && $p->{scratchpad_dir} =~ m{^/}) ? $p->{scratchpad_dir} : undef;
    my $spd = rc::sid_dir();
    eval { sidecar::note_scratchpad($spd, $sp, $src) } if defined $spd && defined $sp;
    # 0.1.3 version skew (lib/plugver.pm): this process's first start under this plugin copy
    eval { plugver::note_load($sid, $src, $p->{cwd}) };
    # 0.1.7 (D-81): the cache state's transcript, the session live again after a resume, and the
    # stable launcher shim for status lines (lib/cachestate.pm)
    if (!defined $p->{agent_id}) {
        eval { cachestate::on_start($sid, $p->{transcript_path}) };
        eval { util::trace('cache-shim ' . cachestate::keep_shim()) } if $src ne 'compact';
    }
    return session_compact($p) if $src eq 'compact';
    my $c = rc::claude();
    my ($lin, $where);
    if (rc::root_ok('handoff_root')) {
        $where = git::where($p->{cwd});
        eval { sessions::write_live($sid, $p->{cwd}, $where->{toplevel}, $src, $where->{head}) };
        # This session's records of earlier processes that ended with no SessionEnd (a
        # background session moved to a new version, a resume after a crash) get their
        # ended- twin here.
        eval { sessions::close_gone($sid) };
        $lin = eval { sessions::write_lineage($sid, $src) } if $src eq 'clear' || $src eq 'fork';
    }
    $lin = sessions::lineage($sid) if !$lin || $lin->{exists};
    my $d = rc::sid_dir();
    if (defined $d && $src =~ /^(startup|resume|clear)$/) {
        util::write_atomic("$d/classic-alive.json",
            jsonc::encode_bytes(jsonc::obj(pid => $c->{pid}, pid_lstart => $c->{lstart}, source => $src, ts => util::iso(util::now()))) . "\n", 0600);
    }
    # AT-RP-04: a block still pending when this session id last ended goes to its first turn
    # (the mod delivers it). Only a resume of the same session id: /clear and a fork start
    # under another id, and a compaction's own block is the session_compact path above.
    eval { resumeblock::arm($d, $sid) } if $src eq 'resume';
    if ($src =~ /^(startup|resume)$/) {
        my $ev = rc::exec_version();
        my $pd = own_data_dir();
        if (defined $ev && defined $pd && $pd ne '') {
            my $last = util::read_file("$pd/last-version");
            $last =~ s/\s+//g if defined $last;
            rc::emit('version_hint', [from => $last, to => $ev]) if defined $last && $last ne '' && $last ne $ev;
            eval { util::write_atomic("$pd/last-version", "$ev\n", 0600) } if !defined $last || $last ne $ev;
        }
    }
    rc::emit('session', [phase => 'start', source => $src, reason => undef,
                         mod_loaded => jsonc::bool(defined $d && -e "$d/mod-alive.json"),
                         previous_session_id => ($lin ? $lin->{previous_session_id} : undef),
                         lineage_reason => ($lin ? $lin->{lineage_reason} : undef),
                         pid => $c->{pid}, pid_lstart => $c->{lstart},
                         scratchpad => (defined $sp ? 'present' : 'absent'),
                         under_temp_root => (defined $sp ? jsonc::bool(sweep::_temp_root(util::clean_path($sp))) : undef)]);
    # the cross-session finish pass, after this session's own records (MOD-SPEC §5.8, ≤ 1 s)
    eval { orphans::pass(budget_ms => $orphans::PASS_MS, after => \&_finished_watch) } if $src =~ /^(startup|resume|clear)$/;
    return ('', {});
}

# own_data_name() -> this plugin's data folder name as Claude Code derives it (0.1.3): the plugin
# id `<name>@<marketplace>` with each character outside A-Z, a-z, 0-9, _ and - read as `-`
# (afk-compact@afk-compact -> afk-compact-afk-compact). The marketplace comes from where Claude
# Code loaded the plugin, CLAUDE_PLUGIN_ROOT (else the helper's own root): an installed plugin's
# .../plugins/cache/<marketplace>/<name>/<version>, a synced one's .../plugins/synced/<x>/<name>
# (`synced`; Claude Code may add `~g<n>` to that folder's name, e.g. engineering~g2), a copy read in
# place from a marketplace's folder (0.1.9, a directory marketplace: that marketplace), anything
# else a --plugin-dir run (`inline`), as settings::load_source reads it.
sub own_data_name {
    my $b = ctx::brand();
    my $m = settings::load_source()->{mkt};
    (my $id = "$b\@$m") =~ s/[^A-Za-z0-9_-]/-/g;
    return $id;
}

# own_data_dir() -> the folder that keeps last-version (0.1.3), or undef for none: when
# CLAUDE_PLUGIN_DATA is an absolute .../plugins/data/<folder> path with no `.` or `..` part, this
# plugin's own data folder there: that path when <folder> is exactly own_data_name, else the
# folder of that name beside it. The codex plugin exports its own CLAUDE_PLUGIN_DATA into session
# shells, so a helper started there saw codex's folder and wrote into it; any other plugin's
# folder is never read or written, and one record serves both cases (no version change logged
# twice). Unset or any other shape: no record (as before 0.1.3).
sub own_data_dir {
    my $pd = $ENV{CLAUDE_PLUGIN_DATA};
    return undef unless defined $pd && $pd =~ m{\A/};
    (my $p = $pd) =~ s{(?<=.)/+\z}{};
    my @seg = split m{/+}, $p;
    return undef unless @seg >= 4 && !grep({ $_ eq '.' || $_ eq '..' } @seg) && $seg[-3] eq 'plugins' && $seg[-2] eq 'data';
    my $own = own_data_name();
    return $p if $seg[-1] eq $own;
    $p =~ s{/[^/]+\z}{};
    return "$p/$own";
}

sub session_compact {
    my ($p) = @_;
    my $sid = rc::sid();
    my $d = rc::sid_dir() // return ('', {});
    my $w = rc::watch();
    my $now = util::now();
    my @recent = grep { ($_->{trigger} // '') ne 'precompute' && $_->{_epoch} >= $now - 600 } dispatch::all($w, $sid);
    my @cand = reverse grep { !-e "$d/ss-seen/$_->{nonce}" } @recent;
    my ($pick, $nonce, $nonok, $midturn);
    if (@cand) {
        rc::emit('sessionstart_ambiguous', [candidates => scalar @cand, nonce => $cand[0]{nonce}]) if @cand > 1;
        for my $c (@cand) {
            next unless util::write_excl("$d/ss-seen/$c->{nonce}", '', 0600);
            $pick = $c;
            last;
        }
        return ('', {}) unless $pick;
        rc::note_dispatch($pick);
        return ('', { dispatch => $pick->{nonce} }) unless ($pick->{resume_pref} // '') eq 'sessionstart';
        $nonce = $pick->{nonce};
        $midturn = $pick->{midturn} || (($pick->{channel} // '') eq 'classic' && ($pick->{trigger} // '') eq 'auto');
    } elsif (!@recent) {
        # No dispatch at all in the last 600 s: neither layer shaped this compaction.
        $nonce = nonce::draw($sid);
        $nonok = 1;
        $midturn = ($p->{trigger} // '') eq 'auto';
    } else {
        return ('', {});
    }
    my $block = resumeblock::build(sid => $sid, nonce => $nonce, midturn => $midturn, nonok => $nonok, saved_copy => resumeblock::pending_line(),
                                   measured_at => util::iso($now),
                                   remeasure => measure::compact($sid, $p->{cwd}, $nonce, transcript => $p->{transcript_path},
                                                                 budget_ms => $SESSION_COMPACT_MS - (util::clock_ms() - ($T0 // util::clock_ms()))));
    my ($r) = resumeblock::claim($sid, $nonce, 'sessionstart', bytes => length($block), nonok_note => jsonc::bool($nonok));
    return ('', { dispatch => $nonce }) unless $r eq 'CLAIMED';
    my $json = jsonc::encode(jsonc::obj(hookSpecificOutput => jsonc::obj(hookEventName => 'SessionStart', additionalContext => $block)));
    return ("$json\n", { dispatch => $nonce, resume_bytes => length($block) });
}

# ------------------------------------------------------------------ SessionEnd (MOD-SPEC §7)
sub on_SessionEnd {
    my ($p) = @_;
    my $sid = rc::sid();
    my $reason = (defined $p->{reason} && $p->{reason} =~ /^(clear|resume|logout|prompt_input_exit|other)$/) ? $p->{reason} : 'other';
    eval { sessions::write_ended($sid, $reason) } if rc::root_ok('handoff_root');
    eval { cachestate::on_end($sid) };
    my $c = rc::claude();
    rc::emit('session', [phase => 'end', source => undef, reason => $reason, mod_loaded => undef,
                         previous_session_id => undef, lineage_reason => undef, pid => $c->{pid}, pid_lstart => $c->{lstart}]);
    # RR-S21-02: a PostCompact deferred for want of proof is decided by reconcile (P3,
    # F2-1). A session that ends before its next Stop (/clear, exit) gets that reconcile
    # here, with the same 2 s budget: the boundary row has landed by now (S-21). Final mode
    # (RRP-05, MOD-SPEC §5.4): what P3 leaves unproven is saved unattributed at once.
    # 0.1.4: at most what leaves the finish pass and the watcher's end pass their time by
    # END_BY_MS from the helper's start, so a start slowed by load still ends inside the 5 s
    # timeout (a save reconcile has no time to sweep waits for a later run, as at Stop).
    my $rb = $END_BY_MS - $END_WATCH_MS - $orphans::PASS_MS - (util::clock_ms() - ($T_START // util::clock_ms()));
    $rb = $RECONCILE_MS if $rb > $RECONCILE_MS;
    $rb = 0 if $rb < 0;
    my $n = eval { reconcile::run(transcript => $p->{transcript_path}, cwd => $p->{cwd}, budget_ms => int $rb,
                                  final => 1, cutoff => reconcile::cutoff()) };
    # then the cross-session finish pass (MOD-SPEC §5.8, ≤ 1 s)
    eval { orphans::pass(budget_ms => $orphans::PASS_MS, after => \&_finished_watch) };
    return ('', { reconcile => $n });
}

# ------------------------------------------------------------------ Stop / SubagentStop (MOD-SPEC §5.4, §7)
sub on_Stop {
    my ($p) = @_;
    my $d = rc::sid_dir() // return ('', {});
    eval { sidecar::write($d, $p, 'Stop') };
    eval { util::write_atomic("$d/last-stop", util::iso_ms(util::now()) . "\n", 0600) };
    # SESSION-RESTART D10, §3.6, G12: the turn's permission mode and effort level, and the transcript
    eval { restart::note_stop($d, $p) };
    # AT-RP-04: a resume block armed for this process's first turn that the turn did not take
    eval { resumeblock::settle_armed($d, rc::sid()) };
    # reconcile: at most 2 s, and no more than leaves the watcher its minimum (a start slowed by
    # load shortens it; its sweeps get what is left of it)
    my $rb = _stop_left($RECONCILE_MS, $WATCH_MIN_MS);
    util::trace("stop-reconcile-budget $rb") if $rb < $RECONCILE_MS;
    my $r0 = util::clock_ms();
    my $n = reconcile::run(transcript => $p->{transcript_path}, cwd => $p->{cwd}, budget_ms => $rb, cutoff => reconcile::cutoff());
    my $rms = util::clock_ms() - $r0;
    %STOP = (%STOP, reconcile_ms => $rms, reconcile_budget_ms => $rb);
    # cut by the Stop budget: a budget under reconcile's own 2 s that ran out, or a main-proven
    # save left for the next Stop (no time for its sweep)
    push @{ $STOP{cut} }, 'reconcile' if ($rb < $RECONCILE_MS && $rms >= $rb) || (ref $n eq 'HASH' && $n->{waited});
    # the cross-session finish pass, only when reconcile left ≥ 500 ms of its budget (MOD-SPEC §5.8)
    my $rleft = $rb - (util::clock_ms() - $r0);
    eval { orphans::pass(budget_ms => ($rleft < $orphans::PASS_MS ? $rleft : $orphans::PASS_MS), after => \&_finished_watch) }
        if $rleft >= $orphans::STOP_MIN_LEFT_MS;
    # Dev-1 D5: a relaunch bumped in this turn that no recorded job matched
    eval { jobrec::on_stop($d) };
    my ($gb, $g0) = (_stop_left($GSD_WARM_MS, $WATCH_MIN_MS), util::clock_ms());
    my $gsd = eval { _warm_gsd($d, $p->{transcript_path}, $gb) };
    if (defined $gsd) {
        %STOP = (%STOP, gsd => $gsd, gsd_ms => util::clock_ms() - $g0);
        # cut by the Stop budget: a catch-up it gave less than its own 300 ms that did not finish
        push @{ $STOP{cut} }, 'gsd' if $gb < $GSD_WARM_MS && $gsd ne 'ok';
    }
    return ('', { reconcile => $n });
}

# 0.1.3 hook speed: the GSD scan cache (lib/gsd.pm, <watch>/<sid>/gsd-scan.json) is read on from
# its offset by the checkpoint before a compaction (1.5 s) and by SessionStart(compact); a cache
# that is missing, of another file or version, or GSD_WARM_LAG bytes or more behind the
# transcript's end is read on here, within GSD_WARM_MS, so neither starts from far back (a whole
# 50 MB transcript under load ran out of its 1.5 s: `GSD: not measured (timeout)`). A scan that
# runs out keeps its offset; the next Stop reads on.
# _warm_gsd(d, transcript, budget) -> undef (no catch-up due), gsd::scan's status ('ok', 'timeout':
# the scan ran out, 'unread') or 'no-time' (due, but the budget is under GSD_WARM_MIN_MS)
sub _warm_gsd {
    my ($d, $tp, $budget) = @_;
    return undef unless defined $tp && !ref $tp && $tp ne '';
    my @s = stat $tp;
    return undef unless @s && -f _;
    my $cache = "$d/$gsd::CACHE";
    # the cache's own fields, without decoding its state: v, dev, ino, offset
    my $raw = -f $cache ? util::read_file($cache, 256 * 1024) // '' : '';
    my %c = map { ($_ => ($raw =~ /"\Q$_\E":(\d+)/)[0]) } qw(dev ino offset);
    ($c{v}) = $raw =~ /"v":(\d+)\}\s*\z/;
    return undef if defined $c{offset} && ($c{v} // -1) == $gsd::CACHE_V && ($c{dev} // -1) == $s[0] && ($c{ino} // -1) == $s[1]
                    && $c{offset} <= $s[7] && $s[7] - $c{offset} < $GSD_WARM_LAG;
    return 'no-time' unless $budget >= $GSD_WARM_MIN_MS;
    util::trace('stop-gsd-warm');
    my (undef, $status) = gsd::scan($tp, cache => $cache, budget_ms => $budget);
    return $status // 'ok';
}

# 0.1.3 hook speed: one `stop_timing` row per Stop (not with `watcher: off`), written last: the
# hook's own duration from the helper's start (ms; the launcher's shell before main.pl is not
# in it), the start itself (start_ms: main.pl's mark to this file's run, the libraries' compile), what
# reconcile, the GSD catch-up and the watcher took and were given, and which phases the Stop
# budget cut (cut). Claude Code's durationMs is not in the plugin's logs; this row is.
sub _stop_row {
    my ($t0, $w0, $window_s) = @_;
    return if _watcher_off();
    my $now = util::clock_ms();
    rc::emit('stop_timing', [ms => $now - $T_START, start_ms => $t0 - $T_START, reconcile_ms => $STOP{reconcile_ms},
                             reconcile_budget_ms => $STOP{reconcile_budget_ms}, gsd => $STOP{gsd} // 'none',
                             gsd_ms => $STOP{gsd_ms}, watch_ms => $now - $w0, watch_window_ms => int($window_s * 1000),
                             cut => $STOP{cut} || []]);
}

sub on_SubagentStop {
    my ($p) = @_;
    my $d = rc::sid_dir() // return ('', {});
    sidecar::write($d, $p, 'SubagentStop');
    return ('', {});
}

# ------------------------------------------------------------------ StopFailure (WATCHER W10)
# watcher = off also stops the stop_failure and permission_denied rows (WATCHER §8 item 6,
# W-BETA A, CONFIG-REVIEW BG-29); the value is read as _watch_call reads it (trimmed, folded).
sub _watcher_off { my $w = settings::trim(lc(rc::val('watcher') // 'shadow')); return $w eq 'off' ? 1 : 0 }

sub on_StopFailure {
    my ($p) = @_;
    return ('', {}) if _watcher_off();
    my $e = $p->{error};
    my $cls = (defined $e && !ref $e && $e =~ /^[a-z_]{1,40}$/) ? $e : 'other';
    rc::emit('stop_failure', [error_class => $cls], actor => _payload_actor($p));
    return ('', {});
}

# A payload from inside a subagent carries agent_id: the row's actor is then unknown.
sub _payload_actor { my ($p) = @_; return defined $p->{agent_id} ? 'unknown' : 'main' }

# ------------------------------------------------------------------ PermissionDenied (MOD-SPEC §1.3, OD-20)
# reason_class and guard_class are fixed classes computed in memory; neither the
# raw reason nor tool_input is ever stored.
our @REASON = (
    ['classifier-unavailable' => qr/classifier.{0,40}(unavailable|error|failed|timed? ?out)|(unavailable|error).{0,20}classifier/i],
    ['classifier-policy'      => qr/classifier|auto[- ]mode|policy/i],
    ['user'                   => qr/\buser\b.{0,20}(denied|rejected|declined)|(rejected|declined) by (the )?user/i],
    ['rule'                   => qr/\brule\b|deny list|denylist|permissions?\.deny|settings/i],
);
our @GUARD_DEFAULT = (
    ['sleep-poll'  => qr/\bsleep\b|\bpoll(ing)?\b|wait loop/i],
    ['secret'      => qr/secret|credential|token|password|\.env\b|api[_ -]?key/i],
    ['routing'     => qr/rout(e|ing)|delegat|model/i],
    ['write-guard' => qr/write|edit|protected|read-only|readonly/i],
    ['scope'       => qr/outside|scope|directory|working dir|path/i],
);

our $GUARD_MAX = 32;
sub _guard_rules {
    my $s = rc::val('deny_class_patterns') // '';
    return @GUARD_DEFAULT if $s eq '';
    my @r;
    my $n = 0;
    for my $pair (split /;/, $s) {
        next unless $pair =~ /\S/;    # positions count the entries, as settings::list does
        $n++;
        # U-06: the limits of the other pattern keys (32 entries, 200 characters, settings::pattern_ok)
        last if $n > $GUARD_MAX;
        # the class, then the rest trimmed: (.+?)\s*$ tried \s*$ at every space of an inner run
        # (150,000 spaces held this 2 s hook past 10 s; U-06 review)
        next unless $pair =~ /\A\s*(sleep-poll|routing|secret|write-guard|scope|other)\s*=/;
        my ($cls, $src) = ($1, settings::trim(substr($pair, $+[0])));
        next if $src eq '' || index($src, "\n") >= 0;
        next unless settings::pattern_ok($src, 200);
        my $re = eval { local $SIG{__WARN__} = sub { }; qr/$src/i } or next;
        push @r, [$cls => $re, $n];
    }
    return @r ? @r : @GUARD_DEFAULT;
}

# _guard_class(text) -> the first guard class whose pattern matches, else `other`. The user's
# deny_class_patterns (rules with a position) run with the time bound of lib/userre.pm (U-06):
# one that is stopped does not match.
sub _guard_class {
    my ($hay) = @_;
    my @r = _guard_rules();
    if (@r && defined $r[0][2]) {
        my $k = userre::first('deny_class_patterns', [map { { re => $_->[1], at => $_->[2] } } @r], [$hay], 'skip');
        return defined $k ? $r[$k][0] : 'other';
    }
    for my $r (@r) { return $r->[0] if $hay =~ $r->[1] }
    return 'other';
}

# _turn_kind() -> (kind, inject_epoch, heal_epoch): the turn kind of MOD-SPEC §1.3 from the
# newest rows after the last Stop, the time of the plugin-injected block behind it, and
# the time of a heal action after the last Stop (WATCHER-SPEC §6.3 caused_by).
sub _turn_kind {
    my ($tail) = @_;
    my $d = rc::sid_dir() // return ('other', undef, undef);
    my $ls = util::read_file("$d/last-stop");
    my $last = defined $ls ? util::parse_iso(($ls =~ /(\S+)/)[0] // '') : undef;
    $last //= 0;
    my $newest = sub {
        my ($rows, $re) = @_;
        for my $r (reverse @$rows) {
            next unless ($r->{ev} // '') =~ $re;
            my $e = util::parse_iso($r->{ts} // '') // next;
            return $e > $last ? $e : undef;
        }
        return undef;
    };
    # Only the newest row of each kind matters, and PermissionDenied has 2 s: read the
    # stream tails (256 KB) and decode only the rows asked for.
    my $classic = rollup::stream_rows(rc::stream_path('classic'), evs => ['resume_receipt', 'heal', 'copy'], tail => 256 * 1024);
    $LAST_CLASSIC = $classic;
    my $heal = $newest->($classic, qr/^heal$/);
    my $rolls = rollup::stream_rows("$d/compactions.jsonl", tail => 256 * 1024);
    my ($post) = sort { $b <=> $a } grep { $_ > $last }
                 map { util::parse_iso($_->{ts} // '') // 0 } grep { ($_->{actor} // '') eq 'main' } @$rolls;
    return ('post-compaction', $post, $heal) if defined $post;
    my $pend = _pending_post($d, $last, $tail);
    return ('post-compaction', $pend, $heal) if defined $pend;
    my $res = $newest->($classic, qr/^resume_receipt$/);
    return ('resume', $res, $heal) if defined $res;
    my $mod = rollup::stream_rows(rc::stream_path('mod'), evs => ['nudge'], tail => 256 * 1024);
    my $nudge = $newest->($mod, qr/^nudge$/);
    return ('nudge', $nudge, $heal) if defined $nudge;
    return ('other', undef, $heal);
}

# RR-S21-03 (PKG-RUNTIME E.1): a pending PostCompact record counts as a post-compaction turn when
# no main rollup row exists after the last Stop: its ts is after the last Stop, no copy row names
# it yet, and a main compact_boundary row in the transcript tail lies within [ts - 2 s, ts + 600 s]
# (F2-1 constants). At most the 20 newest records; the inject time is the record's ts.
sub _pending_post {
    my ($d, $last, $tail) = @_;
    return undef unless defined $tail;
    my @rec;
    for my $f (util::list_dir("$d/pending")) {
        next unless $f =~ /\A(?:[0-9a-f]{6}|h[0-9a-f]{5}(?:-\d+)?)\.post\.json\z/;
        my $raw = util::read_file("$d/pending/$f") // next;
        my $j = eval { jsonc::decode($raw) };
        next unless ref $j eq 'HASH';
        my $e = util::parse_iso($j->{ts} // '') // next;
        push @rec, { %$j, e => $e } if $e > $last;
    }
    return undef unless @rec;
    @rec = (sort { $b->{e} <=> $a->{e} } @rec)[0 .. ($#rec > 19 ? 19 : $#rec)];
    my %copied;
    for my $r (@{ $LAST_CLASSIC || [] }) {
        next unless ($r->{ev} // '') eq 'copy' && ($r->{result} // '') !~ /^failed/;
        $copied{"i:$r->{id6}"} = 1 if defined $r->{id6};
        $copied{"n:$r->{nonce}"} = 1 if defined $r->{nonce};
    }
    my @bounds;
    for my $line (split /\n/, $tail) {
        next unless index($line, q{compact_boundary}) >= 0 && $line !~ m{"isSidechain"\s*:\s*true};
        my $bd = transcript::boundary($line) or next;
        push @bounds, $bd->{epoch};
    }
    for my $r (@rec) {
        next if $copied{"i:$r->{id6}"} || (defined $r->{nonce} && $copied{"n:$r->{nonce}"});
        return $r->{e} if grep { $_ >= $r->{e} - $reconcile::TOL_S && $_ <= $r->{e} + $reconcile::MAIN_WINDOW_S } @bounds;
    }
    return undef;
}

# The transcript's last 512 KB (one read for _turn_kind and _calls_since), or undef.
sub _tail512 {
    my ($path) = @_;
    return undef unless defined $path && !ref $path && $path ne '' && -f $path;
    return util::read_tail($path, 512 * 1024);
}

# Main-thread tool calls in the transcript's last 512 KB stamped after `since`, or undef
# when the transcript cannot be read.
sub _calls_since {
    my ($tail, $since) = @_;
    return undef unless defined $tail;
    my $n = 0;
    for my $line (split /\n/, $tail) {
        next unless index($line, '"tool_use"') >= 0;
        my $j = eval { jsonc::decode($line) };
        next unless ref $j eq 'HASH' && ($j->{type} // '') eq 'assistant' && !$j->{isSidechain};
        my $e = util::parse_iso($j->{timestamp} // '') // next;
        next unless $e > $since;
        my $c = ref $j->{message} eq 'HASH' ? $j->{message}{content} : undef;
        $n += grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'tool_use' } @$c if ref $c eq 'ARRAY';
    }
    return $n;
}

# WATCHER-SPEC §6.3: `plugin` when the denied call is within the first 10 calls after a
# plugin-injected block or a heal action, else `session`. Without a readable transcript
# the injection alone decides (the earlier rule).
our $CAUSED_BY_CALLS = 10;
sub _caused_by {
    my ($inject, $heal, $tail) = @_;
    my @at = grep { defined } ($inject, $heal);
    return 'session' unless @at;
    my ($since) = sort { $b <=> $a } @at;
    my $n = _calls_since($tail, $since);
    return 'plugin' unless defined $n;
    return $n <= $CAUSED_BY_CALLS ? 'plugin' : 'session';
}

sub on_PermissionDenied {
    my ($p) = @_;
    return ('', {}) if _watcher_off();
    my $tool = (defined $p->{tool_name} && !ref $p->{tool_name} && $p->{tool_name} =~ /^[A-Za-z0-9_.:-]{1,80}$/) ? $p->{tool_name} : 'other';
    my $reason = defined $p->{reason} && !ref $p->{reason} ? $p->{reason} : '';
    my $rc = 'other';
    for my $r (@REASON) { if ($reason =~ $r->[1]) { $rc = $r->[0]; last } }
    my $hay = $reason . "\n" . (ref $p->{tool_input} ? jsonc::encode($p->{tool_input}) : ($p->{tool_input} // ''));
    my $gc = _guard_class($hay);
    my $tail = _tail512($p->{transcript_path});
    my ($tk, $inject, $heal) = _turn_kind($tail);
    my $by = defined $p->{agent_id} ? 'session' : _caused_by($inject, $heal, $tail);
    rc::emit('permission_denied', [tool_name => $tool, reason_class => $rc, guard_class => $gc, turn_kind => $tk,
                                   caused_by => $by], actor => _payload_actor($p));
    return ('', {});
}

exit(cmd_hook::run(@ARGV));
