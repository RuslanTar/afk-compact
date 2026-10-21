package dispatch;
# lib/dispatch.pm: dispatch records <watch>/<sid>/dispatch/<nonce>.json (MOD-SPEC
# §2.3, BUILD-PLAN §3.4): exclusive create, 0600 in a 0700 directory; every key
# always present; compaction_seq never in it. Owner: WP-core.
use strict;
use warnings;

our @KEYS = qw(v nonce session_id actor agent_id trigger channel resume_pref midturn tags
               instructions_sha8 instructions_bytes cc_version load_id pid pid_lstart ts);
our %TRIGGERS = map { $_ => 1 } qw(manual auto plugin precompute unknown);
our %CHANNELS = map { $_ => 1 } qw(mod-hook mod-self classic);
our %PREFS = map { $_ => 1 } qw(prompt.context sessionstart prompt.submit none);
our %TAGS = map { $_ => 1 } qw(midturn auto chain measured);

sub path { my ($watch, $sid, $nonce) = @_; return "$watch/$sid/dispatch/$nonce.json" }

# record(%f) -> ordered object with every key
sub record {
    my (%f) = @_;
    my $actor = $f{actor} // 'unknown';
    my $agent = ($actor eq 'main' || $actor eq 'unknown') ? undef : $actor;
    return jsonc::obj(
        v                  => 1,
        nonce              => $f{nonce},
        session_id         => $f{session_id},
        actor              => $actor,
        agent_id           => $agent,
        trigger            => $f{trigger} // 'unknown',
        channel            => $f{channel},
        resume_pref        => $f{resume_pref} // 'none',
        midturn            => jsonc::bool($f{midturn}),
        tags               => [grep { $TAGS{$_} } @{ $f{tags} || [] }],
        instructions_sha8  => $f{instructions_sha8},
        instructions_bytes => defined $f{instructions_bytes} ? 0 + $f{instructions_bytes} : undef,
        cc_version         => $f{cc_version},
        load_id            => $f{load_id},
        pid                => defined $f{pid} ? 0 + $f{pid} : undef,
        pid_lstart         => $f{pid_lstart},
        ts                 => $f{ts} // util::iso(util::now()),
    );
}

# write(watch, sid, record) -> 1 created, 0 exists
sub write {
    my ($watch, $sid, $rec) = @_;
    my %h = @$rec;
    util::mkdir_p("$watch/$sid/dispatch");
    chmod 0700, "$watch/$sid/dispatch", "$watch/$sid";
    return util::write_excl(path($watch, $sid, $h{nonce}), jsonc::encode_bytes($rec) . "\n", 0600);
}

sub read {
    my ($watch, $sid, $nonce) = @_;
    return undef unless defined $watch && defined $nonce && $nonce =~ /^[0-9a-f]{8}$/;
    my $raw = util::read_file(path($watch, $sid, $nonce)) // return undef;
    my $j = eval { jsonc::decode($raw) };
    return ref $j eq 'HASH' ? $j : undef;
}

# all(watch, sid) -> records sorted by ts (oldest first), each with _epoch
sub all {
    my ($watch, $sid) = @_;
    my @out;
    for my $f (util::list_dir("$watch/$sid/dispatch")) {
        next unless $f =~ /^([0-9a-f]{8})\.json$/;
        my $r = dispatch::read($watch, $sid, $1) or next;
        $r->{_epoch} = util::parse_iso($r->{ts}) // 0;
        push @out, $r;
    }
    return sort { $a->{_epoch} <=> $b->{_epoch} || $a->{nonce} cmp $b->{nonce} } @out;
}

sub is_main { my ($r) = @_; return $r && !defined $r->{agent_id} && ($r->{channel} // '') =~ /^mod-(hook|self)$/ ? 1 : 0 }
sub is_mod  { my ($r) = @_; return $r && ($r->{channel} // '') =~ /^mod-(hook|self)$/ ? 1 : 0 }

1;
