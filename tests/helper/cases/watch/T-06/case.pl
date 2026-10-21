# T-06 (WATCH §9): 4 compactions, 1 copy note -> A-01 x3. (`save_gap` as an
# aggregate is W13, deferred.)
my @t;
for my $i (0 .. 3) {
    my $at = 100 + 400 * $i;
    push @t, T::prompt($at - 50), T::prompt($at - 40), T::prompt($at - 30), T::assistant_text($at - 20),
             T::boundary($at, trigger => 'auto', preTokens => 450000), T::summary($at + 0.1);
}
{
    files => [ { path => '$WATCH/$SID.classic.jsonl',
                 jsonl => [ T::row('copy', 101, writer => 'classic', result => 'saved', slot => 'main', nonce => undef,
                                   rel_path => 'repo/general/compact/x.md') ] } ],
    transcript => \@t,
    steps => [ { call => 'stop', at => 1500 } ],
    expect => sub {
        my ($E) = @_;
        my @a = $E->alerts('A-01');
        $E->count(\@a, 3, 'A-01 for each compaction without a copy');
        $E->is(scalar(grep { $_->{severity} eq 'critical' } @a), 3, 'A-01 is critical');
        my @b = $E->boundaries;
        $E->count(\@b, 4, 'four boundaries');
        $E->is($b[0]{copy}, 'saved', 'the first compaction has its copy');
        $E->is(scalar(grep { $_->{copy} eq 'missing' } @b), 3, 'three copies missing');
    },
};
