# cmd/risk.pl: `risk` subcommand.
# The logic lives in lib/skills/risk.pm; exit codes 0, 64, 70.
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::risk;

exit skills::cli::main('risk', \&skills::risk::run, @ARGV);
