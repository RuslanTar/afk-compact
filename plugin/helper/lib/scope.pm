package scope;
# lib/scope.pm: scope proof for every classic-side save and inject (MOD-SPEC §2.4, as
# ROOT-RULINGS F2-1 orders it after the S-21 probe). Owner: WP-core.
#   P1 dispatch record for the nonce: main = agent_id null and channel mod-hook|mod-self;
#      subagent = agent_id set
#   P2 summary marker s=sub (s=main alone is no proof: the classic text is scope-neutral)
#   P3 transcript boundary rows: the main compact_boundary row is written after
#      SessionStart(compact) and PostCompact (S-21, 2 of 2 live compactions), so P3 can
#      never prove the current compaction inside those hooks. It is evaluated at the next
#      Stop only (reconcile::p3), which matches each new main boundary to the PostCompact
#      before it, and a new subagent boundary to an unmatched one.
#   main = P1-main, or P3-main with no subagent signal; subagent = P1-sub, P2-sub or
#   P3-sub; both or neither = unknown. Without proof PostCompact stashes and defers the
#   save to reconcile: no main-slot save and no sweep without proof (MOD-SPEC §0 item 6).
use strict;
use warnings;

sub stored_count {
    my ($sid_dir) = @_;
    my $raw = util::read_file("$sid_dir/boundaries.count");
    return 0 unless defined $raw && $raw =~ /(\d+)/;
    return 0 + $1;
}

# prove(dispatch => rec|undef, marker_scope => main|sub|manual|undef)
# -> {scope, agent_id, p1, p2}: the proofs a hook may use (no boundary count)
sub prove {
    my (%a) = @_;
    my $d = $a{dispatch};
    my %r = (p1 => undef, p2 => undef);
    if ($d) {
        if (defined $d->{agent_id}) { $r{p1} = 'sub'; $r{agent_id} = $d->{agent_id} }
        elsif (dispatch::is_mod($d)) { $r{p1} = 'main' }
    }
    $r{p2} = 'sub' if ($a{marker_scope} // '') eq 'sub';
    my $sub = ($r{p1} // '') eq 'sub' || $r{p2};
    my $main = ($r{p1} // '') eq 'main';
    $r{scope} = ($main && $sub) ? 'unknown' : $main ? 'main' : $sub ? 'sub' : 'unknown';
    delete $r{agent_id} if $r{scope} ne 'sub';
    return \%r;
}

# Set boundaries.count (the main boundary rows already accounted for, under seq.lock).
sub set_count {
    my ($sid_dir, $count, $owner) = @_;
    return unless defined $count;
    lock::with("$sid_dir/seq.lock", $owner, sub {
        util::write_atomic("$sid_dir/boundaries.count", "$count\n", 0600);
    });
}

1;
