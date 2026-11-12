# cmd/verify.pl: `verify` subcommand.
# The logic lives in lib/skills/restore.pm; exit codes 0, 3, 64, 70.
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::restore;

exit skills::cli::main('verify', \&skills::restore::verify, @ARGV);
