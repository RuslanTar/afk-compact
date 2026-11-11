# cmd/stamp.pl: `stamp` subcommand.
# The logic lives in lib/skills/stamp.pm; exit codes 0, 3, 64, 70.
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::stamp;

exit skills::cli::main('stamp', \&skills::stamp::run, @ARGV);
