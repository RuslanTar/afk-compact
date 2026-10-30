package paths;
# lib/paths.pm: where things live (MOD-SPEC conventions). Owner: WP-core.
# paths::for(settings, sid) -> {root, watch, disposable, watch_default, legacy}
# STATE-ROOT (0.1.2): the default handoff root is ~/.local/state/<plugin>/handoffs. Claude Code asks
# before every write under ~/.claude (its protected-path, "sensitive file" prompt), so the old
# default ~/.claude/handoffs asked on each handoff. The move is for that prompt only: in auto mode
# a write to the new root still goes to the safety checker. The old folder stays where it is and
# is read, never written (legacy below).
use strict;
use warnings;
use utf8;

# The shipped default (the config-defaults gate holds it equal to the manifest's once <plugin> is the
# plugin's name: no source but the manifest names the plugin, so a rename needs no edit here) and
# the legacy root.
our $NAME_TOKEN = '<plugin>';
our $DEFAULT_ROOT = '~/.local/state/<plugin>/handoffs';
our $LEGACY_ROOT = '~/.claude/handoffs';

sub for {
    my ($settings, $sid) = @_;
    my $v = ref $settings eq 'HASH' && $settings->{values} ? $settings->{values} : $settings;
    my $root = util::clean_path($v->{handoff_root});
    my $watch = (defined $v->{log_dir} && $v->{log_dir} ne '') ? util::clean_path($v->{log_dir}) : "$root/.watch";
    my $disp = util::clean_path($v->{disposable_root});
    my $droot = default_root();
    my $wdef = util::clean_path($droot) . '/.watch';
    return { root => $root, watch => $watch, disposable => $disp, watch_default => $wdef, legacy => legacy($settings, $root) };
}

# default_root() -> the manifest's handoff_root default, else $DEFAULT_ROOT (unexpanded).
sub default_root {
    my $udef = ctx::user_config();
    my $d = ref $udef eq 'HASH' && ref $udef->{handoff_root} eq 'HASH' ? $udef->{handoff_root}{default} : undef;
    return defined $d && !ref $d && $d ne '' ? $d : named($DEFAULT_ROOT);
}

# named(value) -> value with <plugin> replaced by the plugin's name (ctx::brand: the manifest's, else the
# launcher's, else `plugin`), for a fallback default; any other value is returned as it is.
sub named {
    my ($v) = @_;
    return $v unless defined $v && !ref $v && index($v, $NAME_TOKEN) >= 0;
    my $n = eval { ctx::brand() };
    $n = 'plugin' unless defined $n && $n ne '';
    $v =~ s/\Q$NAME_TOKEN\E/$n/g;
    return $v;
}

# legacy(resolved settings, root) -> the legacy root (expanded and clean) or undef (STATE-ROOT). Only when
# handoff_root comes from the default: unset in every source (resolve's source `default`), or a
# value equal to the default. A plugin load fills unset options with the manifest's defaults (the
# testing kit's TestOptions.options doc), so the mod's options, and the CLAUDE_PLUGIN_OPTION_*
# environment it passes the helper (config.ts optionEnv), carry the default as a value; whether
# `${user_config.handoff_root}` in skill text does too is not probed. Any other value,
# ~/.claude/handoffs itself included, is the only root. Undef when the folder is missing or is the root itself. Settings
# without a source (a plain values hash) give undef.
sub legacy {
    my ($settings, $root) = @_;
    return undef unless ref $settings eq 'HASH' && ref $settings->{source} eq 'HASH' && defined $root;
    my $src = $settings->{source}{handoff_root} // '';
    if ($src ne 'default') {
        my $d = util::clean_path(default_root());
        return undef unless defined $d && $d eq $root;
    }
    my $l = util::clean_path($LEGACY_ROOT);
    return undef if !defined $l || $l eq $root || !-d $l;
    my ($rl, $rr) = (util::real_path($l), util::real_path($root));
    return undef if defined $rl && defined $rr && $rl eq $rr;
    return $l;
}

sub sid_dir { my ($p, $sid) = @_; return "$p->{watch}/$sid" }

1;
