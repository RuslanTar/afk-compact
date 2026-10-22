# cmd/restore-evidence.pl: `restore-evidence` subcommand (BUILD-PLAN §3.1). Owner: WP-skills.
# The logic lives in lib/skills/restore.pm; exit codes per §3.1 (0, 3, 64, 70).
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::restore;

exit skills::cli::main('restore-evidence', \&skills::restore::restore, @ARGV);
