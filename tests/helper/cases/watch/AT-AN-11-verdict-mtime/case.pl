# AT-AN-11 (0.1.3 alert noise): without a session id the verdict picks the
# sessions by their rollup stream's time (compactions.jsonl), not the session folder's, which
# changes only when an entry is added: a folder untouched for 10 days whose rollup got two rows
# today counts them.
my $now = 30 * 86400;
my %got;
{
    files => [ { path => '$WATCH/5b5c3d4e-0000-4000-8000-00000000c0de/compactions.jsonl',
                 jsonl => [ map { T::row('compaction', $now - 3600 + $_, writer => 'helper', actor => 'main', nonce => "5d5e000$_",
                                         trigger => 'auto', copy => 'saved') } 1, 2 ] } ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              my $d = "$v->{WATCH}/5b5c3d4e-0000-4000-8000-00000000c0de";
              utime($T::BASE + $now - 3600, $T::BASE + $now - 3600, "$d/compactions.jsonl");
              utime($T::BASE + $now - 10 * 86400, $T::BASE + $now - 10 * 86400, $d);
              $got{v} = watch::verdict_line(undef, { watch => $v->{WATCH}, root => $v->{ROOT}, plugin_root => $v->{PLUGIN},
                                                     settings => {}, now => $T::BASE + $now });
          } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->is($got{v}, 'ok: 2/2 compactions saved in the last 7 days, no open alerts', 'the rollup rows count');
    },
};
