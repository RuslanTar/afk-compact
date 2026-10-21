# AT-WD-09 (A-18): a halt row and no handoff turn. Young (inside the grace period) and the
# mod has not said it skipped: nothing yet. After the grace period, or at once when the mod
# wrote `handoff_skipped` for it: A-18. With `handoff_turn` off there is no wait.
{
    files => [ { path => '$WATCH/$SID.jsonl',
                 jsonl => [ T::row('continue', 100, result => 'halt:thrash', continues_last_hour => 1) ] } ],
    transcript => [ T::prompt(0), T::assistant_text(50) ],
    steps => [
        { call => 'stop', at => 105 },
        { call => 'code', code => sub { my $v = shift; $main::A18_SEEN{young} = scalar @{ watch::io::read_jsonl("$v->{WATCH}/$v->{SID}.alerts.jsonl") || [] } } },
        { call => 'append', path => '$WATCH/$SID.jsonl',
          rows => [ T::row('continue', 1000, result => 'halt:cap', continues_last_hour => 2),
                    T::row('handoff_skipped', 1001, why => 'headroom', ht => undef),
                    T::row('continue', 1100, result => 'halt:2-nonok', continues_last_hour => 3) ] },
        { call => 'stop', at => 1002 },      # row 1: 902 s old; row 2: skipped; row 3: in the future, young
        { call => 'code', code => sub { my $v = shift; $main::A18_SEEN{after} = join(',', sort map { $_->{evidence}{result} } grep { ($_->{rule} // '') eq 'A-18' } @{ watch::io::read_jsonl("$v->{WATCH}/$v->{SID}.alerts.jsonl") }) } },
        { call => 'stop', at => 1105, ctx => { settings => { handoff_turn => 'off' } } },   # row 3 at once
    ],
    expect => sub {
        my ($E) = @_;
        $E->is($main::A18_SEEN{young}, 0, 'a young halt row, no skip row: nothing yet');
        $E->is($main::A18_SEEN{after}, 'halt:cap,halt:thrash', 'after the grace period, and for the skipped one');
        my @a = $E->alerts('A-18');
        $E->count(\@a, 3, 'handoff_turn off: the third halt row at once');
    },
};
