# AT-AN-10 (0.1.3 alert noise, root decision 3): a background shell with no recorded output path
# has the file Claude Code writes for it, <tmp>/claude-<uid>/<project>/<sid>/tasks/<id>.output
# (<project>: the folder of the session's transcript). A-11 checks that file when it exists: one
# that has not moved for an hour raises A-11 (source derived), one that moved a minute ago does
# not, a shell with no such file is skipped as before, and so is a teammate even with a file of
# that name.
my $stop = 7200;
{
    settings => { stall_min => 60 },
    transcript => [ T::prompt(0), T::assistant_text(5) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              my $bg = "$v->{WATCH}/$T::SID/bg";
              watch::io::mkdir_p($bg);
              my $dir = "$v->{TMP}/cctmp/claude-$</-synthetic-proj/$T::SID/tasks";
              watch::io::mkdir_p($dir);
              for my $id (qw(sh-old sh-new tm-1)) {
                  open(my $fh, '>', "$dir/$id.output") or die; print $fh "x\n"; close $fh;
                  my $t = $id eq 'sh-new' ? $T::BASE + $stop - 60 : $T::BASE + $stop - 3600;
                  utime($t, $t, "$dir/$id.output");
              }
              my @tasks = map { { id => $_, type => ($_ =~ /\Atm/ ? 'teammate' : 'shell'), status => 'running', output_path => undef } }
                          qw(sh-old sh-new sh-none tm-1);
              for my $k (0, 1) {
                  open(my $fh, '>', "$bg/slot-$k.json") or die;
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
        $E->is($has->('sh-old'), 1, 'the shell whose task output file has not moved for an hour');
        $E->is($a[0]{evidence}{source}, 'derived', 'its path derived from the task id') if @a;
        $E->is($has->('sh-new') + $has->('sh-none') + $has->('tm-1'), 0,
               'none for a moving file, a shell with no file, or a teammate');
    },
};
