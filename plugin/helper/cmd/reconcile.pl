# cmd/reconcile.pl: `reconcile --sid S [--transcript PATH] [--cwd DIR]` (MOD-SPEC §5.4) ->
# `reconciled late=<n> unresolved=<n> precompute_not_reused=<n> order_anomaly=<n> undelivered=<n>`.
# Owner: WP-core.
use strict;
use warnings;
use utf8;

package cmd_reconcile;

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid transcript cwd root log-dir disposable-root)]);
    my $sid = args::init_sid($opt);
    my $n = reconcile::run(transcript => $opt->{transcript}, cwd => $opt->{cwd} // do { require Cwd; Cwd::getcwd() },
                           budget_ms => 2000, cutoff => reconcile::cutoff());
    args::out(reconcile::line($n));
    return 0;
}

exit(args::main(\&run, @ARGV));
