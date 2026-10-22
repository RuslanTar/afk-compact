# cmd/publish.pl: `publish` subcommand (BUILD-PLAN §3.1). Owner: WP-skills.
# The logic lives in lib/skills/publish.pm; exit codes per §3.1 (0, 3, 64, 70).
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::publish;

exit skills::cli::main('publish', \&skills::publish::run, @ARGV);
