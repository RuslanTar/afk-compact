# AT-M3-14b-bundled-types setup: write a type-declaration file where Claude Code puts it when its built-in
# plugin-authoring skill loads, as `perl bundled-types.pl TMPROOT VER NONCE HEADER_VER SRC EPOCH [LINK_TARGET]`:
# TMPROOT/claude-<uid>/bundled-skills/VER/NONCE/plugin-authoring/types/claude-code.d.ts,
# line 1 `// Written by Claude Code HEADER_VER.`, then SRC without its own line 1; mtime EPOCH.
# With LINK_TARGET the declarations are written there and the bundled path is a symlink to it.
use strict;
use warnings;

my ($tmproot, $ver, $nonce, $hv, $src, $epoch, $link) = @ARGV;
die "usage: TMPROOT VER NONCE HEADER_VER SRC EPOCH [LINK_TARGET]\n" unless defined $epoch;
my $dir = "$tmproot/claude-$</bundled-skills/$ver/$nonce/plugin-authoring/types";
system('/bin/mkdir', '-p', $dir) == 0 or die "mkdir $dir failed\n";
open(my $in, '<:raw', $src) or die "read $src: $!\n";
my $first = <$in>;
my $body = do { local $/; <$in> } // '';
close $in;
my $f = "$dir/claude-code.d.ts";
my $w = $f;
if (defined $link) {
    (my $ld = $link) =~ s{/[^/]+\z}{};
    system('/bin/mkdir', '-p', $ld) == 0 or die "mkdir $ld failed\n";
    $w = $link;
}
open(my $out, '>:raw', $w) or die "write $w: $!\n";
print $out "// Written by Claude Code $hv.\n", $body;
close($out) or die "close $w: $!\n";
utime($epoch, $epoch, $w) or die "utime $w: $!\n";
if (defined $link) { symlink($link, $f) or die "symlink $f: $!\n" }
