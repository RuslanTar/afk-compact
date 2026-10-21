package skills::stamp;
# lib/skills/stamp.pm: `stamp --stage DIR` prints HH:MM, or MM-DD HH:MM when
# the day differs from the stage date (RV-24), and appends it to stamps.log.
use strict;
use warnings;
use skills::util;
use skills::cli;
use skills::stage;

sub run {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'stage=s');
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    my ($dir, $s) = skills::stage::open_stage($o->{stage});
    my $now = skills::util::now();
    my $stage_epoch = skills::util::iso_to_epoch($s->{date});
    my $same = defined $stage_epoch && skills::util::ymd($stage_epoch) eq skills::util::ymd($now);
    my $shown = $same ? skills::util::hhmm($now) : skills::util::mmdd_hhmm($now);
    skills::util::append_line("$dir/stamps.log", skills::util::iso_local($now) . "\t$shown\n");
    skills::cli::say($shown);
    return 0;
}

1;
