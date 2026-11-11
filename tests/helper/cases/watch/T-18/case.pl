# T-18: canary strings planted in instructions, summary,
# commands, user text, denial input and reason, error details and the last
# assistant message reach no watcher row (the driver greps every file under
# <watch> after each case; this case touches every hook-time writer). The
# denial and the failed stop also run through the real launcher, whose core
# hook is the one writer of their rows (F2-5).
my $n = '5e5e0018';
my $deny = '{"session_id":"' . $T::SID . '","transcript_path":"/nonexistent/t.jsonl","cwd":"/nonexistent",'
         . '"hook_event_name":"PermissionDenied","tool_name":"Bash","tool_input":{"command":"CANARY-TEXT-denied"},'
         . '"tool_use_id":"toolu_9","reason":"CANARY-TEXT-reason"}';
my $fail = '{"session_id":"' . $T::SID . '","transcript_path":"/nonexistent/t.jsonl","cwd":"/nonexistent",'
         . '"hook_event_name":"StopFailure","error":"rate_limit","error_details":"CANARY-TEXT-details",'
         . '"last_assistant_message":"CANARY-TEXT-last"}';
my $body = T::main_body(nonce => $n, W => ['CANARY-TEXT-work /tmp/CANARY-TEXT-path', 'WARN CANARY-TEXT-log']);
{
    files => [ { path => "\$WATCH/\$SID/dispatch/$n.json", json => T::dispatch($n, 8) } ],
    transcript => [
        T::prompt(0, 'CANARY-TEXT-user asks'),
        T::bash(2, 'echo CANARY-TEXT-cmd | git push', id => 'toolu_1'), T::result(3, 'toolu_1'),
        T::boundary(10, trigger => 'auto'), T::summary(10.1),
        T::tool(12, 'mcp__CANARY-TEXT-srv__create_issue', { title => 'CANARY-TEXT-title' }, id => 'toolu_2'),
        T::result(13, 'toolu_2'),
        T::api_error(14, 'CANARY-TEXT-api Error compacting conversation'),
    ],
    steps => [
        { call => 'hook', event => 'PreCompact', at => 9, payload => { trigger => 'auto', custom_instructions => 'CANARY-TEXT-ci' } },
        { call => 'hook', event => 'PostCompact', at => 11, payload => { trigger => 'auto', compact_summary => $body },
          ctx => { detect => { verdict => 'ok', nonce => $n, scope => 'main', marker_line => 1, sentinel_from_end => 1,
                               normalized => $body }, secret_hits => ['jwt'] } },
        { call => 'hook', event => 'PermissionDenied', at => 15,
          payload => { tool_name => 'Bash', tool_input => { command => 'CANARY-TEXT-denied' }, tool_use_id => 'toolu_9',
                       reason => 'CANARY-TEXT-reason' } },
        { call => 'hook', event => 'StopFailure', at => 16,
          payload => { error => 'rate_limit', error_details => 'CANARY-TEXT-details', last_assistant_message => 'CANARY-TEXT-last' } },
        { call => 'cli', at => 15, argv => ['hook', 'PermissionDenied'], stdin => $deny },
        { call => 'cli', at => 16, argv => ['hook', 'StopFailure'], stdin => $fail },
        { call => 'stop', at => 30, payload => { last_assistant_message => 'CANARY-TEXT-last' } },
    ],
    expect => sub {
        my ($E) = @_;
        for my $ev (qw(precompact postcompact sweep)) {
            $E->ok(scalar($E->rows('classic', $ev)), "a $ev row was written");
        }
        for my $ev (qw(permission_denied stop_failure)) {
            $E->count([ $E->rows('classic', $ev) ], 1, "one $ev row (core's)");
        }
        $E->count([ $E->alerts('A-21') ], 1, 'A-21 on a HARD secret rule id');
        my @f = sort map { $_->{evidence}{failed} } $E->alerts('A-17');
        $E->is(join(',', @f), 'api-error:compact,api-error:rate_limit',
               'A-17 for the compacting API error row and for the StopFailure 8 s after a dispatch');
        my ($p) = $E->rows('classic', 'postcompact');
        $E->is(join(',', @{ $p->{secret_hits} }), 'jwt', 'rule ids only');
    },
};
