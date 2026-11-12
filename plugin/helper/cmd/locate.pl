# cmd/locate.pl: `locate` subcommand.
# The logic lives in lib/skills/locate.pm; exit codes 0, 3, 64, 70.
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::locate;

exit skills::cli::main('locate', \&skills::locate::run, @ARGV);
