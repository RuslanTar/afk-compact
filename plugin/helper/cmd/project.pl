# cmd/project.pl: `project status|init|copy` subcommand (D-12 §1.5.8-1.5.9, DP-5;
# BUILD-PLAN §3.1). Owner: WP-skills. The logic lives in lib/skills/project_cmd.pm; exit
# codes per §3.1 (0, 3, 64, 70).
use strict;
use warnings;
use skills::cli;
use skills::project_cmd;

exit skills::cli::main('project', \&skills::project_cmd::run, @ARGV);
