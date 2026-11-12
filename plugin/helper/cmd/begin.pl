# cmd/begin.pl: `begin` subcommand.
# The logic lives in lib/skills/begin.pm; exit codes 0, 3, 64, 70.
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::begin;

exit skills::cli::main('begin', \&skills::begin::run, @ARGV);
