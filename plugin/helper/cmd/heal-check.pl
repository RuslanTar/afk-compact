# cmd/heal-check.pl: `heal-check` subcommand (BUILD-PLAN §3.1). Owner: WP-skills.
# The logic lives in lib/skills/heal.pm; exit codes per §3.1 (0, 3, 64, 70).
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::heal;

exit skills::cli::main('heal-check', \&skills::heal::run, @ARGV);
