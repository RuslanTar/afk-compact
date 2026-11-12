# Keep-warm statistics, 0.1.11 (export schema): a `cache_after_gap` row exports its counts, times
# and classes as given; a result or miss reason outside the known lists exports as `other`, and a
# field the schema does not list is dropped and counted. Rows are given as the watcher reads them.
my %got;
my @rows = (
    { ev => 'cache_after_gap', resp_ts => '2026-11-12T15:00:05.000+03:00', gap_s => 3600, result => 'hit', cache_read => 228161,
      cache_creation => 450, input => 3, miss_reason => 'none' },
    { ev => 'cache_after_gap', resp_ts => '2026-11-12T16:00:00.000+03:00', gap_s => 3550, result => 'miss', cache_read => 25289,
      cache_creation => 234319, input => 3, miss_reason => 'previous_message_not_found', missed_tokens => 234319 },
    { ev => 'cache_after_gap', resp_ts => 'yesterday', gap_s => 'long', result => 'lukewarm', cache_read => 0,
      cache_creation => 0, input => 250000, miss_reason => 'CANARY-TEXT-reason', prompt => 'CANARY-TEXT-prompt' },
    { ev => 'cache_after_gap', resp_ts => '2026-11-12T17:00:00.000+03:00', gap_s => 3900, result => 'none', cache_read => 0,
      cache_creation => 0, input => 250000, miss_reason => 'not-reported' },
);
{
    steps => [
        { call => 'code', code => sub {
              require watch::export;
              my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
              $got{out} = [ map { watch::export::transform_row({ v => 1, ts => '2026-11-12T18:00:00.000+03:00', sid => $T::SID,
                                                                 actor => 'main', writer => 'classic', %$_ }, $X) } @rows ];
              $got{dropped} = $X->{dropped};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = @{ $got{out} };
        $E->is(join(',', map { "$_=$got{dropped}{$_}" } sort keys %{ $got{dropped} }),
               'cache_after_gap.gap_s=1,cache_after_gap.prompt=1,cache_after_gap.resp_ts=1', 'only the bad values and the unknown field dropped');
        $E->is(join(',', map { $o[0]{$_} } qw(resp_ts gap_s result cache_read cache_creation input miss_reason)),
               '2026-11-12T15:00:05.000+03:00,3600,hit,228161,450,3,none', 'a hit exports as given');
        $E->is(join(',', map { $o[1]{$_} } qw(result miss_reason missed_tokens)), 'miss,previous_message_not_found,234319', 'a miss with its reason');
        $E->is(join(',', map { $o[2]{$_} // '-' } qw(result miss_reason resp_ts gap_s)), 'other,other,-,-', 'unknown classes: other');
        $E->is(join(',', map { $o[3]{$_} } qw(result miss_reason)), 'none,not-reported', 'no cache tokens, no reason reported');
        $E->ok((index(join('', map { watch::json::encode($_) } @o), 'CANARY') < 0) ? 1 : 0, 'no text in the export');
    },
};
