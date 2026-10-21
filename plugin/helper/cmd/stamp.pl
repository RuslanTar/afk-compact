# cmd/stamp.pl: `stamp` subcommand (BUILD-PLAN §3.1). Owner: WP-skills.
# The logic lives in lib/skills/stamp.pm; exit codes per §3.1 (0, 3, 64, 70).
use strict;
use warnings;
use skills::cli;
use skills::stamp;

exit skills::cli::main('stamp', \&skills::stamp::run, @ARGV);
