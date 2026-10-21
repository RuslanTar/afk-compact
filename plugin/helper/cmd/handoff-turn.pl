# cmd/handoff-turn.pl: the handoff-turn records of D-18 §9.1 (BUILD-PLAN §3.1). Owner: WP-core.
#   handoff-turn open --sid S --ht H --reason R --max-calls C --max-tokens T
#     -> `ok` (exclusive create of <watch>/<sid>/handoff-turn/<ht>.json; row
#        handoff_turn_open) | `EXISTS` (that ht is taken: draw another)
#   handoff-turn supersede --sid S --ht H --nonce N
#     -> `ok` | `EXISTS`; a native compaction (nonce N) ran during the turn (the race):
#        the plugin compaction for this ht is dropped. Unknown ht -> exit 3 `REFUSED: no-ht`
# The mod runs both; the reason is the halt reason of the last cycle (2-nonok, thrash,
# cap, continue-off); C and T are the mod's limits for the turn (D-18 B1 step 2).
use strict;
use warnings;

package cmd_handoff_turn;

sub run {
    my ($verb, @rest) = @_;
    die "usage: handoff-turn open|supersede --sid S --ht H ...\n" unless defined $verb && $verb =~ /^(open|supersede)$/;
    my ($opt) = args::parse(\@rest, known => [qw(sid ht reason max-calls max-tokens nonce root log-dir)]);
    my $sid = args::init_sid($opt);
    args::need($opt, 'ht');
    die "usage: --ht is 8 lowercase hex\n" unless handoff_turn::valid_ht($opt->{ht});
    my $d = rc::sid_dir();
    if (!defined $d) { args::out('REFUSED: ' . (rc::root_reason('log_dir') // 'no-watch')); return 3 }
    if ($verb eq 'supersede') {
        args::need($opt, 'nonce');
        die "usage: --nonce is 8 lowercase hex\n" unless nonce::valid($opt->{nonce});
        if (!handoff_turn::record($d, $opt->{ht})) { args::out('REFUSED: no-ht'); return 3 }
        args::out(handoff_turn::supersede($d, $opt->{ht}, $opt->{nonce}) ? 'ok' : 'EXISTS');
        return 0;
    }
    args::need($opt, qw(reason max-calls max-tokens));
    die "usage: --reason 2-nonok|thrash|cap|continue-off\n" unless $handoff_turn::REASONS{ $opt->{reason} };
    for my $k (qw(max-calls max-tokens)) { die "usage: --$k is a positive number\n" unless $opt->{$k} =~ /\A[1-9][0-9]{0,8}\z/ }
    if (!handoff_turn::open_ht($d, $sid, $opt->{ht}, $opt->{reason}, $opt->{'max-calls'}, $opt->{'max-tokens'})) {
        args::out('EXISTS');
        return 0;
    }
    rc::emit('handoff_turn_open', [ht => $opt->{ht}, reason => $opt->{reason}, max_calls => 0 + $opt->{'max-calls'},
                                   max_tokens => 0 + $opt->{'max-tokens'}], actor => 'main');
    args::out('ok');
    return 0;
}

exit(args::main(\&run, @ARGV));
