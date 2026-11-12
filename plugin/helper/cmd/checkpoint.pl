# cmd/checkpoint.pl: `checkpoint --sid S --nonce N --budget-ms 10000 [--measured]
# [--cwd DIR] [--transcript PATH]` -> one JSON line <= 6 KB.
use strict;
use warnings;
use utf8;

package cmd_checkpoint;

sub run {
    my ($opt) = args::parse(\@_, bools => ['measured'],
                            known => [qw(sid nonce budget-ms cwd transcript root log-dir disposable-root queue-cmd quota-mb)]);
    my $sid = args::init_sid($opt);
    args::need($opt, 'nonce');
    die "usage: --nonce is 8 lowercase hex\n" unless nonce::valid($opt->{nonce});
    my $budget = $opt->{'budget-ms'} // 10000;
    die "usage: --budget-ms is a number\n" unless $budget =~ /^\d+$/;
    $budget = 10000 if $budget > 10000;
    my ($json) = checkpoint::run(sid => $sid, nonce => $opt->{nonce}, budget_ms => $budget, measured => $opt->{measured},
                                 cwd => $opt->{cwd} // do { require Cwd; Cwd::getcwd() }, transcript => $opt->{transcript});
    print STDOUT $json, "\n";
    return 0;
}

exit(args::main(\&run, @ARGV));
