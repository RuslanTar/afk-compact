# cmd/watch.pl: `watch` subcommand (BUILD-PLAN §3.1). Owner: WP-watch.
# v1 has one form: `watch prune --days N [--sid S]` (D-9). It is built and
# tested but no hook calls it until the owner answers E-8. `watch report`,
# `audit` and `backfill` are W13, deferred (BUILD-PLAN §0): usage error.
#
# stdout: `pruned files=<n> bytes=<n>`; row `watch_prune` (to the given
# session's classic log, else to `<watch>/unknown.classic.jsonl`).
# Exit: 0 ran, 64 usage, 70 internal error.
use strict;
use warnings;
use watch::ctx;
use watch::io;
use watch::prune;

$SIG{__WARN__} = sub { };

sub _usage {
    print STDERR "usage: watch prune --days N [--sid S]\n";
    exit 64;
}

my $form = shift @ARGV;
_usage() unless defined $form && $form eq 'prune';
my ($days, $sid) = (30, undef);
while (@ARGV) {
    my $a = shift @ARGV;
    if ($a eq '--days') {
        $days = shift @ARGV;
        _usage() unless defined $days && $days =~ /\A[1-9][0-9]{0,4}\z/;
    } elsif ($a =~ /\A--days=([1-9][0-9]{0,4})\z/) {
        $days = $1;
    } elsif ($a eq '--sid') {
        $sid = shift @ARGV;
        _usage() unless defined $sid && $sid =~ /\A[0-9A-Za-z][0-9A-Za-z-]{7,63}\z/;
    } else {
        _usage();
    }
}

my $res = eval {
    local $SIG{__DIE__};
    my $ctx = watch::ctx::init({ sid => (defined $sid ? $sid : 'unknown') });
    my $r = watch::prune::prune(watch => $ctx->{watch}, days => 0 + $days, now => $ctx->{now});
    watch::ctx::log_row($ctx, 'watch_prune', { days => 0 + $days, files => $r->{files}, bytes => $r->{bytes},
                                               sessions => $r->{sessions}, kept => $r->{kept} },
                        writer => 'helper', actor => 'unknown')
        if -d $ctx->{watch};
    $r;
};
unless ($res) {
    print STDERR "watch: internal error\n";
    exit 70;
}
print "pruned files=$res->{files} bytes=$res->{bytes}\n";
exit 0;
