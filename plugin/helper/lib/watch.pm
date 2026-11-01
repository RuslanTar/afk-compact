package watch;
# lib/watch.pm: library seam of BUILD-PLAN §3.6. Owner: WP-watch.
#
#   watch::on_hook(event, payload, ctx)   rows written at hook time
#   watch::on_stop(ctx, deadline)         sweep + rules + delivery at main Stop
#   watch::status_lines(sid[, ctx])       lines for `status` (MOD-SPEC §11)
#   watch::verdict_line(sid[, ctx])       the verdict line that opens `status`
#
# ctx is described in lib/watch/ctx.pm. Every entry point is wrapped: it never
# dies, never prints and never writes stderr (a hook's stdout is model-visible
# on PreCompact); an internal error becomes one `watch_error {stage,
# error_class}` row. `watcher: off` turns every entry into a no-op (WATCH §8.6);
# plugin-core writes are core's and are not here.
use strict;
use warnings;
use utf8;
use watch::ctx;
use watch::io;
use watch::json;

# StopFailure and PermissionDenied have one writer, core's `hook` (ROOT-RULINGS
# F2-5): core writes `stop_failure` and `permission_denied` (with its computed
# classes) and the watcher only reads them, so on_hook does nothing for them.
my %HOOKS = (
    PreCompact  => 'pre_compact',
    PostCompact => 'post_compact',
);

sub _sid_ok { return defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9A-Za-z][0-9A-Za-z-]{7,63}\z/ }

# Core decodes the payload into character strings; the watcher works on UTF-8
# bytes (its codec and the spec literals). Every plain value of ctx (payload,
# detect, instructions, settings, paths) is taken as bytes; code refs stay.
sub _prepare {
    my ($ctx, $payload) = @_;
    $ctx = {} unless ref $ctx eq 'HASH';
    $ctx->{payload} = $payload if ref $payload eq 'HASH';
    $ctx->{payload} = {} unless ref $ctx->{payload} eq 'HASH';
    for my $k (keys %$ctx) {
        my $r = ref $ctx->{$k};
        $ctx->{$k} = watch::json::bytes($ctx->{$k}) if !$r || $r eq 'HASH' || $r eq 'ARRAY';
    }
    $ctx->{sid} //= $ctx->{payload}{session_id};
    return $ctx;
}

sub _class {
    my ($err) = @_;
    my $e = defined $err ? "$err" : '';
    $e =~ s/\s+\z//;
    return $e =~ /\A[a-z][a-z0-9-]{0,39}\z/ ? $e : 'internal';
}

sub on_hook {
    my ($event, $payload, $ctx) = @_;
    local $SIG{__WARN__} = sub { };
    $ctx = _prepare($ctx, $payload);
    my $ok = eval {
        local $SIG{__DIE__};
        return 1 unless _sid_ok($ctx->{sid});
        my $fn = defined $event ? $HOOKS{$event} : undef;
        return 1 unless $fn;
        watch::ctx::init($ctx);
        return 1 unless watch::ctx::watcher_on($ctx);
        return 1 if watch::ctx::refused($ctx);
        watch::ctx::note_watcher_value($ctx);
        require watch::hooks;
        no strict 'refs';
        &{"watch::hooks::$fn"}($ctx);
        1;
    };
    unless ($ok) {
        my $err = $@;
        eval { local $SIG{__DIE__}; watch::ctx::init($ctx); watch::ctx::error_row($ctx, 'hook-' . ($event // 'unknown'), _class($err)) };
    }
    return undef;
}

# `deadline`: the hard stop as epoch seconds, or seconds from now when small.
#
# Time (WATCH W9; ROOT-RULINGS F2-4): every phase runs inside the hard stop.
# The sweep reads until the soft limit. The rows the rules need come from the
# persisted incremental cache (lib/watch/cache.pm), which reads only the new
# stream bytes. The rules check the clock as they go. When the hard stop
# passes in the sweep, the cache load or the rules, the run is dropped: no
# transcript offset or session state is kept (the cache keeps what it read),
# one `sweep_partial {reason: hard-stop, stage}` row is written, and the next
# Stop sweeps and evaluates the same input again. Alerts written before the
# cut are not written twice (stable ids). Delivery runs only before the hard
# stop; an alert it did not reach is delivered at a later Stop.
sub on_stop {
    my ($ctx, $deadline) = @_;
    local $SIG{__WARN__} = sub { };
    $ctx = _prepare($ctx);
    my $start = watch::io::mono();
    my $hard = !defined $deadline ? $start + 3 : $deadline < 1e9 ? $start + $deadline : $deadline;
    # Reading stops at 2 s, or at two thirds of a shorter window, so the rules
    # still fit before the hard stop.
    my $soft = $start + 2;
    my $room = $start + ($hard - $start) * 2 / 3;
    $soft = $room if $room < $soft;
    my ($out, $stage) = (undef, 'stop');
    my $run;
    my $ok = eval {
        local $SIG{__DIE__};
        return 1 unless _sid_ok($ctx->{sid});
        watch::ctx::init($ctx);
        return 1 unless watch::ctx::watcher_on($ctx);
        return 1 if watch::ctx::refused($ctx);
        watch::ctx::note_watcher_value($ctx);
        return 1 if defined $ctx->{payload}{agent_id};
        require watch::sweep;
        require watch::rules;
        require watch::alerts;
        require watch::cache;
        $stage = 'sweep';
        $run = watch::sweep::run($ctx, $soft);
        return 1 if $run->{busy};
        return _hard_stop($ctx, $run, 'sweep') if watch::io::mono() >= $hard;
        my $files = $run->{files} || [];
        my $state = $run->{state} || {};
        my $sess = $state->{session} = ref $state->{session} eq 'HASH' ? $state->{session} : {};
        my $carry = ref $state->{carry} eq 'HASH' ? $state->{carry} : {};
        $sess->{task_kinds} = $carry->{task_types} if ref $carry->{task_types} eq 'HASH';
        $stage = 'load';
        my $cache = watch::cache::load($ctx, kinds => \@watch::rules::KINDS, deadline => $hard);
        # Only the Stop holding the sweeper's lock persists the cache.
        watch::cache::save($cache) if $run->{fh};
        return _hard_stop($ctx, $run, 'load') unless $cache->{complete};
        # Rules first: they add the joined per-compaction fields to each
        # boundary record before the sweep rows are written.
        $stage = 'rules';
        my $S = watch::rules::load_session($ctx, $cache);
        my $ex = watch::alerts::load_existing($ctx, $cache);
        my $in_time = eval {
            local $ctx->{_deadline} = $hard;
            watch::rules::evaluate($ctx, $S, $ex, $sess, $files);
            watch::rules::tick($ctx);
        };
        unless ($in_time) {
            my $err = $@;
            return _hard_stop($ctx, $run, 'rules') if defined $err && !ref $err && $err eq "hard-stop\n";
            die $err;
        }
        # From here the run is committed: its sweep rows and offsets are
        # written together (a few appends and one state write).
        $stage = 'sweep';
        for my $f (@$files) {
            watch::ctx::error_row($ctx, 'sweep', 'unreadable') if $f->{unreadable};
            watch::ctx::error_row($ctx, 'sweep', 'bad-json') if $f->{bad_lines};
            watch::ctx::log_row($ctx, 'sweep', $_, actor => $f->{actor}) for watch::sweep::rows_for($f);
            # Only a time cut is a budget breach (WATCH W9, FR-22, A-25); a
            # file left over by the 5 MB cap is `sweep.partial` alone.
            if ($f->{time_cut}) {
                watch::ctx::log_row($ctx, 'sweep_partial', { file => $f->{file}, from_off => $f->{from_off},
                                                             to_off => $f->{to_off}, reason => 'time', stage => 'sweep' },
                                    actor => $f->{actor});
            }
        }
        $sess->{last_stop_ts} = $ctx->{now};
        $carry->{last_stop_ts} = $ctx->{now} if %$carry;
        delete $sess->{task_kinds};
        watch::sweep::finish($run);
        $stage = 'deliver';
        $out = watch::alerts::deliver($ctx, $ex, $hard);
        1;
    };
    unless ($ok) {
        my $err = $@;
        # A failed run keeps no offset: the next Stop reads the same bytes.
        eval { local $SIG{__DIE__}; watch::sweep::abandon($run) } if ref $run eq 'HASH' && $run->{fh};
        eval { local $SIG{__DIE__}; watch::ctx::init($ctx); watch::ctx::error_row($ctx, $stage, _class($err)) };
        $out = undef;
    }
    return $out;
}

# Hard stop (WATCH W9): the run keeps no transcript offset and no session
# state, so no swept boundary or event goes unevaluated; the next Stop sweeps
# and evaluates it again. `stage` names the phase the clock ran out in.
sub _hard_stop {
    my ($ctx, $run, $stage) = @_;
    watch::sweep::abandon($run);
    watch::ctx::log_row($ctx, 'sweep_partial', { file => undef, from_off => undef, to_off => undef,
                                                 reason => 'hard-stop', stage => $stage }, actor => 'main');
    return 1;
}

sub status_lines {
    my ($sid, $ctx) = @_;
    local $SIG{__WARN__} = sub { };
    $ctx = _prepare($ctx);
    $ctx->{sid} = $sid if defined $sid;
    my $lines = eval {
        local $SIG{__DIE__};
        require watch::status;
        watch::status::lines($ctx);
    };
    return ref $lines eq 'ARRAY' ? $lines : ['Watcher: status unavailable'];
}

# The one-line verdict that opens `status` (lib/watch/status.pm verdict), or undef (watcher
# off, or it could not be read).
sub verdict_line {
    my ($sid, $ctx) = @_;
    local $SIG{__WARN__} = sub { };
    $ctx = _prepare($ctx);
    $ctx->{sid} = $sid if defined $sid;
    my $line = eval {
        local $SIG{__DIE__};
        require watch::status;
        watch::status::verdict($ctx);
    };
    return (defined $line && !ref $line) ? $line : undef;
}

1;
