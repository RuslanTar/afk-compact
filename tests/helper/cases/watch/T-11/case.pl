# T-11: a chain where n-1 has D-7 and n has neither D-7 nor a
# Superseded:/fold line -> lost_D 1; A-09 warn. D-8 is named in a fold line
# and D-9 in a range "D-9..D-10" (a range folds nothing) but D-9 stays
# listed, so only D-7 is lost. The previous summary is read from its saved copy.
my ($n1, $n2) = ('f0f00011', 'f0f00012');
my $prev = "---\nkind: compact-summary\n---\n"
         . T::main_body(nonce => $n1, D => ['D-7 keep the cache ' . "\xe2\x80\x94" . ' because CANARY-TEXT-a',
                                             'D-8 use rsync ' . "\xe2\x80\x94" . ' because CANARY-TEXT-b',
                                             'D-9 stay on main ' . "\xe2\x80\x94" . ' because CANARY-TEXT-c']);
my $cur = T::main_body(nonce => $n2, D => ['D-9 stay on main ' . "\xe2\x80\x94" . ' because CANARY-TEXT-c',
                                           'D-8 settled; full text in compact/x_c1.md',
                                           'D-9..D-10 settled; full text in compact/x_c1.md']);
my $rel = 'repo/general/compact/2026-10-21_13-50-00_1b2c3d4e_c1-f0f000.md';
{
    files => [
        { path => "\$WATCH/\$SID/dispatch/$n2.json", json => T::dispatch($n2, 8) },
        { path => "\$ROOT/$rel", text => $prev, mode => 0400 },
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('copy', -600, writer => 'classic', result => 'saved', slot => 'main', nonce => $n1, rel_path => $rel) ] },
    ],
    transcript => [ T::prompt(0), T::bash(2, 'ls', id => 'toolu_1'), T::result(3, 'toolu_1'),
                    T::boundary(10, trigger => 'auto'), T::summary(10.1) ],
    steps => [
        { call => 'hook', event => 'PostCompact', at => 11, payload => { trigger => 'auto', compact_summary => $cur },
          ctx => { detect => { verdict => 'ok', nonce => $n2, scope => 'main', marker_line => 1, sentinel_from_end => 1,
                               normalized => $cur } } },
        { call => 'stop', at => 30 },
    ],
    expect => sub {
        my ($E) = @_;
        my ($p) = $E->rows('classic', 'postcompact');
        $E->is($p->{ledger}{ledger_src}, 'copy', 'previous summary from the saved copy');
        $E->is($p->{ledger}{lost_D}, 1, 'D-7 lost');
        $E->is($p->{ledger}{lost_U}, 0, 'no U lost');
        $E->is($p->{ledger}{folded}, 1, 'D-8 folded by name; the range folds nothing');
        my @a = $E->alerts('A-09');
        $E->count(\@a, 1, 'A-09');
        $E->is($a[0]{severity}, 'warn', 'lost D is warn');
    },
};
