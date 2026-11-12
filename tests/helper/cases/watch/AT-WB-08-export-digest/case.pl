# Export schema, away digest: a digest_submit row exports its result as given when it
# is one of the schema's values, `skipped:off` (idle_digest off, the default of 0.1.1, rule
# (c)) and `skipped:return` among them, and as `other` when it is not. Its lane exports the same
# way. Rows are given as the watcher reads them.
my %got;
my @res = qw(submitted skipped:return skipped:off skipped:running skipped:disabled);
my @rows = (
    (map { { ev => 'digest_submit', lane => 'finished', result => $_ } } @res),
    { ev => 'digest_submit', lane => 'hard-blocked', result => 'skipped:sideways' },
    { ev => 'digest_submit', lane => 'sideways', result => 'skipped:off' },
);
{
    steps => [
        { call => 'code', code => sub {
              require watch::export;
              my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
              $got{out} = [ map { watch::export::transform_row({ v => 1, ts => '2026-10-30T04:00:00.000+02:00', sid => $T::SID,
                                                                 actor => 'main', writer => 'mod', %$_ }, $X) } @rows ];
              $got{dropped} = $X->{dropped};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = @{ $got{out} };
        my $n = scalar @res;
        $E->is(join(',', map { "$_=$got{dropped}{$_}" } sort keys %{ $got{dropped} }), '', 'nothing dropped');
        $E->is(join(',', map { $o[$_]{result} } 0 .. $n - 1), join(',', @res), 'the known results export as given');
        $E->is($o[2]{result}, 'skipped:off', 'skipped:off exports as skipped:off, not other');
        $E->is("$o[$n]{lane}/$o[$n]{result}", 'hard-blocked/other', 'an unknown result exports as other');
        $E->is("$o[$n + 1]{lane}/$o[$n + 1]{result}", 'other/skipped:off', 'an unknown lane exports as other');
    },
};
