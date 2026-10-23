# cmd/hook.pl: `hook <Event>`, the classic command-hook entry (MOD-SPEC §1.3, §3.2, §3.4,
# §5.3, §5.4, §7; BUILD-PLAN §3.3). Owner: WP-core (+ watch.on_hook / watch.on_stop).
# Always exits 0. Prints nothing, or exactly the event's documented output: PreCompact
# the fallback text, SessionStart(compact) one hookSpecificOutput JSON line. An internal
# error writes one `watch_error {stage, error_class}` row and prints nothing.
use strict;
use warnings;
use utf8;

package cmd_hook;

our %EVENTS = map { $_ => 1 } qw(PreCompact PostCompact SessionStart SessionEnd Stop SubagentStop StopFailure PermissionDenied);
our %KEYSET_EVENTS = map { $_ => 1 } qw(PreCompact PostCompact SessionStart);
# One writer per row kind (ROOT-RULINGS F2-5): core writes stop_failure and
# permission_denied with their computed classes; the watcher reads those rows from the
# stream and is not called for these events, so it cannot write a second row.
our %CORE_ROWS_ONLY = map { $_ => 1 } qw(StopFailure PermissionDenied);
# the classic stream tail _turn_kind read (copy rows for the pending-record check)
our $LAST_CLASSIC;

sub _error_class {
    my ($e) = @_;
    $e //= '';
    return 'spec' if $e =~ /^spec:/;
    return 'json' if $e =~ /^json:/;
    return 'assets' if $e =~ /^assemble:/;
    return 'lock-timeout' if $e =~ /lock-timeout/;
    return 'io' if $e =~ /^(create|open|write|close|rename|mkdir|lock open)\b/;
    return 'internal';
}

sub _watch_ctx {
    my ($event, $extra) = @_;
    return { sid => rc::sid(), event => $event, settings => rc::settings(), paths => rc::paths(), watch => rc::watch(),
             sid_dir => rc::sid_dir(), plugin_root => ctx::root(), brand => ctx::brand(), version => ctx::version(),
             now => util::now(), cc_version => rc::cc_version(), cc_version_src => rc::cc_version_src(), %{ $extra || {} } };
}

# Run a watcher seam with stdout closed off (nothing it does may reach stdout).
sub _watch_call {
    my ($stage, $fn) = @_;
    return if (rc::val('watcher') // 'shadow') eq 'off';
    open(my $saved, '>&', \*STDOUT) or return;
    open(STDOUT, '>', '/dev/null');
    my $ok = eval { require "watch.pm"; $fn->(); 1 };
    my $err = $@;
    open(STDOUT, '>&', $saved);
    if (!$ok && $err !~ /not implemented/) { rc::emit('watch_error', [stage => $stage, error_class => _error_class($err)]) }
}

# Stop (8 s hook timeout): reconcile and the watcher share one budget from hook start,
# on the real clock (STORE_TEST_NOW fixes the clock, never a budget).
our $STOP_BUDGET_MS = 7000;
our $WATCH_HARD_S = 3;

# SessionStart (5 s hook timeout): the compact block is measured within this budget from
# hook start, so it is printed and claimed before the hook is killed.
our $SESSION_COMPACT_MS = 3500;
our $T0;

sub run {
    my ($event) = @_;
    my $t0 = $T0 = util::clock_ms();
    my $raw = do { local $/; <STDIN> };
    return 0 unless defined $event && $EVENTS{$event};
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
        # at most the 3 s hard stop of WATCH W9, less when reconcile used the shared budget.
        my $left = ($STOP_BUDGET_MS - (util::clock_ms() - $t0)) / 1000;
        $left = $WATCH_HARD_S if $left > $WATCH_HARD_S;
        $left = 0.2 if $left < 0.2;
        _watch_call('watch.on_stop', sub { watch::on_stop(_watch_ctx($event, { payload => $p }), $left) });
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
    my $text = assemble::classic_fallback(nonce => $nonce, auto => ($trigger eq 'auto'), previous_copy => $prev_abbrev);
    my @tags = (($trigger eq 'auto' ? ('auto') : ()), (defined $prev ? ('chain') : ()));
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
    return session_compact($p) if $src eq 'compact';
    my $c = rc::claude();
    my ($lin, $where);
    if (rc::root_ok('handoff_root')) {
        $where = git::where($p->{cwd});
        eval { sessions::write_live($sid, $p->{cwd}, $where->{toplevel}, $src) };
        $lin = eval { sessions::write_lineage($sid, $src) } if $src eq 'clear' || $src eq 'fork';
    }
    $lin = sessions::lineage($sid) if !$lin || $lin->{exists};
    my $d = rc::sid_dir();
    if (defined $d && $src =~ /^(startup|resume|clear)$/) {
        util::write_atomic("$d/classic-alive.json",
            jsonc::encode_bytes(jsonc::obj(pid => $c->{pid}, pid_lstart => $c->{lstart}, source => $src, ts => util::iso(util::now()))) . "\n", 0600);
    }
    if ($src =~ /^(startup|resume)$/) {
        my $ev = rc::exec_version();
        my $pd = $ENV{CLAUDE_PLUGIN_DATA};
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
    eval { orphans::pass(budget_ms => $orphans::PASS_MS) } if $src =~ /^(startup|resume|clear)$/;
    return ('', {});
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
                                   remeasure => measure::compact($sid, $p->{cwd}, $nonce,
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
    my $c = rc::claude();
    rc::emit('session', [phase => 'end', source => undef, reason => $reason, mod_loaded => undef,
                         previous_session_id => undef, lineage_reason => undef, pid => $c->{pid}, pid_lstart => $c->{lstart}]);
    # RR-S21-02: a PostCompact deferred for want of proof is decided by reconcile (P3,
    # F2-1). A session that ends before its next Stop (/clear, exit) gets that reconcile
    # here, with the same 2 s budget: the boundary row has landed by now (S-21). Final mode
    # (RRP-05, MOD-SPEC §5.4): what P3 leaves unproven is saved unattributed at once.
    my $n = eval { reconcile::run(transcript => $p->{transcript_path}, cwd => $p->{cwd}, budget_ms => 2000,
                                  final => 1, cutoff => reconcile::cutoff()) };
    # then the cross-session finish pass (MOD-SPEC §5.8, ≤ 1 s)
    eval { orphans::pass(budget_ms => $orphans::PASS_MS) };
    return ('', { reconcile => $n });
}

# ------------------------------------------------------------------ Stop / SubagentStop (MOD-SPEC §5.4, §7)
sub on_Stop {
    my ($p) = @_;
    my $d = rc::sid_dir() // return ('', {});
    eval { sidecar::write($d, $p, 'Stop') };
    eval { util::write_atomic("$d/last-stop", util::iso_ms(util::now()) . "\n", 0600) };
    my $r0 = util::clock_ms();
    my $n = reconcile::run(transcript => $p->{transcript_path}, cwd => $p->{cwd}, budget_ms => 2000, cutoff => reconcile::cutoff());
    # the cross-session finish pass, only when reconcile left ≥ 500 ms of its 2 s (MOD-SPEC §5.8)
    my $rleft = 2000 - (util::clock_ms() - $r0);
    eval { orphans::pass(budget_ms => ($rleft < $orphans::PASS_MS ? $rleft : $orphans::PASS_MS)) } if $rleft >= $orphans::STOP_MIN_LEFT_MS;
    # Dev-1 D5: a relaunch bumped in this turn that no recorded job matched
    eval { jobrec::on_stop($d) };
    return ('', { reconcile => $n });
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
sub _watcher_off { my $w = lc(rc::val('watcher') // 'shadow'); $w =~ s/^\s+|\s+$//g; return $w eq 'off' ? 1 : 0 }

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

sub _guard_rules {
    my $s = rc::val('deny_class_patterns') // '';
    return @GUARD_DEFAULT if $s eq '';
    my @r;
    for my $pair (split /;/, $s) {
        next unless $pair =~ /^\s*(sleep-poll|routing|secret|write-guard|scope|other)\s*=\s*(.+?)\s*$/;
        my ($cls, $src) = ($1, $2);
        my $re = eval { qr/$src/i } or next;
        push @r, [$cls => $re];
    }
    return @r ? @r : @GUARD_DEFAULT;
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
    my $gc = 'other';
    for my $r (_guard_rules()) { if ($hay =~ $r->[1]) { $gc = $r->[0]; last } }
    my $tail = _tail512($p->{transcript_path});
    my ($tk, $inject, $heal) = _turn_kind($tail);
    my $by = defined $p->{agent_id} ? 'session' : _caused_by($inject, $heal, $tail);
    rc::emit('permission_denied', [tool_name => $tool, reason_class => $rc, guard_class => $gc, turn_kind => $tk,
                                   caused_by => $by], actor => _payload_actor($p));
    return ('', {});
}

exit(cmd_hook::run(@ARGV));
