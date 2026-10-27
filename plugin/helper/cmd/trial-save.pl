# cmd/trial-save.pl: `trial-save --sid S` with one JSON object on stdin -> one JSON line
# naming what was written (TRIAL-DUAL-HANDOFF §4.3-§4.6). Owner: WP-core.
# stdin: {"kind": "moment"|"skip"|"late"|"failed", "moment_id": "<sid8>-<8 hex>", "repo", "ticket",
#         "moment": {content-free fields}, "old": {arm fields, "reply"?}, "native": {arm fields, "reply"?},
#         "arm": "old"|"native" (late only)}
# `failed` is the mod's second, minimal call after a `moment` save that failed (§4.7 "One row"):
# the moment's status `save-failed` and each arm's status and times, no reply, no shadow.
# Writes only under <home>/.cache/<brand>-trial/ (the trial folder), never under the handoff root:
#   old/<repo>/<ticket>/<YYYY-MM-DD_HH-MM-SS>_<sid8>_<slug>.old-handoff.txt          0600, exclusive
#   native/<repo>/<ticket>/<YYYY-MM-DD_HH-MM-SS>_<sid8>_<kind>.native-summary.txt   0600, exclusive
#   moments/<YYYY-MM>/<moment-id>.json (a late arm: <moment-id>.late-<arm>.json)    0600, exclusive
# A reply is saved only after the secret scan ran with rules loaded: each hit is replaced by
# [redacted:<rule>] and only rule ids reach the record (`no-scan`: nothing saved). The old slug
# is kebab `[a-z0-9-]{1,60}` with no secret-scan hit, else `handoff`; a repo or ticket that is not
# one safe path component is filed under its bucket name (trial::bucket). `REUSE <path>` is taken
# only for an existing old shadow of this bucket (else `bad-reuse`). The record holds ids, sums, sizes, statuses and usage only.
# A config that is not on (or not this owner's, for shadows) writes nothing: `{"written":false}`.
use strict;
use warnings;
use utf8;
require "trial.pm";

package cmd_trial_save;

sub _reply {
    my ($a) = @_;
    return undef unless ref $a eq 'HASH' && defined $a->{reply} && !ref $a->{reply};
    my $t = util::text($a->{reply});
    return $t eq '' ? undef : $t;
}

sub run {
    my ($opt) = args::parse(\@_, known => [qw(sid root log-dir)]);
    my $sid = args::init_sid($opt);
    binmode(STDIN, ':raw');
    my $raw = '';
    my $n = read(STDIN, $raw, 4 * $trial::REPLY_MAX + 1) // 0;
    die "usage: stdin is too large\n" if $n > 4 * $trial::REPLY_MAX;
    my $in = eval { jsonc::decode(util::text($raw)) };
    die "usage: stdin is not a JSON object\n" unless ref $in eq 'HASH';
    my $kind = $in->{kind} // '';
    die "usage: kind is moment, skip, late or failed\n" unless $kind =~ /^(moment|skip|late|failed)$/;
    my $id = $in->{moment_id};
    die "usage: bad moment_id\n" unless trial::valid_moment_id($id) && substr($id, 0, 8) eq substr($sid, 0, 8);
    my $none = sub { args::out(jsonc::encode({ written => jsonc::false(), why => $_[0] })); return 0 };
    my $l = trial::load();
    return $none->($l->{state} . (defined $l->{why} ? ":$l->{why}" : '')) unless $l->{state} eq 'on';
    my $cfg = $l->{cfg};
    my $m = trial::moment_meta($in->{moment});
    $m->{session_id} = $sid;
    my $now = util::iso(util::now());
    if ($kind eq 'skip' || $kind eq 'failed') {
        my $st = $m->{status} // '';
        return $none->('bad-' . $kind) unless $kind eq 'skip' ? $st =~ $trial::SKIP_RE : $st eq 'save-failed';
        my %arms;
        if ($kind eq 'failed') {
            for my $arm (qw(old native)) {
                my $meta = trial::arm_meta($in->{$arm}, $arm eq 'old' ? \%trial::OLD_FIELD : \%trial::NATIVE_FIELD);
                $arms{$arm} = $meta;
            }
        }
        my $rec = { v => 1, moment_id => $id, %$m, %arms, written_at => $now };
        my $p = trial::record_path($id);
        return $none->('exists') unless util::write_excl($p, jsonc::encode_pretty($rec) . "\n", 0600);
        args::out(jsonc::encode({ written => jsonc::true(), record => $p }));
        return 0;
    }
    # Shadows: only in the owner's own config, on a listed version, outside the skip-list.
    return $none->('not-owner-config') if defined trial::owner_skip($cfg);
    my ($name, $ticket) = ($in->{repo}, $in->{ticket});
    die "usage: bad repo or ticket\n" unless defined $name && !ref $name && $name ne '' && defined $ticket && !ref $ticket && $ticket ne '';
    my $repo = trial::bucket($name);
    $ticket = trial::bucket($ticket);
    return $none->('repo-skipped') if trial::skipped_repo($cfg, $repo, $name);
    my $rp = trial::record_path($id, $kind eq 'late' ? '.late-' . ($in->{arm} // '') : undef);
    return $none->('exists') if -e $rp;
    my $stamp = util::file_stamp(util::now());
    my $sid8 = substr($sid, 0, 8);
    my %arms;
    my @which = $kind eq 'late' ? (($in->{arm} // '') =~ /^(old|native)$/ ? ($1) : die "usage: arm is old or native\n") : qw(old native);
    for my $arm (@which) {
        my $a = $in->{$arm};
        my $meta = trial::arm_meta($a, $arm eq 'old' ? \%trial::OLD_FIELD : \%trial::NATIVE_FIELD);
        my $reply = _reply($a);
        if (defined $reply && ($meta->{status} eq 'ok') && length($reply) > $trial::REPLY_MAX) { $meta->{status} = 'rejected'; $reply = undef }
        if (defined $reply && $meta->{status} eq 'ok') {
            if ($arm eq 'old') {
                my $r = trial::old_reply($reply, $repo, $ticket);
                if ($r->{kind} eq 'bad-reuse') { $meta->{status} = 'bad-reuse' }
                elsif ($r->{kind} eq 'reuse') { $meta->{status} = 'reuse'; $meta->{reused_of} = util::basename($r->{path}) }
                else {
                    my ($red, $ids) = trial::scan_redact($r->{body});
                    if (!defined $red) { $meta->{status} = 'no-scan' }
                    else {
                        my $p = trial::write_shadow(trial::dir() . "/old/$repo/$ticket", "${stamp}_${sid8}_" . trial::clean_slug($r->{slug}), $trial::OLD_EXT, $red);
                        @$meta{qw(path sha256 bytes redacted framed)} = ($p, sha::hex256($red), length(util::to_bytes($red)), $ids,
                                                                          jsonc::bool($reply =~ $trial::OLD_START));
                    }
                }
            } else {
                my ($red, $ids) = trial::scan_redact($reply);
                if (!defined $red) { $meta->{status} = 'no-scan' }
                else {
                    my $k = ($m->{kind} // 'moment') =~ /^([a-z0-9-]{1,20})$/ ? $1 : 'moment';
                    my $p = trial::write_shadow(trial::dir() . "/native/$repo/$ticket", "${stamp}_${sid8}_$k", $trial::NATIVE_EXT, $red);
                    @$meta{qw(path sha256 body_sha256 bytes redacted)} = ($p, sha::hex256($red), sha::hex256(trial::native_body($red)),
                                                                        length(util::to_bytes($red)), $ids);
                }
            }
        }
        $arms{$arm} = $meta;
    }
    my $rec = { v => 1, moment_id => $id, repo => $repo, ticket => $ticket, %$m, %arms, written_at => $now };
    my $made = util::write_excl($rp, jsonc::encode_pretty($rec) . "\n", 0600);
    my %out = (written => jsonc::bool($made), record => ($made ? $rp : undef));
    $out{$_} = { status => $arms{$_}{status}, path => $arms{$_}{path} } for sort keys %arms;
    args::out(jsonc::encode(\%out));
    return 0;
}

exit(args::main(\&run, @ARGV));
