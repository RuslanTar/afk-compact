package T;
# Synthetic transcript and record builders for the watcher cases (WATCH §9).
# Shapes follow TF Q3 §1a (keys, not positions). All text is synthetic; the
# planted canaries (`CANARY-TEXT-...`) must never reach a watcher row (T-18).
use strict;
use warnings;

our $SID = '1b2c3d4e-0000-4000-8000-00000000c0de';
our $BRAND = 'plugin';
our $BASE = 1792580400;    # 2026-10-21T11:00:00Z (14:00 at +03:00)
my $n = 0;

sub reset_ids { $n = 0 }
sub uid { return sprintf('u-%04d-0000-4000-8000-%012d', ++$n, $n) }

# Seconds after the base -> ISO (UTC, as transcripts store it) and local +03:00.
sub z {
    my ($s) = @_;
    my @g = gmtime($BASE + $s);
    my $ms = int((($s - int $s) * 1000) + 0.5);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02d.%03dZ', $g[5] + 1900, $g[4] + 1, @g[3, 2, 1, 0], $ms);
}
sub loc {
    my ($s) = @_;
    my @g = gmtime($BASE + $s + 3 * 3600);
    my $ms = int((($s - int $s) * 1000) + 0.5);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02d.%03d+03:00', $g[5] + 1900, $g[4] + 1, @g[3, 2, 1, 0], $ms);
}

sub _base { my ($t, %o) = @_; return (uuid => ($o{uuid} // uid()), sessionId => ($o{sid} // $SID), timestamp => z($t)) }

sub prompt {
    my ($t, $text, %o) = @_;
    return { type => 'user', _base($t, %o), message => { role => 'user', content => ($text // 'CANARY-TEXT-user please continue') } };
}
sub continue_row {
    my ($t, %o) = @_;
    return { type => 'user', _base($t, %o), origin => { kind => 'plugin', name => ($o{name} // $BRAND) },
             message => { role => 'user', content => "Note from the user's $BRAND plugin: CANARY-TEXT-continue" } };
}
sub assistant_text {
    my ($t, %o) = @_;
    return { type => 'assistant', _base($t, %o), message => { role => 'assistant', content => [ { type => 'text', text => 'CANARY-TEXT-assistant done' } ] } };
}
sub tool {
    my ($t, $name, $input, %o) = @_;
    my $id = $o{id} // ('toolu_' . uid());
    return { type => 'assistant', _base($t, %o),
             message => { role => 'assistant', content => [ { type => 'tool_use', id => $id, name => $name, input => ($input || {}) } ] } };
}
sub bash { my ($t, $cmd, %o) = @_; return tool($t, 'Bash', { command => $cmd }, %o) }
sub result {
    my ($t, $id, %o) = @_;
    return { type => 'user', _base($t, %o),
             message => { role => 'user', content => [ { type => 'tool_result', tool_use_id => $id,
                                                         is_error => ($o{error} ? \1 : \0), content => 'CANARY-TEXT-output' } ] } };
}
sub boundary {
    my ($t, %m) = @_;
    my %o = map { $_ => delete $m{$_} } grep { /\A(?:uuid|sid)\z/ } keys %m;
    my %meta = (trigger => 'auto', preTokens => 500000, postTokens => 40000, durationMs => 30000,
                cumulativeDroppedTokens => 0, preservedSegment => { headUuid => 'h', anchorUuid => 'a', tailUuid => 't' }, %m);
    delete $meta{preservedSegment} if exists $m{preservedSegment} && !defined $m{preservedSegment};
    return { type => 'system', subtype => 'compact_boundary', content => 'Conversation compacted', level => 'info',
             parentUuid => undef, isSidechain => \0, _base($t, %o), version => '2.1.306', compactMetadata => \%meta };
}
sub summary {
    my ($t, %o) = @_;
    my %r = (type => 'user', _base($t, %o),
             message => { role => 'user', content => "This session is being continued from a previous conversation that ran out of context. CANARY-TEXT-summary" });
    unless ($o{replaced}) { $r{isCompactSummary} = \1; $r{isVisibleInTranscriptOnly} = \1 }
    return \%r;
}
sub attach {
    my ($t, $type, %o) = @_;
    return { type => 'attachment', _base($t, %o), attachment => { type => $type, %{ $o{fields} || {} } } };
}
sub nudge {
    my ($t, %o) = @_;
    return attach($t, 'hook_additional_context', %o,
                  fields => { hookEvent => 'PostToolUse', content => [ "Note from the user's $BRAND plugin: CANARY-TEXT-nudge" ] });
}
sub api_error {
    my ($t, $text, %o) = @_;
    return { type => 'assistant', _base($t, %o), isApiErrorMessage => \1,
             message => { role => 'assistant', content => [ { type => 'text', text => $text } ] } };
}

sub dispatch {
    my ($nonce, $t, %o) = @_;
    return { v => 1, nonce => $nonce, session_id => $SID, actor => ($o{actor} // 'main'), agent_id => $o{agent_id},
             trigger => ($o{trigger} // 'auto'), channel => ($o{channel} // 'mod-hook'),
             resume_pref => ($o{resume_pref} // 'prompt.context'), midturn => \0, tags => ($o{tags} // []),
             instructions_sha8 => '9f2c01ab', instructions_bytes => 3994, cc_version => '2.1.306', load_id => 'L1',
             pid => 4242, pid_lstart => 'Tue Oct 21 13:00:00 2026', ts => loc($t) };
}

# A log row in the WATCH §6.2 envelope, for rows other writers own.
sub row {
    my ($ev, $t, %f) = @_;
    my $actor = delete $f{actor} // 'main';
    my $writer = delete $f{writer} // 'mod';
    return { v => 1, ts => loc($t), ev => $ev, sid => $SID, actor => $actor, writer => $writer, pid => 4242,
             plugin_version => '0.1.0', cc_version => '2.1.306', turn_seq => undef, %f };
}

# A summary body in the main form, built from the spec headings.
sub main_body {
    my (%o) = @_;
    my $nonce = $o{nonce};
    my @l;
    push @l, "\xe2\x9f\xaa$BRAND v1 n=$nonce s=" . ($o{scope} // 'main') . "\xe2\x9f\xab" if $nonce;
    push @l, '# CANARY-TEXT-topic ' . "\xe2\x80\x94" . ' tested';
    push @l, '## Resume here (<=5 lines)', 'Step 1: `make test` ' . "\xe2\x80\x94" . ' for "CANARY-TEXT-request"', 'Gate: none';
    push @l, '## User constraints', @{ $o{U} || ['U-1 "CANARY-TEXT-keep"'] };
    push @l, '## Decisions and do-not-re-raise', @{ $o{D} || ['D-1 use the queue ' . "\xe2\x80\x94" . ' because CANARY-TEXT-reason'] };
    push @l, '## In flight, latest listing', @{ $o{B} || ['Nothing in flight as of the last message (not checked)'] };
    push @l, '## Live state', 'none beyond git (not checked)';
    push @l, '## Open questions, user-owned', 'none';
    push @l, '## Location, if changed', 'none';
    push @l, '## Work done and findings', @{ $o{W} || ['CANARY-TEXT-work: tested'] };
    push @l, '## Evidence', 'none';
    push @l, '## Next steps', '1. `make test` ' . "\xe2\x80\x94" . ' done when green';
    push @l, "\xe2\x9f\xaa/$BRAND n=$nonce\xe2\x9f\xab" if $nonce;
    return join("\n", @l) . "\n";
}


# W-BETA fixture install (AT-WB-02..07): a watch tree and a handoff root with planted
# canaries in every place the report must never copy from. @BETA_CANARIES lists the strings
# a bundle must not contain (the case adds $HOME, the user and host names).
our $AGENT = 'a9a00b3f36332744e';
our @BETA_CANARIES = ('canaryrepoalpha', 'canary-4711-bucketbeta', '4711-bucketbeta', 'canarybranchgamma',
                      'CANARY-TEXT', 'CANARY-evidence-path', 'AKIAABCDEFGHIJKLMNOP',
                      'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXRlc3Q', $SID, $AGENT,
                      'abcd0001', '-synthetic-proj');
sub beta_install {
    my (%o) = @_;
    my $rel = 'canaryrepoalpha/canary-4711-bucketbeta/compact/2026-10-21_13-50-00_1b2c3d4e_c1-f0f000.md';
    my $jwt = $BETA_CANARIES[7];
    my @mod = (
        row('dispatch', 1, nonce => 'f0f00001', trigger => 'auto', agent_id => undef, channel => 'mod-hook',
            instructions_bytes => 3994, cwd => '$HOME/work/canaryrepoalpha', branch => 'canarybranchgamma'),
        row('compacted', 30, nonce => 'f0f00001', skip => undef, tokens_before => 500000, tokens_after => 40000,
            usage_present => \1, ms => 30000),
        row('continue', 40, result => 'halt:cap', continues_last_hour => 6),
        row('handoff_turn_start', 41, ht => 'abcd0001', reason => 'cap', turn_id => 'p-CANARY-TEXT', t0 => 1,
            gap_s => undef, max_calls => 34, max_tokens => 64000),
        row('mystery_event', 42, note => 'CANARY-TEXT-mystery'),
    );
    my @classic = (
        row('precompact', 2, writer => 'classic', trigger => 'auto', ci_bytes => 3994, ci_has_nonce => \1,
            ci_nonce => 'f0f00001', ci_foreign_header => \0, keyset_hash => '62a951d7'),
        row('postcompact', 31, writer => 'classic', trigger => 'auto', nonce_found => 'f0f00001', scope_found => 'main',
            verdict => 'ok', summary_chars => 9000, section_chars => { resume => 300, '## Task as assigned' => 20,
            'CANARY-TEXT heading' => 5 }, secret_hits => ['jwt'], measured_stamp => '2026-10-21 14:00 +0300',
            ledger => { lost_U => 0, lost_D => 1, ledger_src => 'copy', excerpt => 'CANARY-TEXT-ledger' }),
        row('copy', 32, writer => 'classic', nonce => 'f0f00001', id6 => 'f0f000', result => 'saved', slot => 'main',
            rel_path => $rel),
        row('copy_failed', 33, writer => 'classic', nonce => 'f0f00002', reason => 'AKIAABCDEFGHIJKLMNOP'),
        row('sweep', 34, writer => 'classic', file => "$SID.jsonl", from_off => 0, to_off => 999,
            boundaries => [ { line => 3, uuid => 'u-0001', ts => z(10), trigger => 'auto', pre => 500000,
                              attributed => $AGENT, summary_text => 'CANARY-TEXT-sweep' } ]),
        row('heal', 35, writer => 'helper', origin_sid => $SID, item => 'b1', result => 'ok',
            command => 'CANARY-TEXT-heal make deploy'),
    );
    my @alerts = ( row('alert', 36, writer => 'classic', alert_id => 'a01-1234abcd', rule => 'A-01', severity => 'critical',
                       key => { session_id => $SID, actor => $AGENT, compaction_seq => 1, nonce => 'f0f00001' },
                       evidence => { copy => 'missing', line => 3, path => '$HOME/CANARY-evidence-path' }) );
    my @roll = ( row('compaction', 31, writer => 'helper', session_id => $SID, nonce => 'f0f00001', id6 => 'f0f000',
                     trigger => 'auto', seat_state => 'mod-hook', verdict => 'ok', copy => 'saved', copy_path => $rel,
                     idle => 'false', pre_tokens => 500000, copy_failed_detail => $jwt) );
    return [
        { path => '$WATCH/$SID.jsonl', jsonl => \@mod },
        { path => '$WATCH/$SID.classic.jsonl', jsonl => \@classic },
        { path => '$WATCH/$SID.alerts.jsonl', jsonl => \@alerts },
        { path => '$WATCH/$SID/compactions.jsonl', jsonl => \@roll },
        { path => '$WATCH/$SID/events/1792580400000-ab12.json', json => row('skip', 50, why => 'cooldown') },
        { path => '$WATCH/$SID/mod-alive.json', json => { pid => 4242, turn_id => 'p-1', ts => loc(1) } },
        { path => '$WATCH/$SID/jobs.jsonl', jsonl => [ { ev => 'job', command => 'CANARY-TEXT-jobcmd make deploy' } ] },
        { path => '$WATCH/$SID/paths.jsonl', jsonl => [ { path => '$HOME/CANARY-evidence-path/a.log' } ] },
        { path => '$WATCH/$SID/evidence-index.tsv', text => "CANARY-evidence-path\t1\n" },
        { path => '$WATCH/$SID/queue-adds.jsonl', jsonl => [ { question => 'CANARY-TEXT-question?' } ] },
        { path => '$WATCH/$SID/handoff-turn/abcd0001.stage', text => "CANARY-TEXT-draft\n" },
        { path => '$WATCH/$SID/bg/slot-1.json',
          json => { tasks => [ { id => 'b1', type => 'shell', output_path => '$HOME/CANARY-evidence-path/o' } ] } },
        { path => '$WATCH/version.json', json => { lastVersion => '2.1.306', smokeDue => '2.1.306' } },
        { path => '$WATCH/fingerprints/94c3672537e5.seen', text => '' },
        { path => "\$ROOT/$rel", text => "---\nkind: compact-summary\n---\nCANARY-TEXT-summary\n", mode => 0400 },
        { path => '$ROOT/canaryrepoalpha/canary-4711-bucketbeta/handoff.md', text => "CANARY-TEXT-handoff\n" },
    ];
}


# Report test helpers: the zips in a folder (newest last), a tree's files with their bytes'
# sha (for the D-8 and Dev-6 checks), and the entries of a zip.
sub zips_in {
    my ($dir) = @_;
    return map { "$dir/$_" } grep { /\.zip\z/ } watch::io::list_dir($dir);
}
sub tree {
    my ($dir) = @_;
    my %t;
    my @q = ($dir);
    while (@q) {
        my $d = shift @q;
        for my $e (watch::io::list_dir($d)) {
            my $p = "$d/$e";
            if (-d $p && !-l $p) { push @q, $p; next }
            my $c = watch::io::slurp($p) // '';
            $t{ substr($p, length($dir) + 1) } = length($c) . ':' . watch::io::fnv8($c) . ':' . ((stat $p)[2] & 07777);
        }
    }
    return \%t;
}
sub zip_entries {
    my ($path) = @_;
    require watch::bundle;
    my $u = watch::bundle::unzip(watch::io::slurp($path) // '');
    return { map { $_->{name} => $_ } @{ $u->{entries} || [] } };
}

1;
