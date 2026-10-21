package scope;
# lib/scope.pm: scope proof for every classic-side save and inject (MOD-SPEC §2.4).
#   P1 dispatch record for the nonce: main = agent_id null and channel mod-hook|mod-self;
#      subagent = agent_id set
#   P2 summary marker s=sub (s=main alone is no proof: the classic text is scope-neutral)
#   P3 transcript: main transcript holds more compact_boundary rows than
#      <watch>/<sid>/boundaries.count -> main signal; a subagents/agent-*.jsonl
#      gained a boundary newer than the dispatch ts while the main count did not change
#      -> subagent signal (agent id from the file name)
#   main = P1-main, or P3-main with no subagent signal; subagent = P1-sub, P2-sub or
#   P3-sub; both or neither = unknown. Owner: WP-core.
use strict;
use warnings;

sub stored_count {
    my ($sid_dir) = @_;
    my $raw = util::read_file("$sid_dir/boundaries.count");
    return 0 unless defined $raw && $raw =~ /(\d+)/;
    return 0 + $1;
}

# prove(dispatch => rec|undef, marker_scope => main|sub|manual|undef,
#       transcript => path, sid => S, sid_dir => D, since => epoch)
# -> {scope, agent_id, main_count, p1, p2, p3_main, p3_sub}
sub prove {
    my (%a) = @_;
    my $d = $a{dispatch};
    my %r = (p1 => undef, p2 => undef, p3_main => 0, p3_sub => 0);
    if ($d) {
        if (defined $d->{agent_id}) { $r{p1} = 'sub'; $r{agent_id} = $d->{agent_id} }
        elsif (dispatch::is_mod($d)) { $r{p1} = 'main' }
    }
    $r{p2} = 'sub' if ($a{marker_scope} // '') eq 'sub';
    my $tp = $a{transcript};
    my $main_count = defined $tp && -f $tp ? transcript::count($tp) : undef;
    $r{main_count} = $main_count;
    my $stored = stored_count($a{sid_dir});
    $r{p3_main} = (defined $main_count && $main_count > $stored) ? 1 : 0;
    if (!$r{p3_main}) {
        my $since = $a{since} // (util::now() - 120);
        for my $f (@{ transcript::subagent_files($tp, $a{sid}) }) {
            my $b = transcript::boundaries($f->{path});
            if (grep { $_->{epoch} >= $since - 1 } @$b) {
                $r{p3_sub} = 1;
                $r{agent_id} //= $f->{agent_id};
                last;
            }
        }
    }
    my $sub = ($r{p1} // '') eq 'sub' || $r{p2} || $r{p3_sub};
    my $main = ($r{p1} // '') eq 'main' || ($r{p3_main} && !$sub);
    $r{scope} = ($main && $sub) ? 'unknown' : $main ? 'main' : $sub ? 'sub' : 'unknown';
    delete $r{agent_id} if $r{scope} ne 'sub';
    return \%r;
}

# Set boundaries.count to the observed main count (under seq.lock), MOD-SPEC §2.4.
sub set_count {
    my ($sid_dir, $count, $owner) = @_;
    return unless defined $count;
    lock::with("$sid_dir/seq.lock", $owner, sub {
        util::write_atomic("$sid_dir/boundaries.count", "$count\n", 0600);
    });
}

1;
