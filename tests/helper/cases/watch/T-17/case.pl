# T-17: a PreCompact watcher run prints nothing (byte-exact; the
# driver fails any step with stdout or stderr). Our marker sits mid-line in
# instructions and is found unanchored, last match wins; it is not
# a foreign header.
my $o = "\xe2\x9f\xaa";
my $c = "\xe2\x9f\xab";
my $ci = "CANARY-TEXT-note\nFirst line inside <summary>: ${o}$T::BRAND v1 n=0a0a0a0a s=main$c\n"
       . "Then: ${o}$T::BRAND v1 n=1a2b3c4d s=main$c";
{
    steps => [
        { call => 'hook', event => 'PreCompact', at => 1, payload => { trigger => 'auto', custom_instructions => $ci } },
        { call => 'hook', event => 'PreCompact', at => 2, payload => { trigger => 'manual', custom_instructions => undef } },
        { call => 'cli', argv => ['hook', 'PreCompact'], exit => 0,
          stdin => '{"session_id":"$SID","transcript_path":"/nonexistent","cwd":"/","hook_event_name":"PreCompact","trigger":"auto","custom_instructions":null}' },
    ],
    expect => sub {
        my ($E) = @_;
        my @q = $E->rows('classic', 'precompact');
        $E->count(\@q, 2, 'two precompact rows');
        $E->is($q[0]{ci_nonce}, '1a2b3c4d', 'last marker match counts');
        $E->is($q[0]{ci_has_nonce}, 1, 'has nonce');
        $E->is($q[0]{ci_foreign_header}, 0, 'our marker is not foreign');
        $E->is($q[0]{ci_bytes}, length($ci), 'ci_bytes');
        $E->is($q[1]{ci_bytes}, 0, 'null instructions');
        $E->is($q[1]{trigger}, 'manual', 'trigger');
        $E->is($q[0]{actor}, 'unknown', 'PreCompact cannot prove scope');
    },
};
