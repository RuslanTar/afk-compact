# F2-4: PostCompact looks up the
# previous saved copy (M-11) from the `copy` rows of both streams, and decodes
# only those lines: a long session's other rows are skipped before the JSON
# decode. The copy row is still found (ledger_src copy).
my $n = '4e4e0001';
my @noise_c = map { T::row('measure', 1 + $_ / 100, writer => 'classic', note => 'n' x 200) } 1 .. 300;
my @noise_m = map { T::row('skip', 1 + $_ / 100, why => 'cooldown') } 1 .. 300;
my $prev = T::main_body(nonce => '4e4e0000', U => ['U-1 "CANARY-TEXT-keep"', 'U-2 "CANARY-TEXT-old"']);
my $body = T::main_body(nonce => $n);
my $decode = \&watch::json::decode;
my $calls;
{
    files => [
        { path => "\$WATCH/\$SID/dispatch/$n.json", json => T::dispatch($n, 8) },
        { path => '$ROOT/compact/2026-10-21_1b2c3d4e_c1-4e4e00.md', text => "---\nkind: compaction\n---\n$prev" },
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ @noise_c, T::row('copy', 5, writer => 'classic', nonce => '4e4e0000', result => 'saved', slot => 'main',
                                      rel_path => 'compact/2026-10-21_1b2c3d4e_c1-4e4e00.md') ] },
        { path => '$WATCH/$SID.jsonl', jsonl => \@noise_m },
    ],
    steps => [
        { call => 'code', code => sub {
              no warnings 'redefine';
              *watch::json::decode = sub { $calls++; goto &$decode };
          } },
        { call => 'hook', event => 'PostCompact', at => 13, payload => { trigger => 'auto', compact_summary => $body },
          ctx => { detect => { verdict => 'ok', nonce => $n, scope => 'main', marker_line => 1, sentinel_from_end => 1,
                               normalized => $body } } },
        { call => 'code', code => sub {
              no warnings 'redefine';
              *watch::json::decode = $decode;
          } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->ok(defined $calls && $calls < 20, 'PostCompact decoded ' . ($calls // 'undef') . ' JSON texts, not the 600 stream rows');
        my ($p) = $E->rows('classic', 'postcompact');
        $E->is($p->{ledger}{ledger_src}, 'copy', 'the previous copy was found from its copy row');
        $E->is($p->{ledger}{lost_U}, 1, 'and compared (U-2 lost)');
    },
};
