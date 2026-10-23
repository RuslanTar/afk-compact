# cmd/risk.pl: `risk` subcommand (SR-7; BUILD-PLAN §3.1). Owner: WP-skills.
# The logic lives in lib/skills/risk.pm; exit codes per §3.1 (0, 64, 70).
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::risk;

exit skills::cli::main('risk', \&skills::risk::run, @ARGV);
