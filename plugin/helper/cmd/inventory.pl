# cmd/inventory.pl: `inventory` subcommand.
# The logic lives in lib/skills/inventory.pm; exit codes 0, 3, 64, 70.
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::inventory;

exit skills::cli::main('inventory', \&skills::inventory::run, @ARGV);
