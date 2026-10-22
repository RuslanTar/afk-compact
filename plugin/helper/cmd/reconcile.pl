# cmd/reconcile.pl: `reconcile --sid S [--transcript PATH] [--cwd DIR] [--final] [--orphans [--full]]`
# (MOD-SPEC §5.4, §5.8; BUILD-PLAN §3.1) ->
# `reconciled late=<n> unresolved=<n> precompute_not_reused=<n> order_anomaly=<n> undelivered=<n>`,
# with `--orphans`: `; orphans finished=<n> kept=<n> left=<n>` on the same line.
#   --final    this session's run in final mode (no SETTLE_S wait; RRP-05)
#   --orphans  then the cross-session finish pass for ended sessions (≤ 3 sids, 1 s)
#   --full     the backstop: every <watch>/*/pending/, from the start, 10 s, no sid cap (the
#              user-run command the status skill offers)
# Owner: WP-core.
use strict;
use warnings;
use utf8;

package cmd_reconcile;

our $FULL_MS = 10000;

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid transcript cwd root log-dir disposable-root)], bools => [qw(final orphans full)]);
    my $sid = args::init_sid($opt);
    die "usage: --full needs --orphans\n" if $opt->{full} && !$opt->{orphans};
    my $n = reconcile::run(transcript => $opt->{transcript}, cwd => $opt->{cwd} // do { require Cwd; Cwd::getcwd() },
                           budget_ms => 2000, final => ($opt->{final} ? 1 : 0), cutoff => reconcile::cutoff());
    my $line = reconcile::line($n);
    if ($opt->{orphans}) {
        my $o = $opt->{full} ? orphans::pass(budget_ms => $FULL_MS, max_sids => 1_000_000, full => 1)
                             : orphans::pass(budget_ms => $orphans::PASS_MS);
        $line .= sprintf('; orphans finished=%d kept=%d left=%d', $o->{finished}, $o->{kept}, $o->{left});
    }
    args::out($line);
    return 0;
}

exit(args::main(\&run, @ARGV));
