package resumeblock;
# lib/resumeblock.pm: the post-compaction resume block (MOD-SPEC §3.4):
# resume-context.txt with [midturn]/[nonok] and exactly one of [prod-forbid]/[prod-allow],
# @session_id@, @saved_copy@, @measured_at@, @remeasure@ (<= 3,000 B), @store@ (C-5). Total soft
# 6,500 chars (compaction-rem-6; soft since the owner overturned ratify xxxxxxxx#R3 on 2026-10-23,
# SPEC-DELTAS RP-2): a block over it logs resume_block_over_soft {nonce, chars}. Hard runtime cap
# 9,500 chars, under the 10,000-char SessionStart cutoff: over it the measured block is cut first,
# at a line boundary. No transcript path.
# Owner: WP-core.
use strict;
use warnings;
use utf8;

our $MAX_CHARS = 9500;
our $SOFT_CHARS = 6500;

sub build {
    my (%a) = @_;
    my @tags;
    push @tags, 'midturn' if $a{midturn};
    push @tags, 'nonok' if $a{nonok};
    # step 4 is two tagged lines (S-SETTINGS B, XR-19): exactly one prod tag, prod-allow only when
    # this helper's own unattended_prod_reads (settings file only) is allow. The classic path has
    # no idle signal at SessionStart, so it never pushes idle (never with midturn).
    my $prod = eval { settings::prod(rc::settings()) };
    push @tags, (($prod && ($prod->{reads} // '') eq 'allow') ? 'prod-allow' : 'prod-forbid');
    # @store@ (TXT-06 line 1 defines <store>; PKG-RUNTIME A.2): the launcher word that
    # handoff_turn::finish_command stands for, as the mod's storeRuntime fills it. A root no
    # quoting can carry (store_path_unquotable) has no word: drop the lines that hold the token.
    my $store = ctx::store_cmd();
    my $re = $a{remeasure} // '';
    my $max = 3000;
    my $text;
    for (1 .. 12) {
        $text = assemble::asset('res', \@tags, { session_id => $a{sid}, saved_copy => $a{saved_copy},
                                                  measured_at => $a{measured_at} // util::iso(util::now()),
                                                  remeasure => $re, (defined $store ? (store => $store) : ()) },
                                defined $store ? [] : ['store']);
        last if length($text) <= $MAX_CHARS;
        $max -= 400;
        last if $max < 200;
        $re = measure::cap([split /\n/, $re], $max);
    }
    rc::emit('resume_block_over_soft', [nonce => $a{nonce}, chars => length($text)]) if length($text) > $SOFT_CHARS;
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
    # The winner creates the file, then writes its channel: a loser that reads in
    # between sees it empty, so wait briefly for the content (up to ~0.5 s).
    my $who;
    for my $try (1 .. 50) {
        my $raw = util::read_file($f) // '';
        ($who) = $raw =~ /^(\S+)/;
        last if defined $who;
        util::sleep_ms(10);
    }
    return ('TAKEN', $who // 'unknown');
}

1;
