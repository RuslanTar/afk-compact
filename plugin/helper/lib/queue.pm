package queue;
# lib/queue.pm: the optional queue integration (OD-21; MOD-SPEC §1.2, §10, §10.3). Owner:
# WP-core. Called only when `queue_cmd` is set: `list --json --session <sid>` (lane) and,
# for `queue-add` only, `add --json …` (contract v2, D-10). Never adopt here (the resume
# skill's `adopt` lives in WP-skills); the mod, the checkpoint and the hooks never add.
# The caps cache <watch>/queue-caps.json is keyed by the queue_cmd path, mtime and size:
# a `commands` array in a list reply is kept there (absent = contract v1: list and
# adopt only), and an `add` the tool rejected as unsupported is kept for 24 h.
use strict;
use warnings;
use utf8;

# call(argv, budget_ms) -> run result (the user's PERL5LIB/PERLLIB restored for the child)
# `out` stays the bytes the tool printed (WP-skills callers decode their own); lane() and
# add() decode it once where they read it (MOD-SPEC §2.6 text encoding).
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
    my $j = eval { jsonc::decode(util::text($r->{out})) };
    return { status => "unknown", why => "not-json" } unless ref $j eq 'HASH';
    return { status => 'unknown', why => 'schema' } if defined $j->{schema} && (ref $j->{schema} || $j->{schema} ne $SCHEMA);
    eval { caps_put($cmd, commands => (ref $j->{commands} eq 'ARRAY' ? [grep { defined && !ref } @{ $j->{commands} }] : undef)) };
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

# ---------------------------------------------------------------- caps cache
our $CAPS_TTL_S = 24 * 3600;

sub caps_path { my $w = rc::watch(); return defined $w ? "$w/queue-caps.json" : undef }

sub _caps_key {
    my ($cmd) = @_;
    my @st = stat $cmd or return undef;
    return join('|', $cmd, $st[9], $st[7]);
}

# caps_get(cmd) -> {commands => [..]|undef, add => 'unsupported'|undef} for this file's
# current path+mtime+size (an add verdict older than 24 h is dropped), or {}
sub caps_get {
    my ($cmd) = @_;
    my $f = caps_path() // return {};
    my $key = _caps_key($cmd) // return {};
    my $j = eval { jsonc::decode(util::read_file($f) // '') };
    my $e = ref $j eq 'HASH' && ref $j->{$key} eq 'HASH' ? $j->{$key} : return {};
    my %c = (commands => (ref $e->{commands} eq 'ARRAY' ? $e->{commands} : undef));
    $c{add} = $e->{add} if defined $e->{add} && util::now() - (util::parse_iso($e->{add_ts} // '') // 0) <= $CAPS_TTL_S;
    $c{listed} = $e->{listed} ? 1 : 0;
    return \%c;
}

# caps_put(cmd, commands => [..]|undef | add => verdict): one whole-file write; entries
# of other keys (an older build of the tool) are dropped.
sub caps_put {
    my ($cmd, %o) = @_;
    my $f = caps_path() // return;
    my $key = _caps_key($cmd) // return;
    my $j = eval { jsonc::decode(util::read_file($f) // '') };
    my $e = ref $j eq 'HASH' && ref $j->{$key} eq 'HASH' ? $j->{$key} : {};
    if (exists $o{commands}) { $e->{commands} = $o{commands}; $e->{listed} = jsonc::true() }
    if (exists $o{add}) { $e->{add} = $o{add}; $e->{add_ts} = util::iso(util::now()) }
    util::write_atomic($f, jsonc::encode_bytes({ $key => $e }) . "\n", 0600);
}

# add_supported(cmd) -> 0 when the cache says the tool has no `add` (a cached unsupported
# verdict, or a list reply without "add" in commands, or with no commands array: v1)
sub add_supported {
    my ($cmd) = @_;
    my $c = caps_get($cmd);
    return 0 if ($c->{add} // '') eq 'unsupported';
    return 0 if $c->{listed} && !grep { $_ eq 'add' } @{ $c->{commands} || [] };
    return 1;
}

# ---------------------------------------------------------------- add (D-10, MOD-SPEC §10.3)
our %ADD_EXIT = (3 => 'held', 4 => 'no-lane', 5 => 'invalid', 6 => 'error');
our $ADD_SCHEMA = 'queue-add/v1';
our $ADD_MAX = 4096;

# add(cmd, sid, client_id, lane_name, draft_json_bytes, budget_ms) -> {result, id, exit, ms}
# result: queued | exists | unsupported | held | no-lane | invalid | error | timeout
sub add {
    my ($cmd, $sid, $cid, $lane_name, $json, $budget_ms) = @_;
    my @argv = ($cmd, 'add', '--json', '--session', $sid, '--client-id', $cid);
    push @argv, '--lane-name', $lane_name if defined $lane_name && $lane_name ne '';
    my $t0 = util::clock_ms();
    util::trace('queue_cmd');
    my %env;
    $env{PERL5LIB} = $ENV{STORE_ORIG_PERL5LIB} if defined $ENV{STORE_ORIG_PERL5LIB} && $ENV{STORE_ORIG_PERL5LIB} ne '';
    $env{PERLLIB} = $ENV{STORE_ORIG_PERLLIB} if defined $ENV{STORE_ORIG_PERLLIB} && $ENV{STORE_ORIG_PERLLIB} ne '';
    my $r = util::run(\@argv, timeout_ms => $budget_ms // 5000, env => \%env, stdin => $json, max_out => 64 * 1024);
    my %res = (exit => $r->{exit}, ms => util::clock_ms() - $t0);
    return { %res, result => 'timeout' } if $r->{timed_out};
    my $out = util::text($r->{out} // "");
    if ($r->{exit} == 0) {
        my ($line) = grep { /\S/ } split /\n/, $out;
        my $j = defined $line ? eval { jsonc::decode($line) } : undef;
        my $st = ref $j eq 'HASH' ? ($j->{status} // '') : '';
        my $id = ref $j eq 'HASH' ? $j->{id} : undef;
        return { %res, result => 'error' } unless $st =~ /^(queued|exists)$/ && defined $id && !ref $id && $id =~ /^[A-Za-z0-9._:\/-]{1,128}$/;
        return { %res, result => $st, id => $id };
    }
    return { %res, result => 'unsupported' } if $r->{exit} == 2 && $out !~ /^REFUSED:/m;
    return { %res, result => $ADD_EXIT{ $r->{exit} } // 'error' };
}

1;
