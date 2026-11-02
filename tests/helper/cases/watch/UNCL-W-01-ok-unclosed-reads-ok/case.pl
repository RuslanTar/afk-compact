# UNCL-W-01 (0.1.3 ok-unclosed): two main compactions in a row whose summaries are complete but for
# the closing line read ok to the watcher's rules: no A-02 (a bad verdict), their resume blocks
# without the non-ok note raise no A-23 nonok_note_missing, and a continue after the two is no
# continue after a halt condition (A-19). Before 0.1.3 the watcher read such a verdict as non-ok.
my ($n1, $n2) = ('0c1a0001', '0c1a0002');
my $body = sub { my $b = T::main_body(nonce => $_[0]); $b =~ s{^\xe2\x9f\xaa/[^\n]*\n}{}m; $b };
my $pc = sub {
    my ($n, $at) = @_;
    my $b = $body->($n);
    return { call => 'hook', event => 'PostCompact', at => $at, payload => { trigger => 'auto', compact_summary => $b },
             ctx => { detect => { verdict => 'ok-unclosed', nonce => $n, scope => 'main', marker_line => 1, sentinel_from_end => undef,
                                  normalized => $b } } };
};
{
    files => [
        { path => "\$WATCH/\$SID/dispatch/$n1.json", json => T::dispatch($n1, 99) },
        { path => "\$WATCH/\$SID/dispatch/$n2.json", json => T::dispatch($n2, 499) },
        { path => '$WATCH/$SID.jsonl',
          jsonl => [ T::row('resume_inject', 102, nonce => $n1, channel => 'prompt.context', bytes => 3000, nonok_note => \0),
                     T::row('resume_inject', 502, nonce => $n2, channel => 'prompt.context', bytes => 3000, nonok_note => \0) ] },
    ],
    transcript => [
        T::prompt(0), T::bash(2, 'make', id => 'toolu_1'), T::result(3, 'toolu_1'),
        T::boundary(100, trigger => 'auto'), T::summary(100.1),
        T::continue_row(110), T::assistant_text(115),
        T::prompt(200), T::prompt(300), T::prompt(400),
        T::boundary(500, trigger => 'auto'), T::summary(500.1),
        T::continue_row(510), T::assistant_text(515),
    ],
    steps => [ $pc->($n1, 101), $pc->($n2, 501), { call => 'stop', at => 600 } ],
    expect => sub {
        my ($E) = @_;
        $E->count([ $E->alerts('A-02') ], 0, 'no A-02: ok-unclosed is no bad verdict');
        $E->count([ grep { $_->{evidence}{nonok_note_missing} } $E->alerts('A-23') ], 0, 'no A-23 nonok_note_missing: ok-unclosed needs no non-ok note');
        $E->count([ grep { $_->{evidence}{continue_after_halt_cond} } $E->alerts('A-19') ], 0, 'no A-19: two ok-unclosed verdicts are no halt condition');
        my @b = $E->boundaries;
        $E->is(scalar(@b), 2, 'both compactions seen');
    },
};
