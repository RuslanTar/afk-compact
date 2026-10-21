package ctx;
# lib/ctx.pm: plugin facts for this process (root, brand, version). Owner: WP-core.
# The brand comes from <plugin root>/.claude-plugin/plugin.json `name`; fallback:
# the launcher's basename minus `-store` (STORE_LAUNCHER, set by the launcher).
# Code holds no literal plugin name.
use strict;
use warnings;

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
sub store_cmd { return $BRAND . '-store' }
sub asset_path { return "$ROOT/assets/$_[0]" }

# userConfig defaults from the manifest (one source with the mod and the skills)
sub user_config { return ref $MANIFEST->{userConfig} eq 'HASH' ? $MANIFEST->{userConfig} : {} }

1;
