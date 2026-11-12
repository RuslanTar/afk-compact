# T-24: the transcript basename is unchanged but the path
# moved after --resume, and the stored offset is beyond the new file's size ->
# the sweep restarts that file at 0; no duplicate boundary (dedupe by uuid).
my $b1 = T::boundary(100, trigger => 'manual', uuid => 'u-b1-t24');
my @pad = map { T::prompt($_) } 1 .. 30;
{
    transcript => [ @pad, T::assistant_text(40), $b1, T::summary(100.1), T::prompt(110) ],
    steps => [
        { call => 'stop', at => 120 },
        { call => 'write', path => '$TMP/moved/$SID.jsonl',
          jsonl => [ $b1, T::summary(100.1), T::prompt(300), T::assistant_text(305),
                     T::boundary(400, trigger => 'manual', uuid => 'u-b2-t24'), T::summary(400.1) ] },
        { call => 'stop', at => 500, transcript => '$TMP/moved/$SID.jsonl' },
    ],
    expect => sub {
        my ($E) = @_;
        my @sw = $E->rows('classic', 'sweep');
        $E->count(\@sw, 2, 'two sweep rows');
        $E->is($sw[1]{restarted}, 1, 'second sweep restarted');
        $E->is($sw[1]{from_off}, 0, 'from offset 0');
        my @u = map { $_->{uuid} } $E->boundaries;
        $E->is(join(',', @u), 'u-b1-t24,u-b2-t24', 'each boundary once');
    },
};
