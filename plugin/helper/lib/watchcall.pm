package watchcall;
# lib/watchcall.pm: how core calls the watcher (lib/watch.pm, BUILD-PLAN §3.6), shared by the
# `hook` entry (cmd/hook.pl) and the `reconcile` CLI (cmd/reconcile.pl). Owner: WP-core.
#   ctx(event, extra)        the watch ctx core passes (lib/watch/ctx.pm contract)
#   call(stage, fn)          run a watcher seam with stdout closed off; an error -> one watch_error row
#   finished(n, meta, ms)    orphans::pass `after`: the watcher's end pass for a session finished across
#                            sessions (lib/orphans.pm, in that session's context after its final
#                            reconcile), as its own SessionEnd would have run it (its held A-01s;
#                            lib/watch/rules.pm a01_end). 0.1.4: the CLI's finish pass runs it too.
use strict;
use warnings;
use utf8;

# The end pass takes at most this long (cmd/hook.pl END_WATCH_MS, the same value).
our $END_WATCH_MS = 1000;

sub error_class {
    my ($e) = @_;
    $e //= '';
    return 'spec' if $e =~ /^spec:/;
    return 'json' if $e =~ /^json:/;
    return 'assets' if $e =~ /^assemble:/;
    return 'lock-timeout' if $e =~ /lock-timeout/;
    return 'io' if $e =~ /^(create|open|write|close|rename|mkdir|lock open)\b/;
    return 'internal';
}

sub ctx {
    my ($event, $extra) = @_;
    return { sid => rc::sid(), event => $event, settings => rc::settings(), paths => rc::paths(), watch => rc::watch(),
             sid_dir => rc::sid_dir(), plugin_root => ctx::root(), brand => ctx::brand(), version => ctx::version(),
             now => util::now(), cc_version => rc::cc_version(), cc_version_src => rc::cc_version_src(), %{ $extra || {} } };
}

# Nothing the watcher does may reach stdout (a hook's stdout is model-visible on PreCompact).
sub call {
    my ($stage, $fn) = @_;
    return if (rc::val('watcher') // 'shadow') eq 'off';
    open(my $saved, '>&', \*STDOUT) or return;
    open(STDOUT, '>', '/dev/null');
    my $ok = eval { require "watch.pm"; $fn->(); 1 };
    my $err = $@;
    open(STDOUT, '>&', $saved);
    if (!$ok && $err !~ /not implemented/) { rc::emit('watch_error', [stage => $stage, error_class => error_class($err)]) }
}

sub finished {
    my ($n, $meta, $left_ms) = @_;
    return if !defined $left_ms || $left_ms < 100;
    $left_ms = $END_WATCH_MS if $left_ms > $END_WATCH_MS;
    my $p = { session_id => rc::sid(), transcript_path => (ref $meta eq 'HASH' ? $meta->{transcript} : undef) };
    call('watch.on_hook', sub { watch::on_hook('SessionEnd', $p, ctx('SessionEnd', { reconcile => $n }), $left_ms / 1000) });
}

1;
