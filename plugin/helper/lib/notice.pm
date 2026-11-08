package notice;
# lib/notice.pm: the first-run notice of the watcher (W-BETA A; WATCHER-SPEC §8 item 8).
# Owner: WP-core. The text is fixed in the spec asset (`notice` object: id, version, text) and
# carries no user content; the id names the version (watcher-1), so a version bump shows the
# notice again. The marker <watch>/notice/<id>.shown is made by exclusive create: one `show`
# per install (per config dir, since <watch> lives under it). `status` prints the notice line
# while the marker is missing (a session where the mod never ran).
use strict;
use warnings;
use utf8;

our $MAX_CHARS = 200;
# The spec text names the plugin through the build's placeholder (filled by tools/build; fill()
# below covers a text that still holds it); the fallback is built with the brand at run time.
our $PH = ('{' x 2) . 'plugin' . ('}' x 2);
our %FALLBACK = (id => 'watcher-1', version => 1);
sub _fallback_text {
    my $b = ctx::brand();
    return "$b: local compaction logs are on (content-free; nothing is sent). To share them: /$b:report. To turn them off: set watcher to false in /config.";
}

sub valid_id { return defined $_[0] && !ref $_[0] && $_[0] =~ /\A[a-z0-9][a-z0-9-]{0,40}\z/ ? 1 : 0 }

# spec() -> {id, version, text}: the spec's notice object with the plugin name filled, else the
# fallback. A text that is not a string, still holds a placeholder after the fill, or is over
# MAX_CHARS characters is not shown: the fallback is used.
sub spec {
    my $n = spec::has('notice') ? eval { spec::get('notice') } : undef;
    my %n = (ref $n eq 'HASH' && valid_id($n->{id}) && defined $n->{text} && !ref $n->{text}) ? %$n : (%FALLBACK, text => _fallback_text());
    my $t = fill($n{text});
    if (length($t) > $MAX_CHARS || $t =~ /\x7b\x7b|\x7d\x7d|\@[a-z_]+\@/) { %n = %FALLBACK; $t = _fallback_text() }
    return { id => $n{id}, version => $n{version}, text => $t };
}

sub fill { my ($t) = @_; $t =~ s/\Q$PH\E/ctx::brand()/ge; return $t }

sub marker { my ($watch, $id) = @_; return "$watch/notice/$id.shown" }

sub shown { my ($watch, $id) = @_; return defined $watch && -e marker($watch, $id) ? 1 : 0 }

# claim(watch, id) -> 'show' (this call made the marker) | 'seen' (it was there) | undef (no write)
sub claim {
    my ($watch, $id) = @_;
    return undef unless defined $watch && valid_id($id);
    util::mkdir_p("$watch/notice");
    chmod 0700, "$watch/notice";
    my $ok = eval { util::write_excl(marker($watch, $id), '', 0600) };
    return 'show' if $ok;
    return -e marker($watch, $id) ? 'seen' : undef;
}

1;
