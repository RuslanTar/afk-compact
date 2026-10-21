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

1;
