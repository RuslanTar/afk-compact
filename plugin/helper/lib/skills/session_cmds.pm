package skills::session_cmds;
# lib/skills/session_cmds.pm: `lane adopt`, `pin` and `receipt` (resume R4,
# R9; TPL §6; D-21 `lane:` ids only; OD-21 queue only when configured).
use strict;
use warnings;
use utf8;
use Cwd ();
use skills::util;
use skills::cli;
use skills::ctx;
use skills::core;
use skills::store;
use skills::gitfacts;

my $ADOPT_RE = qr/\Alane:[A-Za-z0-9._\/-]+\z/;
my $LANE_RE  = qr/(?:lane|auto):[A-Za-z0-9._\/-]+/;

# Q-ADAPTER QA-2: adopt refusals by exit code (the reason line is read from stdout).
my %ADOPT_EXIT = (3 => 'held', 4 => 'no-lane', 6 => 'error', 2 => 'unsupported');

# lane adopt --lane ID [--if-free] → `lane: <id>`, a refusal, or `queue: off`. Passes
# --must-exist when the cached list reply's commands hold adopt:must-exist. Exit 3 is
# `held holder=<sid> kind=<process|heartbeat>` (the pair as the tool printed it), 4 no-lane,
# 6 error, 2 unsupported, any other code `queue exit N`. Never adds or answers anything.
sub lane {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'lane=s', 'if-free');
    die skills::cli::usage('lane adopt --lane ID [--if-free]') unless @$argv == 1 && $argv->[0] eq 'adopt';
    my $ctx = skills::ctx::new({});
    my $cmd = $ctx->{settings}{queue_cmd};
    if (skills::util::unset_value($cmd)) { skills::cli::say('queue: off'); return 0 }
    die skills::cli::usage('--lane ID') unless defined $o->{lane} && $o->{lane} ne '';
    die skills::cli::refuse('lane-id (only lane: ids are adopted)') unless $o->{lane} =~ $ADOPT_RE;
    die skills::cli::refuse('queue degraded (not-executable)') unless -f skills::util::bytes($cmd) && -x _;
    skills::ctx::resolve_sid($ctx, undef);
    my @argv = ($cmd, 'adopt', '--lane', $o->{lane});
    push @argv, '--if-free' if $o->{'if-free'};
    push @argv, '--must-exist' if skills::core::queue_must_exist($cmd);
    my $r = skills::core::queue_call(\@argv, 5000);
    die skills::cli::refuse('queue-timeout') if $r->{timed_out};
    my ($first) = grep { /\S/ } split /\n/, ($r->{out} // '');
    $first //= '';
    $first =~ s/[\x00-\x1f\x7f-\x9f]//g;
    $first = substr($first, 0, 200);
    if ($r->{rc} != 0) {
        my $kind = $ADOPT_EXIT{ $r->{rc} } // "queue exit $r->{rc}";
        if ($kind eq 'held') {
            my ($h) = $first =~ /\bholder=([A-Za-z0-9._:-]{1,64})(?=\s|\z)/;
            my ($k) = $first =~ /\bkind=(process|heartbeat)(?=\s|\z)/;
            $kind .= " holder=$h" if defined $h;
            $kind .= " kind=$k" if defined $k;
        }
        die skills::cli::refuse($kind);
    }
    my ($bound) = $first =~ /($LANE_RE)/;
    if (!defined $bound) {
        my $d = eval { skills::util::json_decode($r->{out}) };
        $bound = $d->{lane} if ref $d eq 'HASH' && defined $d->{lane} && !ref $d->{lane} && $d->{lane} =~ /\A$LANE_RE\z/;
    }
    die skills::cli::refuse('queue answer names no lane') unless defined $bound;
    skills::cli::say("lane: $bound");
    skills::cli::say("mismatch: asked for $o->{lane}; nothing queued") if $bound ne $o->{lane};
    return 0;
}

# pin --sid S --resumed-from PATH [--lane ID] → `pinned <bucket>`; for another session's handoff
# then `relation: successor (handoff-resume)` and the `Approvals …` lines of `measure <handoff>`
# when link_resume wrote the link, else `relation: other (not linked: <why>)`.
sub pin {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'sid=s', 'resumed-from=s', 'lane=s');
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    die skills::cli::usage('--resumed-from PATH') unless defined $o->{'resumed-from'} && $o->{'resumed-from'} ne '';
    my $ctx = skills::ctx::new({});
    my $id = skills::ctx::resolve_sid($ctx, $o->{sid});
    die skills::cli::refuse('no-session') if ($id->{degraded} // '') eq 'no-session-id';
    my $rr = skills::core::roots_check($ctx->{settings});
    die skills::cli::refuse($rr) if $rr;
    my $p = skills::util::abs_path($o->{'resumed-from'});
    die skills::cli::refuse('not-found') unless defined $p && -f $p;
    my $root = skills::util::abs_path($ctx->{root}) // $ctx->{root};
    die skills::cli::refuse('not-under-root') unless index($p, "$root/") == 0;
    my $lane;
    if (defined $o->{lane} && !skills::util::unset_value($o->{lane})) {
        die skills::cli::refuse('lane-id') unless $o->{lane} =~ $ADOPT_RE;
        $lane = $o->{lane};
    }
    my $bucket = skills::store::bucket_of($p);
    (my $rel = $bucket) =~ s/\A\Q$root\E\///;
    my $w = skills::gitfacts::where(skills::util::cwd());
    my ($ok, $res) = skills::ctx::pin_update($ctx, $id->{sid}, sub {
        my ($cur) = @_;
        my %n = %$cur;
        @n{qw(bucket bucket_path bucket_source resumed_from)} = ($rel, $bucket, 'pin', $p);
        $n{worktree} = $w->{worktree} if $w->{worktree};
        $n{lane} = $lane if defined $lane;
        return \%n;
    });
    die skills::cli::refuse('pin-locked') unless $ok;
    skills::cli::say("pinned $rel");
    # The handoff-resume link (review of bcdaca6): resuming an ended predecessor's newest handoff
    # makes this session its successor, so its file is own from here on (resume Rule 2) and its
    # checked approvals carry (spec §4 Approval (scoped)). The relation and the approvals that now
    # carry are printed; they replace what locate and measure printed before the pin.
    my ($st, $why) = link_resume($ctx, $id, $p);
    if ($st eq 'linked') {
        skills::cli::say('relation: successor (handoff-resume)');
        require skills::approvals;
        my $d = skills::store::read_doc($p);
        my ($lines) = $d ? skills::approvals::handoff_lines($d, $ctx, $id->{sid}) : ([]);
        skills::cli::say($_) for @{ $lines || [] };
    } elsif ($st eq 'none') {
        skills::cli::say("relation: other (not linked: $why)");
    }
    return 0;
}

# Lineage reasons that pass approvals on (skills::approvals %CARRY_REASON): a predecessor that
# already has such a successor is never linked again. The claim file is skills::approvals
# claim_path, which also reads it: the claim splits the predecessor's line at its time (_claim_cut)
# and the resumed predecessor's quote checks start there (quote_floor).
our %LINK_SOURCES = map { $_ => 1 } qw(startup resume);
our $FM_READ_MAX = 4096;

# link_resume(ctx, id, handoff path) -> ('linked') | ('none', why) | ('same') | ('chain'):
# write `.sessions/<sid>.lineage.json` {previous_session_id: the handoff's session,
# lineage_reason: handoff-resume} (review of bcdaca6; spec §4 Approval (scoped) names the link,
# nothing wrote it). Fail closed: the link is written only when all hold, else ('none', why):
#   - the file is a `kind: handoff` this plugin wrote in the private store, integrity ok (a marker
#     under the former name counts, owner xxxxxxxx-26), not an export or an imported copy, written
#     by another session P;
#   - this session has a per-process record, every one started as startup or resume (a fork, a
#     background copy, a /clear successor or a session with no record is never linked), its
#     identity is not degraded, and it has no lineage link yet (write-once);
#   - P has ended (sessions::ended: no live record; a session with no record never qualifies) and
#     never ended by /clear (a /clear successor already continues it);
#   - the file is P's newest handoff in the store (an older one may hold approvals P used later).
#     This compares handoff dates only: a `once` approval P used after writing that handoff (P
#     kept working, or compacted, before it ended) still reads `not yet used`, and only resume's
#     effect-absent check (Rule 3) guards it, as for a /clear successor (residual, SPEC-DELTAS
#     HR-1);
#   - P is claimed for this session by exclusive create of `.sessions/successors/<P>.json`, so a
#     second session that resumes P's handoff gets no link (a `once` approval is never lent to two
#     sessions).
sub link_resume {
    my ($ctx, $id, $p) = @_;
    my $sid = $id->{sid};
    my $d = skills::store::read_doc($p) or return ('none', 'unreadable');
    my $fm = $d->{fm} || {};
    my $ps = $fm->{session_id} // '';
    return ('same') if $ps eq $sid;
    my $chain = skills::ctx::chain($ctx, $sid);
    return ('chain') if grep { $_->{sid} eq $ps } @$chain;
    return ('none', 'no session id') unless skills::ctx::valid_sid($ps);
    return ('none', 'not a handoff') unless skills::store::is_handoff($d);
    return ('none', 'a repository export') if skills::store::is_export($d);
    return ('none', 'an imported copy') if skills::store::imported($d);
    my $int = skills::store::integrity($d, alias => 1);
    return ('none', "integrity $int->{integrity}") unless ($int->{integrity} // '') eq 'ok';
    return ('none', 'identity degraded') if $id->{degraded};
    return ('none', 'this session has a lineage link') if skills::ctx::lineage_of($ctx, $sid);
    my (@mine, @pend);
    for my $r (@{ skills::ctx::records($ctx) }) {
        my $rs = $r->{data}{session_id} // '';
        push @mine, $r if $r->{state} eq 'live' && $rs eq $sid;
        push @pend, $r if $r->{state} eq 'ended' && $rs eq $ps;
    }
    return ('none', 'no start record') unless @mine;
    for my $r (@mine) {
        my $src = $r->{data}{source};
        return ('none', 'started as ' . (defined $src && !ref $src && $src =~ /\A[a-z-]{1,16}\z/ ? $src : 'unknown'))
            unless defined $src && !ref $src && $LINK_SOURCES{$src};
    }
    return ('none', 'predecessor not ended') unless skills::core::session_ended($ps);
    return ('none', 'predecessor cleared') if grep { ($_->{data}{reason} // '') eq 'clear' } @pend;
    return ('none', 'not the newest') unless _newest_of($ctx, $ps, $d);
    require skills::approvals;
    my $claim = skills::approvals::claim_path($ctx, $ps);
    (my $sdir = $claim) =~ s{/[^/]+\z}{};
    my $json = skills::util::json_encode({ session_id => $sid, lineage_reason => 'handoff-resume', ts => skills::util::iso_local() }) . "\n";
    my $made = eval { skills::util::mkdir_p($sdir); skills::util::write_excl($claim, $json, 0600) };
    return ('none', 'claim failed') unless defined $made;
    if (!$made) {
        my $c = eval { skills::util::json_decode(skills::util::read_file($claim, 65536)) };
        return ('none', 'claimed by another session') unless ref $c eq 'HASH' && ($c->{session_id} // '') eq $sid;
    }
    my $lin = skills::util::json_encode({ previous_session_id => $ps, lineage_reason => 'handoff-resume' }) . "\n";
    my $w = eval { skills::util::write_excl("$ctx->{root}/.sessions/$sid.lineage.json", $lin, 0600) };
    return ('none', 'this session has a lineage link') unless $w;
    return ('linked');
}

# 1 when no other `kind: handoff` file of session $ps in the store (top level of any bucket, not an
# imported copy) is as new as $d or newer, by frontmatter date; a file with no readable date
# beside a dated pick counts as newer (fail closed).
sub _newest_of {
    my ($ctx, $ps, $d) = @_;
    my $mine = skills::util::abs_path($d->{path}) // $d->{path};
    my $t = $d->{epoch};
    return 0 unless defined $t;
    for my $repo (@{ skills::store::repos($ctx->{root}) }) {
        for my $b (@{ skills::store::buckets($ctx->{root}, $repo) }) {
            for my $f (skills::util::list_dir($b)) {
                next unless $f =~ /\.md\z/ && -f "$b/$f";
                my $path = "$b/$f";
                next if (skills::util::abs_path($path) // $path) eq $mine;
                my $head = skills::util::read_text($path, $FM_READ_MAX);
                next unless defined $head && $head =~ /\A---/;
                # The frontmatter from the first 4 KB; a longer one from the whole file.
                my $x = $head =~ /\n---[ \t]*(?:\n|\z)/ ? skills::store::parse($head) : skills::store::read_doc($path);
                next unless $x;
                my $fm = $x->{fm} || {};
                next unless ($fm->{session_id} // '') eq $ps && ($fm->{kind} // '') eq 'handoff';
                next if defined $fm->{imported_from} && $fm->{imported_from} ne '';
                my $e = skills::util::iso_to_epoch($fm->{date});
                return 0 if !defined $e || $e >= $t;
            }
        }
    }
    return 1;
}

my %RELATION = map { $_ => 1 } qw(same-session successor other unselected);

# receipt … → one content-free resume_receipt row; prints nothing.
sub receipt {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'handoff=s', 'relation=s', 'tier=s', 'calls=s', 'drift=s', 'bg=s',
        'questions=s', 'adopt=s', 'cmds-asked=s', 'cmds-run=s', 'approvals=s');
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    die skills::cli::usage('--relation same-session|successor|other|unselected') unless defined $o->{relation} && $RELATION{ $o->{relation} };
    die skills::cli::usage('--tier T1|T2|T3') unless defined $o->{tier} && $o->{tier} =~ /\AT[123]\z/;
    for my $k (qw(calls questions)) {
        die skills::cli::usage("--$k N") unless defined $o->{$k} && $o->{$k} =~ /\A\d{1,4}\z/;
    }
    # T-TEXT E7: handoff commands shown and asked under Rule 2 (optional; absent = not counted)
    die skills::cli::usage('--cmds-asked N') if defined $o->{'cmds-asked'} && $o->{'cmds-asked'} !~ /\A\d{1,4}\z/;
    # SR-8 (owner xxxxxxxx-15 + 03:42): handoff commands run without asking (optional, as --cmds-asked)
    die skills::cli::usage('--cmds-run N') if defined $o->{'cmds-run'} && $o->{'cmds-run'} !~ /\A\d{1,4}\z/;
    # SR-8 / AP-6 (D-2 replaced by scoped carry, owner 2026-10-23 01:5x): approvals carried, used and
    # asked again, as counts only. Absent = not counted (null fields).
    my %ap;
    if (defined $o->{approvals} && $o->{approvals} !~ /\A(?:none|-)?\z/) {
        for my $kv (split /,/, $o->{approvals}) {
            die skills::cli::usage('--approvals carried=n,used=n,asked=n')
                unless $kv =~ /\A(carried|used|asked)=(\d{1,4})\z/ && !exists $ap{$1};
            $ap{$1} = 0 + $2;
        }
    }
    elsif (defined $o->{approvals}) {
        %ap = (carried => 0, used => 0, asked => 0);
    }
    my @drift = _tokens($o->{drift});
    my %bg;
    for my $kv (split /,/, ($o->{bg} // '')) {
        next if $kv eq '' || $kv =~ /\A(?:none|-)\z/;
        die skills::cli::usage('--bg status=count,…') unless $kv =~ /\A([A-Za-z-]{1,24})=(\d{1,4})\z/;
        $bg{ uc $1 } = 0 + $2;
    }
    my ($adopt) = _tokens($o->{adopt});
    my $ctx = skills::ctx::new({});
    skills::ctx::resolve_sid($ctx, undef);
    my $h = $o->{handoff};
    my $hrel = 'none';
    if (defined $h && $h ne '' && $h ne 'none') {
        my $p = skills::util::abs_path($h) // $h;
        my $root = skills::util::abs_path($ctx->{root}) // $ctx->{root};
        $hrel = index($p, "$root/") == 0 ? substr($p, length($root) + 1) : 'external';
    }
    $ctx->log('resume_receipt', {
        handoff => $hrel, relation => $o->{relation}, tier => $o->{tier}, calls => 0 + $o->{calls},
        drift => \@drift, bg => \%bg, questions => 0 + $o->{questions}, adopt => $adopt // 'none',
        cmds_asked => (defined $o->{'cmds-asked'} ? 0 + $o->{'cmds-asked'} : undef),
        cmds_run => (defined $o->{'cmds-run'} ? 0 + $o->{'cmds-run'} : undef),
        approvals_carried => (defined $o->{approvals} ? $ap{carried} // 0 : undef),
        approvals_used => (defined $o->{approvals} ? $ap{used} // 0 : undef),
        approvals_asked => (defined $o->{approvals} ? $ap{asked} // 0 : undef),
    });
    return 0;
}

# Comma-separated enum tokens only (content-free).
sub _tokens {
    my ($v) = @_;
    return () unless defined $v;
    my @t;
    for my $x (split /,/, $v) {
        $x =~ s/\A\s+|\s+\z//g;
        next if $x eq '' || $x =~ /\A(?:none|-)\z/;
        die skills::cli::usage("bad token '$x'") unless $x =~ /\A[a-z0-9][a-z0-9_:-]{0,31}\z/i;
        push @t, lc $x;
    }
    return @t;
}

1;
