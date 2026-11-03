package bucket;
# lib/bucket.pm: bucket choice (MOD-SPEC §7). Owner: WP-core.
#   session pin <root>/.sessions/<sid>.json -> predecessor's pin via
#   <root>/.sessions/<sid>.lineage.json (one hop) -> branch ticket
#   (ticket_pattern setting, default [A-Z][A-Z0-9]+-[0-9]+; SK-1) -> topic (skills' --topic; the handoff SKILL uses it only
#   "without a session pin or a ticket in the branch") -> general. Never asks; never
#   writes a pin.
# A pin's `bucket` is a path relative to <root> (`<repo>/<topic>`) or an absolute
# path under <root> (the pin format is WP-skills'; see the WP-core report).
# STATE-ROOT: a pin or lineage file is read from the effective root, else from the legacy root
# (rc::read_roots; a session that started before 0.1.2 keeps its bucket). A legacy pin's bucket
# is taken relative to the legacy root, and the bucket path is always under the effective root.
use strict;
use warnings;
use utf8;

sub _pin_bucket {
    my ($root, $sid) = @_;
    return undef unless defined $sid && $sid ne '';
    my $raw = util::read_file("$root/.sessions/$sid.json") // return undef;
    my $j = eval { jsonc::decode($raw) };
    return undef unless ref $j eq 'HASH';
    my $b = $j->{bucket};
    $b = $b->{path} if ref $b eq 'HASH';
    return undef unless defined $b && !ref $b && $b ne '';
    # bytes, as the root it is compared with and joined to: the pin is JSON read as characters,
    # so a non-ASCII bucket made the copy path a character string and its root folder encoded
    # twice (RF-4: every compaction copy after /handoff went to a second, double-encoded root)
    $b = util::expand_tilde(util::fsb($b));
    if ($b =~ m{^/}) {
        my $c = util::clean_path($b);
        return undef unless index("$c/", "$root/") == 0;
        $b = substr($c, length($root) + 1);
    }
    $b =~ s{^/+|/+$}{}g;
    return undef if $b eq '' || $b =~ m{(^|/)\.\.(/|$)};
    return $b;
}

# _pin_of(sid) -> the bucket of the first read root that holds sid's pin (undef: none, or that
# pin names no bucket: the effective root's pin wins even then).
sub _pin_of {
    my ($sid) = @_;
    return undef unless defined $sid && $sid ne '';
    for my $r (rc::read_roots()) {
        next unless -e "$r/.sessions/$sid.json";
        return _pin_bucket($r, $sid);
    }
    return undef;
}

sub slug {
    my ($s) = @_;
    $s = lc($s // '');
    $s =~ s/[^a-z0-9]+/-/g;
    $s =~ s/^-+|-+$//g;
    return substr($s, 0, 48);
}

# resolve(sid, cwd, topic [, where]) -> {path, rel, source, repo, where}
sub resolve {
    my ($sid, $cwd, $topic, $where) = @_;
    my $root = rc::root();
    $where ||= git::where($cwd);
    my $repo = $where->{repo} // (defined $cwd ? util::basename($cwd) : 'general');
    $repo = 'general' if !defined $repo || $repo eq '' || $repo eq '/';
    my ($rel, $source);
    if (defined(my $b = _pin_of($sid))) {
        ($rel, $source) = ($b, 'pin');
    } else {
        my ($lin) = grep { defined } map { util::read_file("$_/.sessions/$sid.lineage.json") } rc::read_roots();
        my $l = defined $lin ? eval { jsonc::decode($lin) } : undef;
        my $prev = ref $l eq 'HASH' ? $l->{previous_session_id} : undef;
        if (defined $prev && $prev ne 'unknown' && defined(my $pb = _pin_of($prev))) {
            ($rel, $source) = ($pb, 'pin-lineage');
        } elsif (defined $where->{branch} && defined(my $tk = settings::ticket($where->{branch}))) {
            # SK-1 (S-SETTINGS E1): the ticket_pattern setting; the id rule keeps `..` and `/` out
            ($rel, $source) = ("$repo/$tk", 'branch');
        } elsif (defined $topic && slug($topic) ne '') {
            ($rel, $source) = ("$repo/" . slug($topic), 'topic');
        } else {
            ($rel, $source) = ("$repo/general", 'general');
        }
    }
    return { path => "$root/$rel", rel => $rel, source => $source, repo => $repo, where => $where };
}

1;
