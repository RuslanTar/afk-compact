# Keep-warm statistics, 0.1.11 (the sweep): the first main response after a pause of 300 s or more
# writes one `cache_after_gap` row: the pause, the response's time, its cache read, cache write and
# uncached input, `hit` (the read share of the cached prefix 0.5 or more), `miss` or `none` (no cache
# tokens), and Claude Code's cache miss reason from the transcript (`message.diagnostics`):
# `none` when Claude Code reported no reason (diagnostics null), `not-reported` when the line has
# no diagnostics, a known reason as it is (with its missed token count), any other value `other`.
# The other lines of the same response (one per content block), a pause under 300 s, a sidechain
# line and a response with no usage write nothing. The pause is measured across Stops.
my $resp = sub {
    my ($t, $id, %o) = @_;
    my $r = T::assistant_text($t);
    $r->{message}{id} = $id;
    $r->{message}{model} = 'claude-opus-5-5';
    $r->{message}{usage} = { input_tokens => $o{input} // 3, cache_read_input_tokens => $o{read} // 0,
                             cache_creation_input_tokens => $o{write} // 0, output_tokens => 12 } unless $o{no_usage};
    $r->{message}{diagnostics} = $o{diag} if exists $o{diag};
    $r->{isSidechain} = \1 if $o{side};
    return $r;
};
{
    transcript => [
        T::prompt(0),
        $resp->(5, 'msg_a', read => 20000, write => 200000, diag => undef),
        T::prompt(3600),
        # 3600 s after the last response: a warm read, no reason reported
        $resp->(3605, 'msg_b', read => 228161, write => 450, diag => undef),
        # the same response's next content block: no second row
        $resp->(3606, 'msg_b', read => 228161, write => 450, diag => undef),
        T::prompt(3650),
        # 44 s after it: under 300 s, no row
        $resp->(3650, 'msg_c', read => 228600, write => 300, diag => undef),
    ],
    steps => [
        { call => 'stop', at => 3700 },
        { call => 'append', rows => [
              # a sidechain line in the main file: never a main response
              $resp->(6000, 'msg_s', read => 0, write => 9000, side => 1),
              T::prompt(7200),
              # a cold read after 3550 s, with Claude Code's reason and its missed count
              $resp->(7200, 'msg_d', read => 25289, write => 234319,
                      diag => { cache_miss_reason => { type => 'previous_message_not_found', cache_missed_input_tokens => 234319 } }),
              T::prompt(11000),
              # no usage (a synthetic reply): skipped, the pause still counts from msg_d
              $resp->(11000, 'msg_e', no_usage => 1),
              T::prompt(11100),
              # no diagnostics at all: not reported
              $resp->(11100, 'msg_f', read => 259000, write => 200),
              T::prompt(15000),
              # a reason Claude Code may add later: other; no cache tokens at all: none
              $resp->(15000, 'msg_g', input => 250000, read => 0, write => 0,
                      diag => { cache_miss_reason => { type => 'CANARY-TEXT-new reason', cache_missed_input_tokens => 'x' } }),
          ] },
        { call => 'stop', at => 15100 },
    ],
    expect => sub {
        my ($E) = @_;
        my @r = $E->rows('classic', 'cache_after_gap');
        $E->count(\@r, 4, 'one row per first main response after a pause of 300 s or more') or return;
        $E->is(join(',', map { $_->{gap_s} } @r), '3600,3550,3900,3900', 'the pauses, across Stops; the reply with no usage is skipped');
        $E->is(join(',', map { $_->{result} } @r), 'hit,miss,hit,none', 'the cache results');
        $E->is(join(',', map { $_->{miss_reason} } @r), 'none,previous_message_not_found,not-reported,other', 'the miss reasons');
        $E->is(join(',', map { $_->{missed_tokens} // '-' } @r), '-,234319,-,-', 'the missed count only when it is a number');
        $E->is(join(',', map { "$_->{cache_read}/$_->{cache_creation}/$_->{input}" } @r[0, 1]), '228161/450/3,25289/234319/3', 'the token counts');
        $E->is(join(',', map { int(watch::io::parse_iso($_->{resp_ts}) // 0) - $T::BASE } @r), '3605,7200,11100,15000', 'the response times');
        $E->is(join(',', map { $_->{actor} } @r), 'main,main,main,main', 'main rows');
        my %keys;
        $keys{$_}++ for map { keys %$_ } @r;
        $E->is(join(',', sort grep { !/\A(?:v|ts|ev|sid|actor|writer|pid|plugin_version|cc_version|turn_seq)\z/ } keys %keys),
               'cache_creation,cache_read,gap_s,input,miss_reason,missed_tokens,resp_ts,result', 'only counts, times and classes');
    },
};
