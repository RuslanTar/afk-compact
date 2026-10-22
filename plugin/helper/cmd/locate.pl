# cmd/locate.pl: `locate` subcommand (BUILD-PLAN §3.1). Owner: WP-skills.
# The logic lives in lib/skills/locate.pm; exit codes per §3.1 (0, 3, 64, 70).
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::locate;

exit skills::cli::main('locate', \&skills::locate::run, @ARGV);
