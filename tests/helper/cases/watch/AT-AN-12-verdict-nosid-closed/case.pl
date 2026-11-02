# AT-AN-12 (0.1.3 alert noise, root decision 1): a closed alert (an `alert_closed` row after it in
# the same log) is not open anywhere it is counted: the verdict without a session id (every
# session's last 7 days) and `watch report`'s alert counts leave it out; the open one stays.
my $SID2 = '6b6c3d4e-0000-4000-8000-00000000c0de';
my ($open, $closed) = map { watch::alerts::alert_id('A-11', $SID2, $_) } qw(b0000open b000close);
my $a = sub { my ($id) = @_; return { %{ T::row('alert', 500, writer => 'classic', alert_id => $id, rule => 'A-11', severity => 'warn',
                                                  key => { session_id => $SID2 }, evidence => { output_known => \0, minutes => 70 }) },
                                      sid => $SID2, plugin_version => '0.1.2' } };
my %got;
{
    files => [
        { path => "\$WATCH/$SID2.alerts.jsonl",
          jsonl => [ $a->($open), $a->($closed),
                     { %{ T::row('alert_closed', 600, writer => 'classic', alert_id => $closed, rule => 'A-11',
                                 reason => 'superseded: rule changed in 0.1.3') }, sid => $SID2 } ] },
        { path => "\$WATCH/$SID2.classic.jsonl", jsonl => [ { %{ T::row('config_note', 1, writer => 'helper', key => 'k', note => 'n') }, sid => $SID2 } ] },
    ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              my $ctx = { watch => $v->{WATCH}, root => $v->{ROOT}, plugin_root => $v->{PLUGIN}, settings => {}, now => $T::BASE + 900 };
              $got{v} = watch::verdict_line(undef, { %$ctx });
              require watch::report;
              my $s = watch::report::stats(watch::report::load(watch::ctx::init({ %$ctx })));
              $got{report} = $s->{alerts}{'A-11'};
              $got{n} = $s->{alerts_n};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->is($got{v}, 'attention: 1 open alert (A-11); no compactions in the last 7 days', 'the verdict counts the open one');
        $E->is($got{report}, 1, 'watch report counts the open A-11 only');
        $E->is($got{n}, 1, 'and one alert in all');
    },
};
