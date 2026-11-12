# cmd/report.pl: `report` subcommand.
# The work is in lib/watch/export.pm.
#   report [--dry-run] [--since <N>d|<YYYY-MM-DD>] [--out DIR] [--max-mb N] [--with-summaries]
#          [--with-handoffs]
#   (--dry-run also prints `summaries: <n> available (<KB>)` and `handoffs: <n> available (<KB>)`;
#   --with-summaries adds the saved compaction copies under summaries/, --with-handoffs
#   the published handoffs under handoffs/ (an opt-in of its own), each file
#   through the identity and secret scans)
#   report verify --zip FILE
# Exit: 0 written (also when files were withheld) or verified, 1 verify found a problem,
# 3 REFUSED (not --dry-run, and the watch dir or handoff root is refused),
# 64 usage, 70 internal error, 73 output folder not writable. No network, no deletion.
use strict;
use warnings;
use utf8;
use watch::export;

$SIG{__WARN__} = sub { };

my %seed;
$seed{sha256} = \&sha::hex256 if defined &sha::hex256;
my $code = eval { local $SIG{__DIE__}; watch::export::cli([@ARGV], \%seed) };
unless (defined $code) {
    my $e = $@ // '';
    $e =~ s/\n.*//s;
    print STDERR "report: internal error" . ($e =~ /\Areport: ([a-z ]{1,60})\z/ ? " ($1)" : '') . "\n";
    exit 70;
}
exit $code;
