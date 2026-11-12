# cmd/evidence.pl: `evidence` subcommand.
# The logic lives in lib/skills/evidence_cmd.pm; exit codes 0, 3, 64, 70.
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::evidence_cmd;

exit skills::cli::main('evidence', \&skills::evidence_cmd::run, @ARGV);
