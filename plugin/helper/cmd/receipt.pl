# cmd/receipt.pl: `receipt` subcommand.
# The logic lives in lib/skills/session_cmds.pm; exit codes 0, 3, 64, 70.
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::session_cmds;

exit skills::cli::main('receipt', \&skills::session_cmds::receipt, @ARGV);
