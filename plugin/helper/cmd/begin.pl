# cmd/begin.pl: `begin` subcommand (BUILD-PLAN §3.1). Owner: WP-skills.
# The logic lives in lib/skills/begin.pm; exit codes per §3.1 (0, 3, 64, 70).
use strict;
use warnings;
use skills::cli;
use skills::begin;

exit skills::cli::main('begin', \&skills::begin::run, @ARGV);
