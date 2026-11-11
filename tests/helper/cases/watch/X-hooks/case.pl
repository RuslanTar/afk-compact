# F2-5: `stop_failure` and `permission_denied`
# have one writer, core's `hook`. The watcher's on_hook writes
# nothing for StopFailure or PermissionDenied and reads no transcript for them
# (a transcript read here dies, which would leave a watch_error row). Through
# the real launcher, one denial gives exactly one `permission_denied` row with
# core's computed classes, and one API-error stop exactly one `stop_failure`
# row. The rules read core's row: A-17 (d) for the StopFailure 8 s after a
# counted dispatch.
my $n = 'abab0002';
my $tail = \&watch::rows::tail_rows;
my $deny = '{"session_id":"' . $T::SID . '","transcript_path":"/nonexistent/t.jsonl","cwd":"/nonexistent",'
         . '"hook_event_name":"PermissionDenied","tool_name":"Bash","tool_input":{"command":"sleep 60"},'
         . '"tool_use_id":"toolu_01","reason":"denied by a rule"}';
my $fail = '{"session_id":"' . $T::SID . '","transcript_path":"/nonexistent/t.jsonl","cwd":"/nonexistent",'
         . '"hook_event_name":"StopFailure","error":"rate_limit"}';
{
    files => [ { path => "\$WATCH/\$SID/dispatch/$n.json", json => T::dispatch($n, 8) } ],
    transcript => [ T::prompt(0), T::bash(2, 'ls', id => 'toolu_1'), T::result(3, 'toolu_1') ],
    steps => [
        { call => 'code', code => sub {
              no warnings 'redefine';
              *watch::rows::tail_rows = sub { die "transcript-read\n" };
          } },
        { call => 'hook', event => 'PermissionDenied', at => 11,
          payload => { tool_name => 'Bash', tool_input => { command => 'CANARY-TEXT-x' }, tool_use_id => 't', reason => 'CANARY-TEXT-r' } },
        { call => 'hook', event => 'PermissionDenied', at => 12, payload => { tool_name => 'Edit', reason => 'r', agent_id => 'a1' } },
        { call => 'hook', event => 'StopFailure', at => 13, payload => { error => 'overloaded', error_details => 'CANARY-TEXT-d' } },
        { call => 'code', code => sub {
              no warnings 'redefine';
              *watch::rows::tail_rows = $tail;
          } },
        { call => 'cli', at => 15, argv => ['hook', 'PermissionDenied'], stdin => $deny },
        { call => 'cli', at => 16, argv => ['hook', 'StopFailure'], stdin => $fail },
        { call => 'stop', at => 30 },
    ],
    expect => sub {
        my ($E) = @_;
        $E->count([ $E->rows('classic', 'watch_error') ], 0, 'no watch_error (no transcript read for these events)');
        my @d = $E->rows('classic', 'permission_denied');
        $E->count(\@d, 1, 'one permission_denied row for one denial');
        $E->is(join('/', map { $_ // 'undef' } @{ $d[0] || {} }{qw(tool_name reason_class guard_class)}),
               'Bash/rule/sleep-poll', "core's computed classes");
        my @s = $E->rows('classic', 'stop_failure');
        $E->count(\@s, 1, 'one stop_failure row for one failed stop');
        $E->is($s[0]{error_class}, 'rate_limit', 'error class');
        my @a = map { $_->{evidence}{failed} } $E->alerts('A-17');
        $E->is(join(',', @a), 'api-error:rate_limit', "A-17 (d) from core's stop_failure row");
    },
};
