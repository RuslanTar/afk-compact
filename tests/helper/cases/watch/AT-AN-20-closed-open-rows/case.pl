# AT-AN-20 (0.1.4 W-4): a closed alert (superseded, resolved) no longer grades or holds back a later
# real one: a rule is graded info only while an open row of it exists, and A-15's canary "first for
# this Claude Code version" reads open rows only (the alert id dedupe still reads every row, so a
# closed id is never raised again; HS-04 covers A-24). The log holds a hookless A-15 and a
# version_change A-15 of Claude Code 2.1.400, both closed as superseded: a real hookless boundary
# and a new version_change row of 2.1.400 each raise A-15 as warn.
my $aid = sub { watch::alerts::alert_id($_[0], $T::SID, @_[1 .. $#_]) };
my $old = sub {
    my ($id, $cc, %ev) = @_;
    return ({ %{ T::row('alert', 50, writer => 'classic', alert_id => $id, rule => 'A-15', severity => 'warn',
                        key => { session_id => $T::SID, actor => 'main', compaction_seq => 1, nonce => 'none' }, evidence => { %ev }) },
              plugin_version => '0.1.2', cc_version => $cc },
            T::row('alert_closed', 60, writer => 'classic', alert_id => $id, rule => 'A-15', reason => 'superseded: rule changed in 0.1.3'));
};
{
    files => [
        { path => '$WATCH/$SID.alerts.jsonl',
          jsonl => [ $old->($aid->('A-15', 'b:old-b', 'hookless'), '2.1.306', hookless_boundary => \1, line => 3),
                     $old->($aid->('A-15', 'version_change', 'x'), '2.1.400', canary => 'version_change') ] },
        { path => '$WATCH/$SID.classic.jsonl',
          jsonl => [ T::row('config_note', 1, writer => 'helper', key => 'relaunch_auto', note => 'settings-file-only') ] },
        { path => '$WATCH/$SID.jsonl', jsonl => [ { %{ T::row('version_change', 150) }, cc_version => '2.1.400' } ] },
    ],
    transcript => [ T::prompt(0), T::assistant_text(5), T::boundary(100, uuid => 'b-new', trigger => 'auto'), T::summary(100.1) ],
    steps => [ { call => 'stop', at => 1000 } ],
    expect => sub {
        my ($E) = @_;
        my @a = grep { ($_->{plugin_version} // '') ne '0.1.2' } $E->alerts('A-15');
        my %by = map { ((ref $_->{evidence} eq 'HASH' && $_->{evidence}{canary} ? 'canary' : 'hookless') => $_) } @a;
        $E->count(\@a, 2, 'two new A-15 rows');
        $E->is(($by{hookless} || {})->{severity}, 'warn', 'the real hookless boundary is warn (the closed hookless row demotes nothing)');
        $E->is(($by{canary} || {})->{severity}, 'warn', 'the version_change of 2.1.400 is warn (the closed canary row of 2.1.400 holds nothing back)');
    },
};
