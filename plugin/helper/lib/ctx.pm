package ctx;
# lib/ctx.pm: plugin facts for this process (root, brand, version). Owner: WP-core.
# The brand comes from <plugin root>/.claude-plugin/plugin.json `name`; fallback:
# the launcher's basename minus `-store` (STORE_LAUNCHER, set by the launcher).
# Code holds no literal plugin name.
use strict;
use warnings;
use utf8;

our ($ROOT, $HELPER, $BRAND, $VERSION, $MANIFEST);

sub init {
    my ($helper_dir) = @_;
    $HELPER = $helper_dir;
    $ROOT = util::dirname($helper_dir);
    my $raw = util::read_file("$ROOT/.claude-plugin/plugin.json");
    my $m = eval { jsonc::decode($raw) } if defined $raw;
    $MANIFEST = ref $m eq 'HASH' ? $m : {};
    $BRAND = $MANIFEST->{name};
    if (!defined $BRAND || $BRAND eq '') {
        my $l = util::basename($ENV{STORE_LAUNCHER} // '');
        $l =~ s/-store$//;
        $BRAND = $l ne '' ? $l : 'plugin';
    }
    $VERSION = $MANIFEST->{version} // '0.0.0';
}

sub root    { $ROOT }
sub brand   { $BRAND }
sub version { $VERSION }

# The launcher folder: one constant here, in tools/build and in the mod's deps.ts (PKG-RUNTIME
# A.1; the AT-PK-01 gate finds any other spelling).
our $LAUNCHER_DIR = 'scripts';
sub launcher { return "$ROOT/$LAUNCHER_DIR/" . $BRAND . '-store' }

# store_word(path) -> the launcher path as one shell word, the same word the mod's storeWord()
# makes (parity test, AT-PK-03): double quotes; single quotes when the path holds `"`, `$`,
# a backquote or `\`; undef when it holds `'` as well (store_path_unquotable).
sub store_word {
    my ($p) = @_;
    return undef unless defined $p;
    return "\"$p\"" unless $p =~ /["\$`\\]/;
    return "'$p'" unless index($p, "'") >= 0;
    return undef;
}

# store_cmd() -> the word that starts every helper command the plugin writes for the model or
# the user: the absolute launcher path, quoted (PKG-RUNTIME A.1); undef when no quoting can
# hold it.
sub store_cmd { return store_word(launcher()) }
sub asset_path { return "$ROOT/assets/$_[0]" }

# userConfig defaults from the manifest (one source with the mod and the skills)
sub user_config { return ref $MANIFEST->{userConfig} eq 'HASH' ? $MANIFEST->{userConfig} : {} }

1;
