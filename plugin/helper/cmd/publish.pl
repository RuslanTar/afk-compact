# cmd/publish.pl: `publish` subcommand.
# The logic lives in lib/skills/publish.pm; exit codes 0, 3, 64, 70.
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::publish;

exit skills::cli::main('publish', \&skills::publish::run, @ARGV);
