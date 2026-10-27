# AT-MG-03 (root ruling 2026-10-27 23:16): the cold test of a compaction is the prefix read,
# cache_read / (cache_read + cache_creation), and the input outside the cache is logged apart.
# compaction_cache exports nonce, prefix_read and uncovered; compaction_cold exports nonce and
# prefix_read; rows of an older version keep their read_share. A-28 names the prefix read of a
# cold compaction (the read share of an older row), and the handoff turn's first-request share as
# before. Rows are given as the watcher reads them.
my %got;
my @rows = (
    { ev => 'compaction_cache', nonce => '1d1e0c0b', prefix_read => 0.925, uncovered => 338700 },
    { ev => 'compaction_cold', nonce => '2d2e0c0b', prefix_read => 0.27 },
    { ev => 'compaction_cache', nonce => '3d3e0c0b', read_share => 0.045 },
    { ev => 'compaction_cold', nonce => '4d4e0c0b', read_share => 0.1 },
    { ev => 'compaction_cache', nonce => '5d5e0c0b', prefix_read => undef, uncovered => 120000 },
);
my @mod = (
    T::row('compaction_cold', 10.4, nonce => '2d2e0c0b', prefix_read => 0.27),
    T::row('compaction_cold', 10.5, nonce => '4d4e0c0b', read_share => 0.1),
);
{
    files => [ { path => '$WATCH/$SID.jsonl', jsonl => \@mod } ],
    steps => [
        { call => 'code', code => sub {
              require watch::export;
              my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
              $got{out} = [ map { watch::export::transform_row({ v => 1, ts => '2026-10-27T23:30:00.000+03:00', sid => $T::SID,
                                                                 actor => 'main', writer => 'mod', %$_ }, $X) } @rows ];
              $got{dropped} = $X->{dropped};
          } },
        { call => 'stop', at => 500 },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = @{ $got{out} };
        my $v = sub { my $x = shift; defined $x ? "<$x>" : 'null' };
        $E->is(join(',', map { "$_=$got{dropped}{$_}" } sort keys %{ $got{dropped} }), '', 'nothing dropped');
        $E->is(join(',', map { $v->($o[0]{$_}) } qw(nonce prefix_read uncovered)), '<1d1e0c0b>,<0.925>,<338700>',
               'compaction_cache: the prefix read and the uncovered input');
        $E->is(join(',', map { $v->($o[1]{$_}) } qw(nonce prefix_read)), '<2d2e0c0b>,<0.27>', 'compaction_cold: the prefix read');
        $E->is($v->($o[2]{read_share}), '<0.045>', 'an older compaction_cache row keeps its read share');
        $E->is($v->($o[3]{read_share}), '<0.1>', 'an older compaction_cold row keeps its read share');
        $E->is(join(',', map { $v->($o[4]{$_}) } qw(prefix_read uncovered)), 'null,<120000>', 'no cache tokens: the prefix read is null');
        my $old = sub { defined $_[0]{evidence}{prefix_read} ? 0 : 1 };
        my @c = sort { $old->($a) <=> $old->($b) } $E->alerts('A-28');
        $E->count(\@c, 2, 'A-28: one per compaction_cold row');
        $E->is(join(',', map { $_->{evidence}{kind} } @c), 'compaction,compaction', 'A-28 kind');
        $E->is(join(',', map { $v->($_->{evidence}{prefix_read}) . '/' . $v->($_->{evidence}{read_share}) } @c),
               '<0.27>/null,null/<0.1>', 'A-28 evidence: the prefix read, or an older row\'s read share');
    },
};
