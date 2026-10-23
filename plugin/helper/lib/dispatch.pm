package dispatch;
# lib/dispatch.pm: dispatch records <watch>/<sid>/dispatch/<nonce>.json (MOD-SPEC
# §2.3, BUILD-PLAN §3.4): exclusive create, 0600 in a 0700 directory; every key
# always present; compaction_seq never in it. Optional `handoff_ht` (8 hex, D-18 B3) only
# when the dispatch follows or interrupts a handoff turn. `idle` (IC-1 D1): the mod's idle
# predicate, true|false on a mod record (absent flag = false), null on a classic record;
# `idle_gap_s`: the dispatch ts minus the last main turn end, from the mod, else null.
# Optional `model` (MG-4): the session's model the mod read, last, only when given.
# Owner: WP-core.
use strict;
use warnings;
use utf8;

our @KEYS = qw(v nonce session_id actor agent_id trigger channel resume_pref midturn idle idle_gap_s tags
               instructions_sha8 instructions_bytes cc_version cc_version_src load_id pid pid_lstart ts);
our %TRIGGERS = map { $_ => 1 } qw(manual auto plugin precompute unknown);
our %CHANNELS = map { $_ => 1 } qw(mod-hook mod-self classic);
our %PREFS = map { $_ => 1 } qw(prompt.context sessionstart prompt.submit none);
our %TAGS = map { $_ => 1 } qw(midturn auto chain measured handoff queue);    # queue: QA-B3 (2026-10-23)

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
        idle               => defined $f{idle} ? jsonc::bool($f{idle}) : undef,
        idle_gap_s         => defined $f{idle_gap_s} ? 0 + $f{idle_gap_s} : undef,
        tags               => [grep { $TAGS{$_} } @{ $f{tags} || [] }],
        instructions_sha8  => $f{instructions_sha8},
        instructions_bytes => defined $f{instructions_bytes} ? 0 + $f{instructions_bytes} : undef,
        cc_version         => $f{cc_version},
        cc_version_src     => $f{cc_version_src},
        load_id            => $f{load_id},
        pid                => defined $f{pid} ? 0 + $f{pid} : undef,
        pid_lstart         => $f{pid_lstart},
        ts                 => $f{ts} // util::iso(util::now()),
        (defined $f{handoff_ht} ? (handoff_ht => $f{handoff_ht}) : ()),
        (defined $f{model} ? (model => $f{model}) : ()),
    );
}

# MG-4 (ratify R4 guard, 2026-10-23): a model id as `$.session.model()` gives it
# (`claude-opus-4-1`, `claude-sonnet-4-5[1m]`); anything else is not recorded.
sub valid_model {
    my ($m) = @_;
    return (defined $m && !ref $m && $m =~ m{\A[A-Za-z0-9][A-Za-z0-9._:/\@-]{0,79}(?:\[[0-9A-Za-z]{1,8}\])?\z}) ? 1 : 0;
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
