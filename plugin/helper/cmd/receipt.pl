# cmd/receipt.pl: `receipt` subcommand (BUILD-PLAN §3.1). Owner: WP-skills.
# The logic lives in lib/skills/session_cmds.pm; exit codes per §3.1 (0, 3, 64, 70).
use strict;
use warnings;
use skills::cli;
use skills::session_cmds;

exit skills::cli::main('receipt', \&skills::session_cmds::receipt, @ARGV);
