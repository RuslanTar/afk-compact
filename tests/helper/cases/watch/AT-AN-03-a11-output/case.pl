# AT-AN-03 (0.1.3 alert noise item 1): A-11 checks only an item with a known output path. On
# 0.1.2 every item without one was "quiet" (107 of 107 A-11 rows false: teammates, workflows,
# subagents, monitors, and shells whose path the result text did not give); such an item now
# raises nothing. A shell whose output file has not moved for 15 min still raises A-11 (the
# true case); one whose file moved 1 min ago does not.
my $stop = 7200;
{
    settings => { stall_min => 60 },
    transcript => [ T::prompt(0), T::assistant_text(5) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              my $bg = "$v->{WATCH}/$T::SID/bg";
              watch::io::mkdir_p($bg);
              my %out = (old => "$v->{TMP}/out-old.output", new => "$v->{TMP}/out-new.output");
              for my $k (keys %out) {
                  open(my $fh, '>', $out{$k}) or die; print $fh "x\n"; close $fh;
              }
              utime($T::BASE + $stop - 3600, $T::BASE + $stop - 3600, $out{old});
              utime($T::BASE + $stop - 60, $T::BASE + $stop - 60, $out{new});
              my @tasks = ({ id => 'tm-1', type => 'teammate', status => 'running', output_path => undef },
                           { id => 'wf-1', type => 'workflow', status => 'running', output_path => undef },
                           { id => 'sh-u', type => 'shell', status => 'running', output_path => undef },
                           { id => 'sh-old', type => 'shell', status => 'running', output_path => $out{old} },
                           { id => 'sh-new', type => 'shell', status => 'running', output_path => $out{new} });
              for my $k (0, 1) {
                  my $p = "$bg/slot-$k.json";
                  open(my $fh, '>', $p) or die;
                  print $fh watch::json::encode({ v => 1, ts => T::loc($k ? $stop - 60 : 0), set_hash => "h$k", tasks => \@tasks }), "\n";
                  close $fh;
              }
          } },
        { call => 'stop', at => $stop },
    ],
    expect => sub {
        my ($E) = @_;
        my @a = $E->alerts('A-11');
        my %id = map { ($_->{alert_id} => 1) } @a;
        my $has = sub { $id{ watch::alerts::alert_id('A-11', $T::SID, $_[0]) } ? 1 : 0 };
        $E->count(\@a, 1, 'one A-11');
        $E->is($has->('sh-old'), 1, 'the shell whose output has not moved for an hour');
        $E->is($a[0]{evidence}{output_known}, 1, 'its output path is known') if @a;
        $E->is($a[0]{evidence}{minutes}, 120, 'listed running for 120 min') if @a;
        $E->is($has->('sh-new') + $has->('tm-1') + $has->('wf-1') + $has->('sh-u'), 0,
               'none for a moving output or an item with no known output path');
    },
};
