package watch;
# lib/watch.pm: library seam of BUILD-PLAN §3.6. Owner: WP-watch.
#
#   watch::on_hook(event, payload, ctx)   rows written at hook time
#   watch::on_stop(ctx, deadline)         sweep + rules + delivery at main Stop
#   watch::status_lines(sid[, ctx])       lines for `status` (MOD-SPEC §11)
#
# ctx is described in lib/watch/ctx.pm. Every entry point is wrapped: it never
# dies, never prints and never writes stderr (a hook's stdout is model-visible
# on PreCompact); an internal error becomes one `watch_error {stage,
# error_class}` row. `watcher: off` turns every entry into a no-op (WATCH §8.6);
# plugin-core writes are core's and are not here.
use strict;
use warnings;
use watch::ctx;
use watch::io;

my %HOOKS = (
    PreCompact       => 'pre_compact',
    PostCompact      => 'post_compact',
    StopFailure      => 'stop_failure',
    PermissionDenied => 'permission_denied',
);

sub _sid_ok { return defined $_[0] && !ref $_[0] && $_[0] =~ /\A[0-9A-Za-z][0-9A-Za-z-]{7,63}\z/ }

sub _prepare {
    my ($ctx, $payload) = @_;
    $ctx = {} unless ref $ctx eq 'HASH';
    $ctx->{payload} = $payload if ref $payload eq 'HASH';
    $ctx->{payload} = {} unless ref $ctx->{payload} eq 'HASH';
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
sub on_stop {
    my ($ctx, $deadline) = @_;
    local $SIG{__WARN__} = sub { };
    $ctx = _prepare($ctx);
    my $start = watch::io::mono();
    my $hard = !defined $deadline ? $start + 3 : $deadline < 1e9 ? $start + $deadline : $deadline;
    my $soft = $start + 2 < $hard ? $start + 2 : $hard;
    my ($out, $stage) = (undef, 'stop');
    my $ok = eval {
        local $SIG{__DIE__};
        return 1 unless _sid_ok($ctx->{sid});
        watch::ctx::init($ctx);
        return 1 unless watch::ctx::watcher_on($ctx);
        return 1 if watch::ctx::refused($ctx);
        return 1 if defined $ctx->{payload}{agent_id};
        require watch::sweep;
        require watch::rules;
        require watch::alerts;
        $stage = 'sweep';
        my $run = watch::sweep::run($ctx, $soft);
        return 1 if $run->{busy};
        my $files = $run->{files} || [];
        my $state = $run->{state} || {};
        my $sess = $state->{session} = ref $state->{session} eq 'HASH' ? $state->{session} : {};
        my $carry = ref $state->{carry} eq 'HASH' ? $state->{carry} : {};
        $sess->{task_kinds} = $carry->{task_types} if ref $carry->{task_types} eq 'HASH';
        # Rules first: they add the joined per-compaction fields to each
        # boundary record before the sweep rows are written.
        $stage = 'rules';
        my $S = watch::rules::load_session($ctx);
        my $ex = watch::alerts::load_existing($ctx);
        my $hard_stop = watch::io::mono() >= $hard;
        watch::rules::evaluate($ctx, $S, $ex, $sess, $files) unless $hard_stop;
        $stage = 'sweep';
        for my $f (@$files) {
            watch::ctx::error_row($ctx, 'sweep', 'unreadable') if $f->{unreadable};
            watch::ctx::error_row($ctx, 'sweep', 'bad-json') if $f->{bad_lines};
            watch::ctx::log_row($ctx, 'sweep', $_, actor => $f->{actor}) for watch::sweep::rows_for($f);
            if ($f->{partial}) {
                watch::ctx::log_row($ctx, 'sweep_partial', { file => $f->{file}, from_off => $f->{from_off},
                                                             to_off => $f->{to_off}, reason => 'budget' },
                                    actor => $f->{actor});
            }
        }
        if ($hard_stop) {
            watch::ctx::log_row($ctx, 'sweep_partial', { file => undef, from_off => undef, to_off => undef,
                                                         reason => 'hard-stop' }, actor => 'main');
        }
        $sess->{last_stop_ts} = $ctx->{now};
        $carry->{last_stop_ts} = $ctx->{now} if %$carry;
        delete $sess->{task_kinds};
        watch::sweep::finish($run);
        $stage = 'deliver';
        $out = watch::alerts::deliver($ctx, $ex);
        1;
    };
    unless ($ok) {
        my $err = $@;
        eval { local $SIG{__DIE__}; watch::ctx::init($ctx); watch::ctx::error_row($ctx, $stage, _class($err)) };
        $out = undef;
    }
    return $out;
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

1;
