# AT-WB-01 / AT-WB-02, tool names (re-review regression on export_schema.pm:142):
# the hook writes the payload's tool name as it is (hook.pl on_PermissionDenied), so an MCP tool
# name carries the user's own server name (`mcp__acme-payroll__list`). Tool names go through the
# `tool` class: a Claude Code built-in name is kept, any `mcp__*` name (and the sweep's own `mcp`)
# becomes `mcp`, anything else `other`. No server or tool name of an MCP server reaches the zip.
# The sweep's per-turn tool counts (`turns.classes`) use the same class for their keys.
my %got;
my @rows = (
    { ev => 'permission_denied', tool_name => 'mcp__acme-payroll__list', reason_class => 'rule', guard_class => 'other',
      turn_kind => 'other', caused_by => 'session' },
    { ev => 'permission_denied', tool_name => 'mcp__acme_payroll_and_a_much_longer_server__list_all_the_things',
      reason_class => 'rule' },
    { ev => 'permission_denied', tool_name => 'Bash', reason_class => 'rule' },
    { ev => 'permission_denied', tool_name => 'WebFetch', reason_class => 'rule' },
    { ev => 'permission_denied', tool_name => 'acmepayroll', reason_class => 'rule' },
    { ev => 'permission_denied', tool_name => 'AcmePayroll', reason_class => 'rule' },
    { ev => 'permission_denied', tool_name => 'other', reason_class => 'rule' },
    { ev => 'sweep', file => 'f', turns => { tool_calls => 4,
      classes => { Bash => 2, mcp => 1, 'mcp__acme-payroll__list' => 1, acmepayroll => 3, Edit => 1 } } },
);
{
    steps => [
        { call => 'code', code => sub {
              require watch::export;
              my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
              $got{out} = [ map { watch::export::transform_row({ v => 1, ts => '2026-10-22T09:00:00.000+03:00', sid => $T::SID,
                                                                 actor => 'main', writer => 'classic', %$_ }, $X) } @rows ];
              $got{dropped} = $X->{dropped};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = @{ $got{out} };
        $E->is(join(',', map { "$_=$got{dropped}{$_}" } sort keys %{ $got{dropped} }), '', 'nothing dropped');
        $E->is($o[0]{tool_name}, 'mcp', 'an MCP tool name becomes mcp (no server name)');
        $E->is($o[1]{tool_name}, 'mcp', 'a long MCP tool name becomes mcp');
        $E->is($o[2]{tool_name}, 'Bash', 'built-in Bash kept');
        $E->is($o[3]{tool_name}, 'WebFetch', 'built-in WebFetch kept');
        $E->is($o[4]{tool_name}, 'other', 'an unknown lowercase name becomes other');
        $E->is($o[5]{tool_name}, 'other', 'an unknown capitalised name becomes other');
        $E->is($o[6]{tool_name}, 'other', 'the hook\'s own other stays other');
        $E->is($o[0]{reason_class}, 'rule', 'reason_class kept');
        my $c = $o[7]{turns}{classes} || {};
        $E->is(join(',', map { "$_=$c->{$_}" } sort keys %$c), 'Bash=2,Edit=1,mcp=2,other=3', 'sweep turn classes keyed by tool class');
        my $all = join("\n", map { watch::json::encode($_) } @o);
        $E->ok((index(lc $all, 'acme') < 0 ? 1 : 0), 'no server name anywhere in the exported rows');
    },
};
