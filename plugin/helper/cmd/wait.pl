# cmd/wait.pl: `wait` subcommand (Dev-7 D2, BUILD-PLAN §3.1). Owner: WP-skills.
# The logic lives in lib/skills/wait.pm. Exit codes: 0 done · 10 pending · 11 stalled ·
# 12 ended · 13 overdue · 3 REFUSED · 64 usage · 70 internal (an overrun past --max).
use strict;
use warnings;
use utf8;
use skills::cli;
use skills::wait;

exit skills::cli::main('wait', \&skills::wait::run, @ARGV);
