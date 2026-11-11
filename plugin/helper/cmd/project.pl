# cmd/project.pl: `project status|init|copy` subcommand. The logic lives in
# lib/skills/project_cmd.pm; exit codes 0, 3, 64, 70.
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::project_cmd;

exit skills::cli::main('project', \&skills::project_cmd::run, @ARGV);
