package handoff_turn;
# lib/handoff_turn.pm: the handoff-turn store (D-18 §9.1, B8; DP-6 / REVIEW B-18: one core
# lib, called by `handoff-turn`, `handoff-state` and the skills' `begin` and `publish`).
# Owner: WP-core. Files under <watch>/<sid>/handoff-turn/, each by exclusive create, never
# rewritten or removed:
#   <ht>.json        {v, ht, session_id, reason, max_calls, max_tokens, opened_at}
#                    (`handoff-turn open`, run by the mod before it submits the turn)
#   <ht>.stage       the stage path `begin` bound to this ht (bind_stage)
#   <ht>.published   the handoff path, written by `publish` before its rename (mark_published)
#   <ht>.superseded  the nonce of a native compaction that ran during the turn (the race);
#                    `<ht>.json` stays write-once, so superseded_by lives in this twin file
#   <ht>.closed      why the mod closed the ht (cancelled | ended; `handoff-turn close`,
#                    CR-F17/F25): begin no longer binds it (open_for_begin)
# A second handoff for one ht cannot happen: bind_stage returns the existing stage
# (`resumed`), mark_published refuses with the existing path.
use strict;
use warnings;
use utf8;

# precompact: the OD-4 pre-compaction turn (MOD-SPEC §9.3, S-SETTINGS D); idle: the pre-idle
# handoff turn (§9.4, IC-1 D5)
our %REASONS = map { $_ => 1 } qw(2-nonok thrash cap continue-off precompact idle);
our $OPEN_MAX_AGE_S = 3600;
our %CLOSE_WHY = map { $_ => 1 } qw(cancelled ended);

sub valid_ht { return defined $_[0] && $_[0] =~ /\A[0-9a-f]{8}\z/ ? 1 : 0 }
sub dir { my ($sid_dir) = @_; return "$sid_dir/handoff-turn" }
sub _f { my ($sid_dir, $ht, $ext) = @_; return dir($sid_dir) . "/$ht.$ext" }

sub _read_line {
    my ($f) = @_;
    my $raw = util::read_file($f, 8192) // return undef;
    $raw =~ s/\s+\z//;
    return $raw eq '' ? undef : $raw;
}

# open(sid_dir, sid, ht, reason, max_calls, max_tokens) -> 1 created | 0 exists
sub open_ht {
    my ($sid_dir, $sid, $ht, $reason, $calls, $tokens) = @_;
    my $rec = jsonc::obj(v => 1, ht => $ht, session_id => $sid, reason => $reason, max_calls => 0 + $calls,
                         max_tokens => 0 + $tokens, opened_at => util::iso(util::now()));
    util::mkdir_p(dir($sid_dir));
    chmod 0700, dir($sid_dir);
    return util::write_excl(_f($sid_dir, $ht, 'json'), jsonc::encode_bytes($rec) . "\n", 0600);
}

sub record {
    my ($sid_dir, $ht) = @_;
    return undef unless valid_ht($ht);
    my $raw = util::read_file(_f($sid_dir, $ht, 'json')) // return undef;
    my $j = eval { jsonc::decode($raw) };
    return undef unless ref $j eq 'HASH';
    $j->{superseded_by} = _read_line(_f($sid_dir, $ht, 'superseded'));
    return $j;
}

# open_for_begin(sid_dir) -> the newest ht with a record, no .published, no .closed and
# opened at most 60 minutes ago, or undef (begin binds it; the model never types an ht, HK-06)
sub open_for_begin {
    my ($sid_dir) = @_;
    my $now = util::now();
    my ($best, $best_t);
    for my $f (util::list_dir(dir($sid_dir))) {
        next unless $f =~ /\A([0-9a-f]{8})\.json\z/;
        my $ht = $1;
        next if -e _f($sid_dir, $ht, 'published') || -e _f($sid_dir, $ht, 'closed');
        my $r = record($sid_dir, $ht) or next;
        my $t = util::parse_iso($r->{opened_at} // '') // next;
        next if $now - $t > $OPEN_MAX_AGE_S || $t > $now + 60;
        ($best, $best_t) = ($r, $t) if !defined $best_t || $t > $best_t;
    }
    return $best;
}

# bind_stage(sid_dir, ht, stage) -> (stage, resumed 0|1); resumed: the ht already had a
# stage, which is returned instead (one handoff per ht)
sub bind_stage {
    my ($sid_dir, $ht, $stage) = @_;
    die "handoff_turn: bad ht\n" unless valid_ht($ht);
    my $f = _f($sid_dir, $ht, 'stage');
    return ($stage, 0) if util::write_excl($f, "$stage\n", 0600);
    return (_read_line($f) // $stage, 1);
}

sub stage_of { my ($sid_dir, $ht) = @_; return valid_ht($ht) ? _read_line(_f($sid_dir, $ht, 'stage')) : undef }
sub published_of { my ($sid_dir, $ht) = @_; return valid_ht($ht) ? _read_line(_f($sid_dir, $ht, 'published')) : undef }

# mark_published(sid_dir, ht, path) -> (1, path) created | (0, existing path): publish
# refuses with `REFUSED: handoff-exists <existing path>`
sub mark_published {
    my ($sid_dir, $ht, $path) = @_;
    die "handoff_turn: bad ht\n" unless valid_ht($ht);
    my $f = _f($sid_dir, $ht, 'published');
    return (1, $path) if util::write_excl($f, "$path\n", 0600);
    return (0, _read_line($f) // $path);
}

# close_ht(sid_dir, ht, why) -> 1 created | 0 exists (CR-F17/F25: the mod closes an ht
# whose turn it cancelled after the open, or that ended, so a later manual handoff in the
# hour does not bind it)
sub close_ht {
    my ($sid_dir, $ht, $why) = @_;
    die "handoff_turn: bad ht\n" unless valid_ht($ht);
    die "handoff_turn: bad close reason\n" unless defined $why && $CLOSE_WHY{$why};
    return util::write_excl(_f($sid_dir, $ht, 'closed'), "$why\n", 0600);
}

sub closed_of { my ($sid_dir, $ht) = @_; return valid_ht($ht) ? _read_line(_f($sid_dir, $ht, 'closed')) : undef }

# supersede(sid_dir, ht, nonce) -> 1 created | 0 exists
sub supersede {
    my ($sid_dir, $ht, $nonce) = @_;
    die "handoff_turn: bad ht\n" unless valid_ht($ht);
    return util::write_excl(_f($sid_dir, $ht, 'superseded'), "$nonce\n", 0600);
}

# finish_command(stage, meta) -> the literal publish command for a staged draft: the stage
# path single-quoted (undef when it holds a quote, or when the launcher path cannot be
# quoted), the slug and status from the stage meta
# when the skill recorded them, else the kebab name of the bucket's topic and in-progress
# (an interrupted turn leaves the work in progress). No session id: publish reads it from
# the stage.
sub finish_command {
    my ($stage, $meta) = @_;
    return undef if !defined $stage || index($stage, "'") >= 0 || $stage =~ /[\n\r]/;
    $meta ||= {};
    my $slug = (defined $meta->{slug} && !ref $meta->{slug} && $meta->{slug} =~ /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) ? $meta->{slug} : undef;
    if (!defined $slug) {
        my $b = (defined $meta->{bucket} && !ref $meta->{bucket}) ? util::basename($meta->{bucket}) : util::basename(util::dirname(util::dirname($stage)));
        $slug = bucket::slug($b);
        $slug = 'handoff' if $slug eq '';
    }
    my $status = (defined $meta->{status} && !ref $meta->{status} && $meta->{status} =~ /\A(in-progress|blocked|completed)\z/) ? $meta->{status} : 'in-progress';
    # The quoted absolute launcher path (PKG-RUNTIME A.1); none when no quoting holds it.
    my $store = ctx::store_cmd();
    return undef unless defined $store;
    return $store . " publish --stage '$stage' --slug $slug --status $status";
}

# published_ok(sid_dir, ht, path) -> 1 when the claimed handoff is in place: a regular file
# (not a link) whose last non-empty line is a sentinel of the spec grammar, with the nonce
# of the stage bound to this ht when that stage records one (CR-F9: publish claims before
# it links the file into place, and a failed link leaves the claim naming a missing or
# foreign file). Without a readable spec the regular file alone counts.
sub published_ok {
    my ($sid_dir, $ht, $path) = @_;
    $path //= published_of($sid_dir, $ht);
    return 0 unless defined $path && !-l $path && -f _;
    my $size = -s _;
    open(my $fh, '<:raw', $path) or return 0;
    my $from = $size > 4096 ? $size - 4096 : 0;
    seek($fh, $from, 0) or return 0;
    my $tail = '';
    defined read($fh, $tail, 4096) or return 0;
    close $fh;
    my ($last) = grep { /\S/ } reverse split /\n/, $tail;
    return 0 unless defined $last;
    $last =~ s/\r\z//;
    utf8::decode($last);
    my $sre = eval { spec::re('sentinel_re') } or return 1;
    return 0 unless $last =~ $sre;
    my $got = $1;
    my $st = stage_of($sid_dir, $ht);
    my $meta = defined $st ? eval { jsonc::decode(util::read_file("$st/settings.json", 262144) // '') } : undef;
    my $want = ref $meta eq 'HASH' && defined $meta->{nonce} && !ref $meta->{nonce} ? $meta->{nonce} : undef;
    return 0 if defined $want && (!defined $got || $got ne $want);
    return 1;
}

# state(sid_dir, ht) -> {state => none|staged|published|publish-failed|superseded, path,
# stage, draft, finish, nonce}. Precedence: published, staged, superseded, none: after a
# race the next window still needs the finish command of a staged draft ([handoff-partial]);
# the mod knows of the race it recorded, and `superseded` is what is left when nothing was
# staged. A claim whose file is not in place (published_ok) is `publish-failed <path>`: no
# second handoff can be published for that ht, so the mod falls back to the full summary.
sub state {
    my ($sid_dir, $ht) = @_;
    my $p = published_of($sid_dir, $ht);
    if (defined $p) {
        return { state => 'published', path => $p } if published_ok($sid_dir, $ht, $p);
        return { state => 'publish-failed', path => $p };
    }
    my $r = record($sid_dir, $ht);
    my $st = stage_of($sid_dir, $ht);
    if ($r && defined $st && -d $st) {
        my $body = util::read_file("$st/body.md", 1 << 20);
        my $meta = eval { jsonc::decode(util::read_file("$st/settings.json", 262144) // '') };
        return { state => 'staged', stage => $st, draft => (defined $body && $body =~ /\S/ ? 1 : 0),
                 finish => finish_command($st, ref $meta eq 'HASH' ? $meta : {}) };
    }
    return { state => 'superseded', nonce => $r->{superseded_by} } if $r && defined $r->{superseded_by};
    return { state => 'none' };
}

1;
