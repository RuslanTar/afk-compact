package bucket;
# lib/bucket.pm: bucket choice (MOD-SPEC §7). Owner: WP-core.
#   session pin <root>/.sessions/<sid>.json -> predecessor's pin via
#   <root>/.sessions/<sid>.lineage.json (one hop) -> branch ticket
#   [A-Z][A-Z0-9]+-[0-9]+ -> topic (skills' --topic; the handoff SKILL uses it only
#   "without a session pin or a ticket in the branch") -> general. Never asks; never
#   writes a pin.
# A pin's `bucket` is a path relative to <root> (`<repo>/<topic>`) or an absolute
# path under <root> (the pin format is WP-skills'; see the WP-core report).
use strict;
use warnings;

sub _pin_bucket {
    my ($root, $sid) = @_;
    return undef unless defined $sid && $sid ne '';
    my $raw = util::read_file("$root/.sessions/$sid.json") // return undef;
    my $j = eval { jsonc::decode($raw) };
    return undef unless ref $j eq 'HASH';
    my $b = $j->{bucket};
    $b = $b->{path} if ref $b eq 'HASH';
    return undef unless defined $b && !ref $b && $b ne '';
    $b = util::expand_tilde($b);
    if ($b =~ m{^/}) {
        my $c = util::clean_path($b);
        return undef unless index("$c/", "$root/") == 0;
        $b = substr($c, length($root) + 1);
    }
    $b =~ s{^/+|/+$}{}g;
    return undef if $b eq '' || $b =~ m{(^|/)\.\.(/|$)};
    return $b;
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
    if (defined(my $b = _pin_bucket($root, $sid))) {
        ($rel, $source) = ($b, 'pin');
    } else {
        my $lin = util::read_file("$root/.sessions/$sid.lineage.json");
        my $l = defined $lin ? eval { jsonc::decode($lin) } : undef;
        my $prev = ref $l eq 'HASH' ? $l->{previous_session_id} : undef;
        if (defined $prev && $prev ne 'unknown' && defined(my $pb = _pin_bucket($root, $prev))) {
            ($rel, $source) = ($pb, 'pin-lineage');
        } elsif (defined $where->{branch} && $where->{branch} =~ /([A-Z][A-Z0-9]+-[0-9]+)/) {
            ($rel, $source) = ("$repo/$1", 'branch');
        } elsif (defined $topic && slug($topic) ne '') {
            ($rel, $source) = ("$repo/" . slug($topic), 'topic');
        } else {
            ($rel, $source) = ("$repo/general", 'general');
        }
    }
    return { path => "$root/$rel", rel => $rel, source => $source, repo => $repo, where => $where };
}

1;
