# cmd/hook.pl: `hook <Event>`, the classic command-hook entry (MOD-SPEC §1.3, §3.2, §3.4,
# §5.3, §5.4, §7; BUILD-PLAN §3.3). Owner: WP-core (+ watch.on_hook / watch.on_stop).
# Always exits 0. Prints nothing, or exactly the event's documented output: PreCompact
# the fallback text, SessionStart(compact) one hookSpecificOutput JSON line. An internal
# error writes one `watch_error {stage, error_class}` row and prints nothing.
use strict;
use warnings;

package cmd_hook;

our %EVENTS = map { $_ => 1 } qw(PreCompact PostCompact SessionStart SessionEnd Stop SubagentStop StopFailure PermissionDenied);
our %KEYSET_EVENTS = map { $_ => 1 } qw(PreCompact PostCompact SessionStart);

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
             now => util::now(), %{ $extra || {} } };
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
    rc::init(sid => $sid, writer => 'classic');
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
    } else {
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
                                       cc_version => rc::cc_version(), load_id => undef, pid => $c->{pid}, pid_lstart => $c->{lstart});
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
                         pid => $c->{pid}, pid_lstart => $c->{lstart}]);
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
    my $block = resumeblock::build(sid => $sid, midturn => $midturn, nonok => $nonok, saved_copy => resumeblock::pending_line(),
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
    return ('', {});
}

# ------------------------------------------------------------------ Stop / SubagentStop (MOD-SPEC §5.4, §7)
sub on_Stop {
    my ($p) = @_;
    my $d = rc::sid_dir() // return ('', {});
    eval { sidecar::write($d, $p, 'Stop') };
    eval { util::write_atomic("$d/last-stop", util::iso_ms(util::now()) . "\n", 0600) };
    my $n = reconcile::run(transcript => $p->{transcript_path}, cwd => $p->{cwd}, budget_ms => 2000, cutoff => reconcile::cutoff());
    return ('', { reconcile => $n });
}

sub on_SubagentStop {
    my ($p) = @_;
    my $d = rc::sid_dir() // return ('', {});
    sidecar::write($d, $p, 'SubagentStop');
    return ('', {});
}

# ------------------------------------------------------------------ StopFailure (WATCHER W10)
sub on_StopFailure {
    my ($p) = @_;
    my $e = $p->{error};
    my $cls = (defined $e && !ref $e && $e =~ /^[a-z_]{1,40}$/) ? $e : 'other';
    rc::emit('stop_failure', [error_class => $cls]);
    return ('', {});
}

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

sub _turn_kind {
    my $d = rc::sid_dir() // return 'other';
    my $ls = util::read_file("$d/last-stop");
    my $last = defined $ls ? util::parse_iso(($ls =~ /(\S+)/)[0] // '') : undef;
    $last //= 0;
    my $newer = sub {
        my ($rows, $re) = @_;
        for my $r (reverse @$rows) {
            next unless ($r->{ev} // '') =~ $re;
            my $e = util::parse_iso($r->{ts} // '') // next;
            return $e > $last ? 1 : 0;
        }
        return 0;
    };
    my $rolls = rollup::rows($d);
    return 'post-compaction' if grep { ($_->{actor} // '') eq 'main' && (util::parse_iso($_->{ts} // '') // 0) > $last } @$rolls;
    my $classic = rollup::stream_rows(rc::stream_path('classic'));
    return 'resume' if $newer->($classic, qr/^resume_receipt$/);
    my $mod = rollup::stream_rows(rc::stream_path('mod'));
    return 'nudge' if $newer->($mod, qr/^nudge$/);
    return 'other';
}

sub on_PermissionDenied {
    my ($p) = @_;
    my $tool = (defined $p->{tool_name} && !ref $p->{tool_name} && $p->{tool_name} =~ /^[A-Za-z0-9_.:-]{1,80}$/) ? $p->{tool_name} : 'other';
    my $reason = defined $p->{reason} && !ref $p->{reason} ? $p->{reason} : '';
    my $rc = 'other';
    for my $r (@REASON) { if ($reason =~ $r->[1]) { $rc = $r->[0]; last } }
    my $hay = $reason . "\n" . (ref $p->{tool_input} ? jsonc::encode($p->{tool_input}) : ($p->{tool_input} // ''));
    my $gc = 'other';
    for my $r (_guard_rules()) { if ($hay =~ $r->[1]) { $gc = $r->[0]; last } }
    my $tk = _turn_kind();
    rc::emit('permission_denied', [tool_name => $tool, reason_class => $rc, guard_class => $gc, turn_kind => $tk,
                                   caused_by => ($tk eq 'other' ? 'session' : 'plugin')]);
    return ('', {});
}

exit(cmd_hook::run(@ARGV));
