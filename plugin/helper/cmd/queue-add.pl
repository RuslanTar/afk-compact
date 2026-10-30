# cmd/queue-add.pl: `queue-add --sid S --nonce N [--file F]` (D-10, small-rulings §1.5;
# MOD-SPEC §10.3; BUILD-PLAN §3.1). Owner: WP-core.
# The main model runs it in the checkpoint's step-3 batch, one call per user-owned
# question, with one JSON draft on stdin ({question, kind, options, blocks, context?}).
# Steps: queue_cmd set and executable (else off, no exec) -> parse and bound the draft
# (invalid) -> secret scan (HARD: secret, nothing sent; WARN: redacted in place) ->
# ledger <watch>/<sid>/queue-adds.jsonl (a queued or exists row for this client id:
# EXISTS, no exec) -> caps cache (add unsupported: no exec) -> `queue_cmd add --json
# --session <sid> --client-id <id> [--lane-name <bucket slug>]` with the queue-add/v1
# draft on stdin (5 s) -> ledger row, one content-free `queue_add {result, exit, ms}`
# row. Prints exactly one line: `QUEUED <id>` | `EXISTS <id>` | `NOT QUEUED (<result>):
# keep it in Questions` (`invalid` and `secret` put the rule before it). Exits 0 in every
# case, so the model's Bash call never fails and is never retried. Never adopt, never --lane.
use strict;
use warnings;
use utf8;

package cmd_queue_add;

our $BUDGET_MS = 5000;
our %KIND = map { $_ => 1 } qw(choice approval open);
# field => max bytes (UTF-8)
our %MAX = (question => 600, blocks => 200, context => 400, label => 40, description => 300,
            recommendation_none_reason => 200);

sub _bytes { my ($s) = @_; my $c = $s; utf8::encode($c) if utf8::is_utf8($c); return length $c }
sub _str { my ($v) = @_; return defined $v && !ref $v && $v =~ /\S/ ? 1 : 0 }
sub _bool { my ($v) = @_; return !defined $v || jsonc::is_bool($v) ? 1 : 0 }

# check(draft) -> undef when it is bounded, else the rule it breaks
sub check {
    my ($d) = @_;
    return 'not-an-object' unless ref $d eq 'HASH';
    return 'question' unless _str($d->{question}) && $d->{question} =~ /\?\s*\z/;
    return 'question-size' if _bytes($d->{question}) > $MAX{question};
    return 'kind' unless defined $d->{kind} && !ref $d->{kind} && $KIND{ $d->{kind} };
    return 'blocks' unless _str($d->{blocks});
    return 'blocks-size' if _bytes($d->{blocks}) > $MAX{blocks};
    if (defined $d->{context}) { return 'context' unless _str($d->{context}) && _bytes($d->{context}) <= $MAX{context} }
    my $opts = $d->{options};
    if ($d->{kind} eq 'open') {
        return 'options-on-open' if defined $opts && !(ref $opts eq 'ARRAY' && !@$opts);
        return undef;
    }
    return 'options' unless ref $opts eq 'ARRAY' && @$opts >= 2 && @$opts <= 4;
    my $rec = 0;
    for my $o (@$opts) {
        return 'option' unless ref $o eq 'HASH' && _str($o->{label}) && _str($o->{description});
        return 'option-size' if _bytes($o->{label}) > $MAX{label} || _bytes($o->{description}) > $MAX{description};
        return 'option-flags' unless _bool($o->{recommended}) && _bool($o->{long_term});
        $rec++ if $o->{recommended};
    }
    return 'recommended' if $rec > 1;
    if (!$rec) {
        return 'recommendation_none_reason' unless _str($d->{recommendation_none_reason})
            && _bytes($d->{recommendation_none_reason}) <= $MAX{recommendation_none_reason};
    }
    return undef;
}

# The model's fields only, in the queue-add/v1 order; WARN secrets redacted in place.
sub model_fields {
    my ($d) = @_;
    my @o;
    for my $o (@{ ref $d->{options} eq 'ARRAY' ? $d->{options} : [] }) {
        push @o, jsonc::obj(label => $o->{label}, description => $o->{description},
                            recommended => jsonc::bool($o->{recommended}), long_term => jsonc::bool($o->{long_term}));
    }
    return (question => $d->{question}, kind => $d->{kind}, ($d->{kind} eq 'open' ? () : (options => \@o)),
            (defined $d->{recommendation_none_reason} ? (recommendation_none_reason => $d->{recommendation_none_reason}) : ()),
            blocks => $d->{blocks}, (defined $d->{context} ? (context => $d->{context}) : ()));
}

# Every text the draft carries, for the secret scan (paths into the structure).
sub texts {
    my ($d) = @_;
    my @t = map { \$d->{$_} } grep { defined $d->{$_} } qw(question blocks context recommendation_none_reason);
    for my $o (@{ ref $d->{options} eq 'ARRAY' ? $d->{options} : [] }) { push @t, map { \$o->{$_} } grep { defined $o->{$_} } qw(label description) }
    return @t;
}

# client_id: "ck-" + 12 hex of sha256(sid \0 normalized question \0 option labels joined by \0)
sub client_id {
    my ($sid, $d) = @_;
    my $q = lc($d->{question});
    $q =~ s/\s+/ /g;
    $q =~ s/^ | $//g;
    my @labels = map { $_->{label} } @{ ref $d->{options} eq 'ARRAY' ? $d->{options} : [] };
    return 'ck-' . substr(sha::hex256(join("\0", $sid, $q, @labels)), 0, 12);
}

sub ledger_path { my $d = rc::sid_dir(); return defined $d ? "$d/queue-adds.jsonl" : undef }

# ledger_hit(client_id) -> the id of a queued/exists row for it, or undef
sub ledger_hit {
    my ($cid) = @_;
    my $f = ledger_path() // return undef;
    my $raw = util::read_file($f) // return undef;
    my $hit;
    for my $l (split /\n/, $raw) {
        my $j = eval { jsonc::decode($l) } or next;
        next unless ref $j eq 'HASH' && ($j->{client_id} // '') eq $cid && ($j->{result} // '') =~ /^(queued|exists)$/;
        $hit = $j->{id};
    }
    return $hit;
}

# lane_name() -> the kebab slug of this session's pinned bucket topic, or undef
sub lane_name {
    my $root = rc::root();
    return undef unless defined $root && rc::root_ok('handoff_root');
    my $b = bucket::_pin_of(rc::sid()) // return undef;
    my $s = bucket::slug(util::basename($b));
    return $s ne '' ? $s : undef;
}

sub _say {
    my ($result, $what, $t0, $exit) = @_;
    rc::emit('queue_add', [result => $result, exit => $exit, ms => util::clock_ms() - $t0]);
    if ($result eq 'queued') { args::out("QUEUED $what") }
    elsif ($result eq 'exists') { args::out("EXISTS $what") }
    else { args::out("NOT QUEUED ($result): " . (defined $what ? "$what; " : '') . 'keep it in Questions') }
    return 0;
}

sub run {
    my $t0 = util::clock_ms();
    my ($opt) = eval { args::parse(\@_, known => [qw(sid nonce file root log-dir)]) };
    if (!$opt || !args::valid_sid($opt->{sid}) || !nonce::valid($opt->{nonce} // '')) {
        args::out('NOT QUEUED (invalid): usage queue-add --sid S --nonce N [--file F]; keep it in Questions');
        return 0;
    }
    my $sid = args::init_sid($opt);
    my $cmd = rc::val('queue_cmd');
    return _say('off', undef, $t0, undef) unless defined $cmd && $cmd ne '' && -f $cmd && -x _;
    my $raw;
    if (defined $opt->{file}) { $raw = util::read_file($opt->{file}, $queue::ADD_MAX + 1) }
    else { binmode(STDIN, ':raw'); my $n = read(STDIN, $raw, $queue::ADD_MAX + 1); $raw = '' unless $n }
    return _say('invalid', 'draft-size', $t0, undef) if !defined $raw || length($raw) > $queue::ADD_MAX;
    my $d = eval { jsonc::decode($raw) };
    my $bad = check($d);
    return _say('invalid', $bad, $t0, undef) if defined $bad;
    # HARD: nothing is sent; WARN: redacted in place, then sent
    my @refs = texts($d);
    my @hard = map { $_->{rule} } grep { $_->{class} eq 'HARD' } map { @{ secrets::scan($$_) } } @refs;
    return _say('secret', $hard[0], $t0, undef) if @hard;
    for my $r (@refs) { ($$r) = secrets::redact($$r, ['WARN']) if @{ secrets::scan($$r) } }
    my $cid = client_id($sid, $d);
    if (defined(my $id = ledger_hit($cid))) { return _say('exists', $id, $t0, undef) }
    return _say('unsupported', undef, $t0, undef) unless queue::add_supported($cmd);
    my $draft = jsonc::obj(schema => $queue::ADD_SCHEMA, client_id => $cid, session => $sid, asked_at => util::iso(util::now()),
                           source => jsonc::obj(plugin => ctx::brand(), kind => 'checkpoint', nonce => $opt->{nonce}),
                           model_fields($d));
    my $json = jsonc::encode_bytes($draft);
    return _say('invalid', 'draft-size', $t0, undef) if length($json) > $queue::ADD_MAX;
    my $r = queue::add($cmd, $sid, $cid, lane_name(), $json, $BUDGET_MS);
    eval { queue::caps_put($cmd, add => 'unsupported') } if $r->{result} eq 'unsupported';
    eval {
        log::append(ledger_path(), jsonc::obj(client_id => $cid, result => $r->{result}, id => $r->{id}, ts => util::iso(util::now())))
            if defined ledger_path();
    };
    return _say($r->{result}, $r->{id}, $t0, $r->{exit});
}

# An internal error is a `NOT QUEUED (error)` line and exit 0 too.
sub main {
    my $code = eval { run(@_) };
    return $code if defined $code;
    args::out('NOT QUEUED (error): keep it in Questions');
    return 0;
}

exit(args::main(\&main, @ARGV));
