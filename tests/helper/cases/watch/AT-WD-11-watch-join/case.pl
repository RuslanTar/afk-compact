# AT-WD-11, watcher half (PKG-RUNTIME E.2; BUILD-ROUND-9 WCH-05): the watcher reads core's
# `compaction_boundary` rows from the rollup stream and joins them to the rollup row by
# nonce. A null rollup size takes the boundary value; a non-null rollup value is kept and
# the disagreement is a counted `join_conflict`; a repeated boundary row for a nonce adds
# nothing; a boundary row is never taken as a rollup row. A rule that reads `pre` (A-05)
# uses the joined size when no transcript boundary was swept (the P-only path).
my ($na, $nb, $nc) = ('ab000011', 'ab000012', 'ab000013');
my @roll = (
    T::row('compaction', 10, writer => 'helper', nonce => $na, id6 => 'aaaaaa', copy => 'saved',
           pre_tokens => undef, post_tokens => undef, duration_ms => undef, precomputed => undef),
    T::row('compaction_boundary', 11, writer => 'helper', nonce => $na, id6 => 'aaaaaa', boundary_uuid => 'b-a',
           pre_tokens => 790000, post_tokens => 41000, duration_ms => 31000, precomputed => \0),
    T::row('compaction_boundary', 12, writer => 'helper', nonce => $na, id6 => 'aaaaaa', boundary_uuid => 'b-a2',
           pre_tokens => 1, post_tokens => 1, duration_ms => 1, precomputed => \1),
    T::row('compaction', 20, writer => 'helper', nonce => $nb, id6 => 'bbbbbb', copy => 'saved',
           pre_tokens => 450000, post_tokens => undef, duration_ms => undef, precomputed => \0),
    T::row('compaction_boundary', 21, writer => 'helper', nonce => $nb, id6 => 'bbbbbb', boundary_uuid => 'b-b',
           pre_tokens => 460000, post_tokens => 42000, duration_ms => 32000, precomputed => \0),
    T::row('compaction_boundary', 30, writer => 'helper', nonce => $nc, id6 => 'cccccc', boundary_uuid => 'b-c',
           pre_tokens => 300000, post_tokens => 30000, duration_ms => 20000, precomputed => \0),
);
my %got;
{
    settings => { native_window_tokens => 800000 },
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    files => [
        { path => '$WATCH/$SID/compactions.jsonl', jsonl => \@roll },
        { path => "\$WATCH/\$SID/dispatch/$na.json", json => T::dispatch($na, 9) },
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('postcompact', 10, writer => 'classic', nonce_found => $na, scope_found => 'main',
                            verdict => 'ok', trigger => 'auto') ] },
    ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              require watch::rules;
              my $ctx = watch::ctx::init({ sid => $T::SID, watch => $v->{WATCH}, root => $v->{ROOT},
                                           plugin_root => $v->{PLUGIN}, settings => {}, now => $T::BASE + 400 });
              my $S = watch::rules::load_session($ctx);
              %got = (S => $S);
          } },
        { call => 'stop', at => 400 },
    ],
    expect => sub {
        my ($E) = @_;
        my $S = $got{S};
        my $a = $S->{rollup}{$na};
        $E->is($a->{pre_tokens}, 790000, 'null rollup pre_tokens takes the boundary value');
        $E->is($a->{post_tokens}, 41000, 'post_tokens joined');
        $E->is($a->{duration_ms}, 31000, 'duration_ms joined');
        $E->is($a->{boundary_uuid}, 'b-a', 'the first boundary row for the nonce counts');
        $E->ok((!$a->{_join_conflict} ? 1 : 0), 'no conflict when the rollup was null');
        my $b = $S->{rollup}{$nb};
        $E->is($b->{pre_tokens}, 450000, 'a non-null rollup value is never replaced');
        $E->is($b->{post_tokens}, 42000, 'the null fields of the same row are filled');
        $E->is(join(',', @{ $b->{_join_conflict} || [] }), 'pre_tokens', 'the disagreement is named');
        $E->is($S->{join_conflict}, 1, 'one join_conflict counted');
        $E->ok((!exists $S->{rollup}{$nc} ? 1 : 0), 'a boundary row alone is not a rollup row');
        $E->is($S->{boundary}{$nc}{pre_tokens}, 300000, 'the lone boundary row is kept by nonce');
        $E->is($S->{rollup}{$na}{ev}, 'compaction', 'the rollup row was not overwritten by a boundary row');
        my @a5 = $E->alerts('A-05');
        $E->count(\@a5, 1, 'A-05 from the joined size on the P-only path');
        $E->is($a5[0]{evidence}{tokens_before}, 790000, 'A-05 tokens_before from the join') if @a5;
        $E->is($a5[0]{evidence}{source}, 'rollup', 'A-05 names the rollup source') if @a5;
        $E->is($a5[0]{evidence}{band_position}, 'at-native', '790K at the 800K window') if @a5;
    },
};
