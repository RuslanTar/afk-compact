package skills::stamp;
# lib/skills/stamp.pm: `stamp --stage DIR` prints a stamp, `YYYY-MM-DD HH:MM ±hhmm`
# (RV-24: always date, time and zone), and appends it to stamps.log, the list of
# times the publish lint accepts as printed by the helper.
use strict;
use warnings;
use skills::util;
use skills::cli;
use skills::stage;

sub run {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'stage=s');
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    my ($dir) = skills::stage::open_stage($o->{stage});
    my $now = skills::util::now();
    my $shown = skills::util::stamp($now);
    skills::util::append_line("$dir/stamps.log", skills::util::iso_local($now) . "\t$shown\n");
    skills::cli::say($shown);
    return 0;
}

1;
