package resumeblock;
# lib/resumeblock.pm: the post-compaction resume block (MOD-SPEC §3.4):
# resume-context.txt with [midturn]/[nonok], @session_id@, @saved_copy@,
# @measured_at@, @remeasure@ (<= 3,000 B). Total <= 5,000 chars; no transcript path.
# Owner: WP-core.
use strict;
use warnings;

our $MAX_CHARS = 5000;

sub build {
    my (%a) = @_;
    my @tags;
    push @tags, 'midturn' if $a{midturn};
    push @tags, 'nonok' if $a{nonok};
    my $re = $a{remeasure} // '';
    my $max = 3000;
    my $text;
    for (1 .. 12) {
        $text = assemble::asset('res', \@tags, { session_id => $a{sid}, saved_copy => $a{saved_copy},
                                                  measured_at => $a{measured_at} // util::iso(util::now()),
                                                  remeasure => $re });
        last if length($text) <= $MAX_CHARS;
        $max -= 400;
        last if $max < 200;
        $re = measure::cap([split /\n/, $re], $max);
    }
    return $text;
}

sub pending_line {
    return 'pending (saved after this message; /' . ctx::brand() . ':status shows the path)';
}

# claim(sid, nonce, channel, bytes => n, nonok_note => bool) -> ('CLAIMED') | ('TAKEN', channel) | ('REFUSED', why)
# Exclusive create of <watch>/<sid>/resume-claimed/<nonce>, content = channel; row resume_inject.
our %CHANNELS = map { $_ => 1 } qw(sessionstart prompt.context prompt.submit);

sub claim {
    my ($sid, $nonce, $channel, %o) = @_;
    my $d = rc::sid_dir() // return ('REFUSED', 'no-watch');
    my $f = "$d/resume-claimed/$nonce";
    util::mkdir_p("$d/resume-claimed");
    if (util::write_excl($f, "$channel\n", 0600)) {
        rc::emit('resume_inject', [nonce => $nonce, channel => $channel, bytes => $o{bytes}, nonok_note => $o{nonok_note}]);
        return ('CLAIMED');
    }
    my $raw = util::read_file($f) // '';
    my ($who) = $raw =~ /^(\S+)/;
    return ('TAKEN', $who // 'unknown');
}

1;
