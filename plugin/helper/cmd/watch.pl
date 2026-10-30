# cmd/watch.pl: `watch` subcommand (BUILD-PLAN §3.1). Owner: WP-watch.
# Forms:
#   watch prune --days N [--sid S]      (D-9) built and tested; no hook calls it until the
#                                       owner answers E-8. stdout `pruned files=<n> bytes=<n>`;
#                                       row `watch_prune` (the given session's classic log,
#                                       else <watch>/unknown.classic.jsonl).
#   watch report [--since <N>d|<YYYY-MM-DD>|all] [--input DIR] [--export] [--out FILE]
#                                       W13 (WATCHER-SPEC §10.2, §10.7; W-BETA E): the report
#                                       markdown. Live: <watch>/reports/<date>_watch-report.md;
#                                       --input DIR (export rows): printed unless --out.
#                                       stdout `WATCH-REPORT <path>`.
#   watch audit [--since ...] [--input DIR]   W13 audit: `AUDIT FAIL ...` lines, then
#                                       `AUDIT: PASS|FAIL (...)`; exit 1 on a failure.
# `watch backfill` is W13 too and stays deferred (BUILD-PLAN §0): usage error.
# prune and a report that writes under the watch dir (the default reports/ folder, or --export's
# salt) print `REFUSED: <key>: <reason>` and exit 3 when the watch dir or handoff root is
# refused (WATCH §6.1, watch::ctx::refused); they write and delete nothing then.
# Exit: 0 ran, 1 audit failed, 3 REFUSED, 64 usage, 70 internal error, 73 output not writable.
use strict;
use warnings;
use utf8;
use watch::ctx;
use watch::io;
use watch::prune;

$SIG{__WARN__} = sub { };

sub _usage {
    print STDERR "usage: watch prune --days N [--sid S]\n"
               . "       watch report [--since <N>d|<YYYY-MM-DD>|all] [--input DIR] [--export] [--out FILE]\n"
               . "       watch audit [--since <N>d|<YYYY-MM-DD>|all] [--input DIR]\n";
    exit 64;
}

my $form = shift @ARGV;
_usage() unless defined $form;

if ($form eq 'report' || $form eq 'audit') {
    require watch::report;
    my %seed;
    $seed{sha256} = \&sha::hex256 if defined &sha::hex256;
    my $code = eval {
        local $SIG{__DIE__};
        $form eq 'report' ? watch::report::report_cli([@ARGV], \%seed) : watch::report::audit_cli([@ARGV], \%seed);
    };
    unless (defined $code) {
        print STDERR "watch: internal error\n";
        exit 70;
    }
    _usage() if $code == 64;
    exit $code;
}

_usage() unless $form eq 'prune';
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
    # WATCH §6.1: under a refused watch dir or handoff root the watcher deletes and writes nothing
    if (my $why = watch::ctx::refused($ctx)) { return { refused => $why } }
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
if (defined $res->{refused}) {
    print "REFUSED: $res->{refused}\n";
    exit 3;
}
print "pruned files=$res->{files} bytes=$res->{bytes}\n";
exit 0;
