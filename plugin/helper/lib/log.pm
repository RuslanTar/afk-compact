package log;
# lib/log.pm: content-free rows in the WATCHER-SPEC §6.2 envelope (BUILD-PLAN §3.2).
# Owner: WP-core. Every row is one O_APPEND write of <= 4 KB under flock.
#   log::row(ev, fields, ctx) -> ordered row object
#   log::append(stream_path, row) -> 1, or dies "row-too-large"
# fields: an array ref of key/value pairs (kept in order) or a hash ref (sorted).
use strict;
use warnings;

our $MAX = 4096;

sub row {
    my ($ev, $fields, $c) = @_;
    $c ||= {};
    my @f;
    if (ref $fields eq 'ARRAY') { @f = @$fields }
    elsif (ref $fields eq 'HASH') { @f = map { ($_ => $fields->{$_}) } sort keys %$fields }
    return jsonc::obj(
        v              => 1,
        ts             => $c->{ts} // util::iso_ms(util::now()),
        ev             => $ev,
        sid            => $c->{sid},
        actor          => $c->{actor} // 'unknown',
        writer         => $c->{writer} // 'helper',
        pid            => $c->{pid},
        plugin_version => ctx::version(),
        cc_version     => $c->{cc_version},
        turn_seq       => $c->{turn_seq},
        @f,
    );
}

# Encode a row (object or already-encoded line) and append it.
sub append {
    my ($path, $row) = @_;
    my $line = ref $row ? jsonc::encode($row) : $row;
    $line =~ s/\n+\z//;
    utf8::encode($line) if utf8::is_utf8($line);
    die "row-too-large\n" if length($line) + 1 > $MAX;
    die "row-not-one-line\n" if index($line, "\n") >= 0;
    util::append($path, $line . "\n");
    return 1;
}

1;
