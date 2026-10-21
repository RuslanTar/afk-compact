# cmd/evidence.pl: `evidence` subcommand (BUILD-PLAN §3.1). Owner: WP-skills.
# The logic lives in lib/skills/evidence_cmd.pm; exit codes per §3.1 (0, 3, 64, 70).
use strict;
use warnings;
use skills::cli;
use skills::evidence_cmd;

exit skills::cli::main('evidence', \&skills::evidence_cmd::run, @ARGV);
