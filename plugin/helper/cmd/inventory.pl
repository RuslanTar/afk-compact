# cmd/inventory.pl: `inventory` subcommand (BUILD-PLAN §3.1). Owner: WP-skills.
# The logic lives in lib/skills/inventory.pm; exit codes per §3.1 (0, 3, 64, 70).
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::inventory;

exit skills::cli::main('inventory', \&skills::inventory::run, @ARGV);
