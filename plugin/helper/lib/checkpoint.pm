package checkpoint;
# lib/checkpoint.pm: the pre-compaction checkpoint (MOD-SPEC §10). Owner: WP-core.
# Budget 10 s total; git 2 s, GSD 2 s, queue <= 5 s; a timed-out step reads
# `not measured (timeout)`. Never asks the model, never writes STATE.md, repo files
# or pins, never queues or adopts. Output <= 6 KB JSON; written to
# <watch>/<sid>/checkpoint/<nonce>.json by exclusive create.
use strict;
use warnings;

sub _shrink_json {
    my ($obj, $max) = @_;
    my $j = jsonc::encode_bytes($obj);
    return $j if length $j <= $max;
    for my $k (qw(evidence_map inventory gsd)) {
        while (ref $obj->{$k} eq 'ARRAY' && @{ $obj->{$k} } && length($j) > $max) {
            pop @{ $obj->{$k} };
            $j = jsonc::encode_bytes($obj);
        }
    }
    if (length($j) > $max) { $obj->{measured_block} = undef; $j = jsonc::encode_bytes($obj) }
    return $j;
}

# run(sid, nonce, budget_ms, measured, cwd, transcript) -> (json_bytes, obj)
sub run {
    my (%a) = @_;
    util::trace('checkpoint');
    my $sid = $a{sid};
    my $t0 = util::clock_ms();
    my $budget = $a{budget_ms} // 10000;
    my $deadline = $t0 + $budget;
    my $left = sub { my ($cap) = @_; my $l = $deadline - util::clock_ms(); $l = $cap if $l > $cap; return $l < 0 ? 0 : $l };
    my (%ms, @timeouts);
    my $sid_dir = rc::sid_dir();

    # inventory: newest sidecar slot; outputs exist? git-ignored?
    my $s0 = util::clock_ms();
    my $slot = defined $sid_dir ? sidecar::newest($sid_dir) : undef;
    my @inv;
    for my $t (@{ $slot ? $slot->{tasks} || [] : [] }) {
        my %r = (id => $t->{id}, kind => $t->{type}, status => $t->{status});
        if (defined $t->{output_path}) { $r{output} = $t->{output_path}; $r{exists} = jsonc::bool(-e $t->{output_path}) }
        push @inv, \%r;
    }
    push @inv, { id => $_, kind => 'cron', status => 'scheduled' } for @{ $slot ? $slot->{crons} || [] : [] };
    $ms{inventory} = util::clock_ms() - $s0;

    # git (2 s)
    $s0 = util::clock_ms();
    my $g = $left->(2000) > 50 ? git::measure($a{cwd}, $left->(2000)) : { status => 'timeout' };
    push @timeouts, 'git' if $g->{status} eq 'timeout';
    $ms{git} = util::clock_ms() - $s0;

    # GSD (2 s; a file read)
    $s0 = util::clock_ms();
    my $where = $g->{status} eq 'ok' ? git::where($a{cwd}, $left->(2000)) : {};
    my $gsd = gsd::read($where->{toplevel} // ($g->{status} eq 'not-git' ? undef : undef));
    $ms{gsd} = util::clock_ms() - $s0;

    # lane (<= 5 s), only when configured
    $s0 = util::clock_ms();
    my $lane;
    my $qc = rc::val('queue_cmd');
    if (defined $qc && $qc ne '') {
        $lane = $left->(5000) > 50 ? queue::lane($sid, $qc, $left->(5000)) : { status => 'timeout' };
        push @timeouts, 'lane' if $lane->{status} eq 'timeout';
        if ($lane->{status} ne 'ok' && !$lane->{silent}) { rc::emit('lane_unknown', [why => $lane->{why} // $lane->{status}]) }
    }
    $ms{lane} = util::clock_ms() - $s0;

    # evidence: the sweep (claims swept/<nonce6>)
    $s0 = util::clock_ms();
    my $bk = bucket::resolve($sid, $a{cwd}, undef, $where->{in_git} ? $where : undef);
    my $stem = util::stamp(util::now()) . '_' . substr($sid, 0, 8) . '-' . substr($a{nonce}, 0, 6);
    my $sw = $left->(8000) > 50
        ? sweep::run(sid => $sid, id6 => substr($a{nonce}, 0, 6), stem => $stem, transcript => $a{transcript},
                     budget_ms => $left->(8000), bucket => $bk->{path}, nonce => $a{nonce})
        : { rows => [], totals => {} };
    $ms{evidence} = util::clock_ms() - $s0;
    my @emap = map { { origin => $_->{origin}, copy => (defined $_->{copy} ? util::abbrev($_->{copy}) : undef), status => $_->{status} } }
               grep { $_->{status} ne 'missing' } @{ $sw->{rows} || [] };

    my $block;
    if ($a{measured}) {
        my $facts = measure::compact($sid, $a{cwd}, $a{nonce}, git => $g, lane => $lane, worktree => $where->{toplevel},
                                     evidence_rows => $sw->{rows}, max => 3000 - 40, quiet => 1);
        $block = measure::cap(["Measured facts (" . util::iso(util::now()) . "):", split(/\n/, $facts)], 3000);
    }
    $ms{total} = util::clock_ms() - $t0;
    my $obj = {
        measured_block => $block,
        lane           => ($lane && $lane->{status} eq 'ok' ? $lane->{lane} : undef),
        queued_line    => ($lane && $lane->{status} eq 'ok' ? $lane->{queued_line} : undef),
        gsd            => ($gsd->{status} eq 'ok' ? $gsd->{lines} : []),
        git            => ($g->{status} eq 'ok' ? { branch => $g->{branch}, head => $g->{head}, count => $g->{count},
                                                    ahead => $g->{ahead}, behind => $g->{behind} }
                                                 : $g->{status} eq 'timeout' ? 'not measured (timeout)' : $g->{status}),
        inventory      => \@inv,
        evidence_map   => [@emap[0 .. ($#emap > 7 ? 7 : $#emap)]],
        checkpoint_ms  => jsonc::obj(map { ($_ => $ms{$_} // 0) } qw(inventory git gsd lane evidence total)),
        timeouts       => \@timeouts,
    };
    my $json = _shrink_json($obj, 6 * 1024);
    if (defined $sid_dir) {
        eval { util::write_excl("$sid_dir/checkpoint/$a{nonce}.json", $json . "\n", 0600) };
    }
    my $t = $sw->{totals} || {};
    rc::emit('checkpoint', [nonce => $a{nonce}, checkpoint_ms => $obj->{checkpoint_ms}, timeouts => \@timeouts,
                            evidence => { copied => $t->{copied} // 0, redacted => $t->{redacted} // 0, withheld => $t->{withheld} // 0,
                                          ref_only => $t->{'ref-only'} // 0, dup => $t->{dup} // 0 },
                            measured => jsonc::bool(defined $block), inventory => scalar @inv]);
    return ($json, $obj);
}

1;
