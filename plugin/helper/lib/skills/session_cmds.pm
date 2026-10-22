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

# pin --sid S --resumed-from PATH [--lane ID] → `pinned <bucket>`.
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
    return 0;
}

my %RELATION = map { $_ => 1 } qw(same-session successor other unselected);

# receipt … → one content-free resume_receipt row; prints nothing.
sub receipt {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'handoff=s', 'relation=s', 'tier=s', 'calls=s', 'drift=s', 'bg=s',
        'questions=s', 'adopt=s', 'cmds-asked=s');
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    die skills::cli::usage('--relation same-session|successor|other|unselected') unless defined $o->{relation} && $RELATION{ $o->{relation} };
    die skills::cli::usage('--tier T1|T2|T3') unless defined $o->{tier} && $o->{tier} =~ /\AT[123]\z/;
    for my $k (qw(calls questions)) {
        die skills::cli::usage("--$k N") unless defined $o->{$k} && $o->{$k} =~ /\A\d{1,4}\z/;
    }
    # T-TEXT E7: handoff commands shown and asked under Rule 2 (optional; absent = not counted)
    die skills::cli::usage('--cmds-asked N') if defined $o->{'cmds-asked'} && $o->{'cmds-asked'} !~ /\A\d{1,4}\z/;
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
