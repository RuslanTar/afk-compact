package queue;
# lib/queue.pm: the optional queue integration (OD-21; MOD-SPEC §1.2, §10). Owner: WP-core.
# Called only when `queue_cmd` is set; only `list --json --session <sid>` here
# (the resume skill's `adopt` lives in WP-skills); never `add`, never adopt.
use strict;
use warnings;

# call(argv, budget_ms) -> run result (the user's PERL5LIB/PERLLIB restored for the child)
sub call {
    my ($argv, $budget_ms) = @_;
    util::trace('queue_cmd');
    my %env;
    $env{PERL5LIB} = $ENV{STORE_ORIG_PERL5LIB} if defined $ENV{STORE_ORIG_PERL5LIB} && $ENV{STORE_ORIG_PERL5LIB} ne '';
    $env{PERLLIB} = $ENV{STORE_ORIG_PERLLIB} if defined $ENV{STORE_ORIG_PERLLIB} && $ENV{STORE_ORIG_PERLLIB} ne '';
    return util::run($argv, timeout_ms => $budget_ms // 5000, env => \%env, max_out => 256 * 1024);
}

my $LANE_RE = qr/^(lane|auto):[A-Za-z0-9._\/-]+$/;

# lane(sid, queue_cmd, budget_ms) -> {status: ok|off|unknown|timeout, lane, open, ids, label, queued_line}
# The `list --json` reply is the v1 contract `queue-stub/v1` (ROOT-RULINGS F2-8,
# provisional): one object {"schema": "queue-stub/v1", "session", "lane": "lane:<repo>/<name>"
# | "auto:…" | null, "open": n, "pending": n, "preview": bool, "held_by": sid | null,
# "lanes": [{id, holder, open, preview}]}. A reply naming another schema is not read;
# one without `schema` is read as v1. Also taken: `minted` as `preview`, `label`, and the
# open items as `items`/`open`/`pending` arrays (ids, or objects with `id`).
our $SCHEMA = 'queue-stub/v1';
sub lane {
    my ($sid, $cmd, $budget_ms) = @_;
    return { status => 'off' } unless defined $cmd && $cmd ne '';
    return { status => 'unknown', why => 'not-executable' } unless -x $cmd;
    my $r = call([$cmd, 'list', '--json', '--session', $sid], $budget_ms);
    return { status => 'timeout' } if $r->{timed_out};
    return { status => 'unknown', why => 'exit' } unless $r->{exit} == 0;
    my $j = eval { jsonc::decode($r->{out}) };
    return { status => 'unknown', why => 'not-json' } unless ref $j eq 'HASH';
    return { status => 'unknown', why => 'schema' } if defined $j->{schema} && (ref $j->{schema} || $j->{schema} ne $SCHEMA);
    my $lane = $j->{lane};
    return { status => 'unknown', why => 'no-lane' } unless defined $lane && !ref $lane && $lane =~ $LANE_RE;
    return { status => 'unknown', why => 'preview' } if $j->{preview} || $j->{minted};
    my @ids;
    my $count = 0;
    for my $k (qw(items open pending)) {
        my $v = $j->{$k};
        next unless defined $v;
        if (ref $v eq 'ARRAY') {
            for my $it (@$v) {
                my $id = ref $it eq 'HASH' ? $it->{id} : $it;
                push @ids, $id if defined $id && !ref $id && $id =~ /^[A-Za-z0-9._:\/-]{1,64}$/;
            }
            $count = scalar @$v if @$v > $count;
        } elsif (!ref $v && $v =~ /^\d+$/) {
            $count = 0 + $v if $v > $count;
        }
        last if $count;
    }
    my $named = $lane =~ /^lane:/ ? 1 : 0;
    # "has something pending" (MOD-SPEC §10): v1's `pending` count when given, else the open count
    my $pending = (defined $j->{pending} && !ref $j->{pending} && $j->{pending} =~ /^\d+$/) ? 0 + $j->{pending} : $count;
    return { status => 'unknown', why => 'auto-empty', silent => 1 } if !$named && !$pending && !$count;
    my $label = (defined $j->{label} && !ref $j->{label} && $j->{label} =~ /^[^\n]{1,80}$/) ? $j->{label} : $lane;
    my $line;
    if ($count) {
        my $idl = @ids ? ' (' . join(', ', @ids[0 .. ($#ids > 7 ? 7 : $#ids)]) . (@ids > 8 ? ', …' : '') . ')' : '';
        $line = "Queued: $count open in $label$idl; answered only via the queue; never re-ask.";
    }
    return { status => 'ok', lane => $lane, open => $count, ids => \@ids, label => $label, queued_line => $line };
}

1;
