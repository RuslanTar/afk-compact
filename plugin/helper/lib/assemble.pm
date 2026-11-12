package assemble;
# lib/assemble.pm: the asset grammar,
# byte-identical with tools/assemble and hooks/lib/assemble.ts (BT-04).
#   Build time already stripped review comments and filled the plugin name (assets/*.txt).
#   Run time: a `[tag] ` line is kept (tag removed) when the tag applies, else
#   dropped; a line holding a token of a dropped block (`drop`) is dropped; lines
#   joined by \n, stripped, one trailing \n; then @name@ tokens filled from runtime
#   (unknown tokens are left as they are).
use strict;
use warnings;
use utf8;

# `turn` (handoff-turn.txt) is assembled by the mod; the helper knows it so the
# BT-04 goldens of every asset compare. Tags are kept only when a caller passes them: the
# classic paths never pass the mod-only ones (main [handoff], res [handoff] and
# [handoff-partial], nudge [halt-handoff], the turn's [submit] [near] [spent] [imminent]).
our %FILES = (main => 'handoff-instructions.txt', sub => 'subagent-instructions.txt',
              res => 'resume-context.txt', nudge => 'checkpoint-nudge.txt', turn => 'handoff-turn.txt');

my %TEXT;
sub text {
    my ($name) = @_;
    my $file = $FILES{$name} // "$name.txt";
    return $TEXT{$file} if defined $TEXT{$file};
    my $raw = util::read_file(ctx::asset_path($file));
    die "assemble: assets/$file missing\n" unless defined $raw;
    utf8::decode($raw);
    $TEXT{$file} = $raw;
    return $raw;
}

sub _strip {
    my ($s) = @_;
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

# grammar(text, \@tags, \@drop) -> text before token fill
sub grammar {
    my ($text, $tags, $drop) = @_;
    my %on = map { $_ => 1 } @{ $tags || [] };
    my @drop = @{ $drop || [] };
    my %dropped = map { $_ => 1 } @drop;
    my @out;
    for my $line (split /\r\n|\n|\r/, $text) {
        if ($line =~ /^\[([a-z-]+)\] /) {
            my $t = $1;
            next if !$on{$t} || $dropped{$t};
            $line = substr($line, length($t) + 3);
        }
        next if grep { index($line, "\@$_\@") >= 0 } @drop;
        push @out, $line;
    }
    return _strip(join("\n", @out)) . "\n";
}

# The asset is text (characters): a byte value (a path) is decoded where it joins it.
sub fill {
    my ($s, $runtime) = @_;
    $runtime ||= {};
    $s =~ s/\@([a-z_]+)\@/exists $runtime->{$1} && defined $runtime->{$1} ? util::text($runtime->{$1}) : "\@$1\@"/ge;
    return $s;
}

# asset(name, \@tags, \%runtime [, \@drop]) -> assembled text
sub asset {
    my ($name, $tags, $runtime, $drop) = @_;
    return fill(grammar(text($name), $tags, $drop), $runtime);
}

# Invariants checked by all three implementations.
sub leftovers {
    my ($s) = @_;
    my @bad;
    push @bad, 'tag' if $s =~ /^\[[a-z-]+\] /m;
    push @bad, 'token' if $s =~ /\@[a-z_]+\@/;
    push @bad, 'braces' if index($s, '{' x 2) >= 0;
    push @bad, 'comment' if index($s, '<' . '!--') >= 0;
    return @bad;
}

# Classic fallback: main (+[auto], +[chain], +[queue] when queue_cmd is set,
# never [measured]) followed directly by the subagent text with [fallback]. The queue
# lines ride on the setting, as on the mod path; no queue call here.
sub classic_fallback {
    my (%a) = @_;
    my @tags;
    push @tags, 'auto' if $a{auto};
    push @tags, 'chain' if defined $a{previous_copy};
    push @tags, 'queue' if $a{queue};
    my %rt = (nonce => $a{nonce});
    $rt{previous_copy} = $a{previous_copy} if defined $a{previous_copy};
    return asset('main', \@tags, \%rt, ['measured']) . asset('sub', ['fallback'], { nonce => $a{nonce} });
}

1;
