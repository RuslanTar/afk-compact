# WATCH W10/W11 (MOD-SPEC §1.3): `stop_failure {error_class}` from the error
# enum only; `permission_denied {tool_name, reason_class, guard_class,
# turn_kind, caused_by}` with turn_kind and caused_by classed from the
# transcript in memory. reason_class and guard_class are `other` until the
# class patterns exist (escalated: not in design/).
my @calls = map { (T::bash(41 + $_ * 0.1, 'ls', id => "toolu_x$_"), T::result(41.05 + $_ * 0.1, "toolu_x$_")) } 0 .. 10;
{
    transcript => [
        T::prompt(0), T::bash(2, 'make', id => 'toolu_1'), T::result(3, 'toolu_1'),
        T::boundary(10, trigger => 'auto'), T::summary(10.1),
        T::attach(10.2, 'hook_additional_context', fields => { hookEvent => 'SessionStart', content => ['CANARY-TEXT-block'] }),
        T::bash(12, 'ls', id => 'toolu_2'),
    ],
    steps => [
        { call => 'hook', event => 'PermissionDenied', at => 13,
          payload => { tool_name => 'Bash', tool_input => { command => 'CANARY-TEXT-x' }, tool_use_id => 't', reason => 'CANARY-TEXT-r' } },
        { call => 'append', rows => [ T::result(13.5, 'toolu_2'), T::prompt(30), T::prompt(40), @calls ] },
        { call => 'hook', event => 'PermissionDenied', at => 60, payload => { tool_name => 'mcp__srv__create_x', reason => 'r' } },
        { call => 'append', rows => [ T::prompt(70, "/$T::BRAND:resume some-topic") ] },
        { call => 'hook', event => 'PermissionDenied', at => 71, payload => { tool_name => 'Write', reason => 'r' } },
        { call => 'append', rows => [ T::nudge(80) ] },
        { call => 'hook', event => 'PermissionDenied', at => 81, payload => { tool_name => 'Edit', reason => 'r' } },
        { call => 'hook', event => 'PermissionDenied', at => 82, payload => { tool_name => 'Bash', reason => 'r', agent_id => 'a1' } },
        { call => 'hook', event => 'StopFailure', at => 90, payload => { error => 'overloaded', error_details => 'CANARY-TEXT-d' } },
        { call => 'hook', event => 'StopFailure', at => 91, payload => { error => 'Weird Thing' } },
    ],
    expect => sub {
        my ($E) = @_;
        my @d = $E->rows('classic', 'permission_denied');
        $E->count(\@d, 5, 'five denial rows');
        $E->is("$d[0]{turn_kind}/$d[0]{caused_by}", 'post-compaction/plugin', 'first turn after a compaction, after a plugin block');
        $E->is("$d[1]{turn_kind}/$d[1]{caused_by}", 'other/session', 'a later turn, more than 10 calls after the block');
        $E->is($d[1]{tool_name}, 'mcp__srv__create_x', 'tool name kept');
        $E->is("$d[2]{turn_kind}/$d[2]{caused_by}", 'resume/session', 'a manual resume turn');
        $E->is("$d[3]{turn_kind}/$d[3]{caused_by}", 'nudge/plugin', 'after a nudge');
        $E->is("$d[4]{turn_kind}/$d[4]{actor}", 'other/unknown', 'a subagent denial');
        $E->is(join(',', map { "$_->{reason_class}/$_->{guard_class}" } @d[0, 1]), 'other/other,other/other', 'classes');
        my @s = $E->rows('classic', 'stop_failure');
        $E->is(join(',', map { $_->{error_class} } @s), 'overloaded,other', 'error classes');
    },
};
