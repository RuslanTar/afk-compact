# cmd/heal-check.pl: `heal-check` subcommand.
# The logic lives in lib/skills/heal.pm; exit codes 0, 3, 64, 70.
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::heal;

exit skills::cli::main('heal-check', \&skills::heal::run, @ARGV);
