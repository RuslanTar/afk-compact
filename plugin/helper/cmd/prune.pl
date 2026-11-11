# cmd/prune.pl: `prune` subcommand (0.1.6). User-run, and the prune skill's
# dry run and apply. The logic lives in lib/skills/prune.pm; exit codes 0, 3, 64, 70.
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::prune;

exit skills::cli::main('prune', \&skills::prune::run, @ARGV);
