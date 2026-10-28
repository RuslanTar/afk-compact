# AT-IC-C42 (watcher half; IDLE-COMPACT-SPEC §1.4, MOD-SPEC §3.4 idle exception): an idle
# compaction's resume block waits on disk for the next turn, which may come in the next process
# (resume-persist), and only prompt.context delivers it. A main Stop that sweeps such a compaction
# before any claim does not raise A-23 count 0: the compaction is held and decided at a later
# Stop. n0, not idle, with no claim: A-23 count 0 at its first Stop. n1, idle: held while its
# record is pending, then armed (a resume), then claimed by prompt.context: no A-23. n2, idle:
# held while pending, then settled undelivered with no claim: A-23 count 0 at the Stop after that.
my ($n0, $n1, $n2) = ('a23d0000', 'a23d0001', 'a23d0002');
my $ok = sub { T::main_body(nonce => $_[0]) };
my $idle = sub { T::dispatch($_[0], $_[1], channel => 'mod-self', trigger => 'plugin', resume_pref => 'prompt.context') };
my $rec = sub { { v => 1, state => $_[1] // 'pending', session_id => $T::SID, nonce => $_[0], built_at => 0, measured_at => 0,
                  load_id => 'L1', args => { nonce => $_[0], midturn => \0, nonok => \0, savedCopy => undef, idle => \1 },
                  remeasure => undef, outcome => { nudged => \0, continued => \0, halt => \0 } } };
my $a23 = sub {
    my ($v) = @_;
    return [ grep { ($_->{ev} // '') eq 'alert' && ($_->{rule} // '') eq 'A-23' }
             @{ watch::io::read_jsonl("$v->{WATCH}/$v->{SID}.alerts.jsonl") } ];
};
my $post = sub {
    my ($n, $t) = @_;
    my $b = $ok->($n);
    return { call => 'hook', event => 'PostCompact', at => $t, payload => { trigger => 'auto', compact_summary => $b },
             ctx => { detect => { verdict => 'ok', nonce => $n, scope => 'main', marker_line => 1, sentinel_from_end => 1,
                                  normalized => $b } } };
};
my $claim = sub {
    my ($n, $t) = @_;
    return ({ call => 'append', path => '$WATCH/$SID.jsonl',
              rows => [ T::row('resume_inject', $t, writer => 'helper', nonce => $n, channel => 'prompt.context', bytes => 3000,
                               nonok_note => \0) ] },
            { call => 'code', code => sub { main::write_file("$_[0]{WATCH}/$_[0]{SID}/resume-claimed/$n", "prompt.context\n") } });
};
my %seen;
my $snap = sub { my $k = shift; return { call => 'code', code => sub { $seen{$k} = [ map { $_->{key}{nonce} } @{ $a23->($_[0]) } ] } } };
my $idle_d = { %{ $idle->($n1, 999) }, idle => \1 };
my $idle_d2 = { %{ $idle->($n2, 2999) }, idle => \1 };
{
    files => [
        { path => "\$WATCH/\$SID/dispatch/$n0.json", json => T::dispatch($n0, 99, channel => 'mod-self', trigger => 'plugin') },
        { path => "\$WATCH/\$SID/dispatch/$n1.json", json => $idle_d },
        { path => "\$WATCH/\$SID/dispatch/$n2.json", json => $idle_d2 },
        # n0's record is pending too: only an idle dispatch is held.
        { path => '$WATCH/$SID/resume-pending.json', json => $rec->($n0) },
    ],
    transcript => [ T::prompt(0), T::boundary(100, trigger => 'auto'), T::summary(100.1), T::prompt(140) ],
    steps => [
        $post->($n0, 101),
        { call => 'stop', at => 150 },
        $snap->('n0'),
        { call => 'write', path => '$WATCH/$SID/resume-pending.json', json => $rec->($n1) },
        { call => 'append', rows => [ T::boundary(1000, trigger => 'auto'), T::summary(1000.1), T::prompt(1050) ] },
        $post->($n1, 1001),
        { call => 'stop', at => 1100 },
        $snap->('n1-pending'),
        # A resume armed it (resumeblock.pm `arm`): still waiting.
        { call => 'code', code => sub { my $d = "$_[0]{WATCH}/$_[0]{SID}"; rename("$d/resume-pending.json", "$d/resume-armed.json") or die } },
        { call => 'append', rows => [ T::prompt(1400) ] },
        { call => 'stop', at => 1500 },
        $snap->('n1-armed'),
        $claim->($n1, 2000),
        { call => 'write', path => '$WATCH/$SID/resume-armed.json', json => { v => 1, state => 'settled', session_id => $T::SID,
                                                                             nonce => $n1, resume => 'delivered:prompt.context' } },
        { call => 'append', rows => [ T::prompt(2050) ] },
        { call => 'stop', at => 2100 },
        $snap->('n1-claimed'),
        { call => 'write', path => '$WATCH/$SID/resume-pending.json', json => $rec->($n2) },
        { call => 'append', rows => [ T::boundary(3000, trigger => 'auto'), T::summary(3000.1), T::prompt(3050) ] },
        $post->($n2, 3001),
        { call => 'stop', at => 3100 },
        $snap->('n2-pending'),
        # The mod's turn end settled it undelivered (another plugin held prompt.context): no claim.
        { call => 'write', path => '$WATCH/$SID/resume-pending.json', json => { v => 1, state => 'settled', session_id => $T::SID,
                                                                               nonce => $n2, resume => 'undelivered' } },
        { call => 'append', rows => [ T::prompt(4050) ] },
        { call => 'stop', at => 4100 },
        $snap->('n2-settled'),
    ],
    expect => sub {
        my ($E) = @_;
        my $j = sub { join(',', @{ $seen{ $_[0] } || [] }) };
        $E->is($j->('n0'), $n0, 'a non-idle compaction with no claim: A-23 at its first Stop');
        $E->is($j->('n1-pending'), $n0, 'an idle block pending on disk: no A-23');
        $E->is($j->('n1-armed'), $n0, 'an idle block armed by a resume: no A-23');
        $E->is($j->('n1-claimed'), $n0, 'an idle block claimed later: no A-23');
        $E->is($j->('n2-pending'), $n0, 'a second idle block pending: no A-23');
        $E->is($j->('n2-settled'), "$n0,$n2", 'an idle block settled with no claim: A-23 at the next Stop');
        my @a = $E->alerts('A-23');
        $E->is(join(',', map { join(':', $_->{key}{nonce}, keys %{ $_->{evidence} }) } @a), "$n0:count,$n2:count", 'A-23 count 0, twice');
        $E->is($a[1]{evidence}{count}, 0, 'count 0');
        $E->is($a[1]{key}{session_id}, $T::SID, 'the held compaction keeps its key');
    },
};
