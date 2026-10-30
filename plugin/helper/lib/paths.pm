package paths;
# lib/paths.pm: where things live (MOD-SPEC conventions). Owner: WP-core.
# paths::for(settings, sid) -> {root, watch, disposable, watch_default, from_default, legacy,
#   disposable_from_default, disposable_legacy}
# STATE-ROOT (0.1.2): the default handoff root is ~/.local/state/<plugin>/handoffs and the default
# disposable root ~/.local/state/<plugin>/disposable. Claude Code asks before every write under
# ~/.claude in the default permission mode (its protected-path, "sensitive file" prompt, which no
# allow rule lifts), so the old defaults ~/.claude/handoffs and ~/.claude/trash-staging asked on each
# handoff and evidence copy; under ~/.local/state an Edit(~/.local/state/<plugin>/**) allow rule lifts
# it. The move is for that prompt only: in auto mode a write to the new roots still goes to the
# safety checker. The old folders stay where they are and are read, never written (legacy below);
# `migrate` copies them on request and deletes nothing.
use strict;
use warnings;
use utf8;

# The shipped defaults (the config-defaults gate holds them equal to the manifest's once <plugin> is the
# plugin's name: no source but the manifest names the plugin, so a rename needs no edit here) and
# the legacy roots.
our $NAME_TOKEN = '<plugin>';
our $DEFAULT_ROOT = '~/.local/state/<plugin>/handoffs';
our $LEGACY_ROOT = '~/.claude/handoffs';
our $DEFAULT_DISPOSABLE = '~/.local/state/<plugin>/disposable';
our $LEGACY_DISPOSABLE = '~/.claude/trash-staging';
# key -> [fallback default, legacy default]: the two settings whose default moved out of ~/.claude
our %MOVED = (handoff_root => [$DEFAULT_ROOT, $LEGACY_ROOT], disposable_root => [$DEFAULT_DISPOSABLE, $LEGACY_DISPOSABLE]);

sub for {
    my ($settings, $sid) = @_;
    my $v = ref $settings eq 'HASH' && $settings->{values} ? $settings->{values} : $settings;
    my $given = util::clean_path($v->{handoff_root});
    my $is_def = from_default($settings, $given);
    my $root = $is_def ? state_default() : $given;
    my $watch = (defined $v->{log_dir} && $v->{log_dir} ne '') ? util::clean_path($v->{log_dir}) : "$root/.watch";
    my $dgiven = util::clean_path($v->{disposable_root});
    my $d_def = from_default($settings, $dgiven, 'disposable_root');
    my $disp = $d_def ? state_default('disposable_root') : $dgiven;
    my $wdef = state_default() . '/.watch';
    return { root => $root, watch => $watch, disposable => $disp, watch_default => $wdef,
             from_default => $is_def, legacy => $is_def ? legacy($settings, $root) : undef,
             disposable_from_default => $d_def,
             disposable_legacy => $d_def ? legacy($settings, $disp, 'disposable_root') : undef };
}

# default_root([key]) -> the manifest's default for key (handoff_root unless given), else its
# fallback in %MOVED (unexpanded).
sub default_root {
    my ($key) = @_;
    $key //= 'handoff_root';
    my $udef = ctx::user_config();
    my $d = ref $udef eq 'HASH' && ref $udef->{$key} eq 'HASH' ? $udef->{$key}{default} : undef;
    return defined $d && !ref $d && $d ne '' ? $d : named($MOVED{$key}[0]);
}

# state_default([key]) -> the default root of key (handoff_root unless given), expanded and clean.
# STATE-ROOT: under $XDG_STATE_HOME when that is an absolute path and the default lies under
# ~/.local/state (the XDG Base Directory rule: a relative value is ignored, so it reads as unset);
# the manifest's default stays the literal path.
sub state_default {
    my ($key) = @_;
    my $d = default_root($key);
    my $x = $ENV{XDG_STATE_HOME};
    return util::clean_path($x . $1) if defined $x && $x =~ m{\A/} && defined $d && $d =~ m{\A~/\.local/state(/.+)\z}s;
    return util::clean_path($d);
}

# from_default(resolved settings, clean value[, key]) -> 1 when key (handoff_root unless given) comes
# from the default: unset in every source (resolve's source `default`), or a value equal to the default
# (as written, or as state_default reads it). A plugin load fills unset options with the manifest's
# defaults (the testing kit's TestOptions.options doc), so the mod's options, and the
# CLAUDE_PLUGIN_OPTION_* environment it passes the helper (config.ts optionEnv), carry the default as
# a value; whether `${user_config.<key>}` in skill text does too is not probed. Any other value, the
# old default (~/.claude/handoffs, ~/.claude/trash-staging) included, is the only root.
sub from_default {
    my ($settings, $given, $key) = @_;
    $key //= 'handoff_root';
    my $src = ref $settings eq 'HASH' && ref $settings->{source} eq 'HASH' ? $settings->{source}{$key} // '' : '';
    return 1 if $src eq 'default';
    return 0 unless defined $given;
    for my $d (util::clean_path(default_root($key)), state_default($key)) { return 1 if defined $d && $d eq $given }
    return 0;
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

# legacy(resolved settings, root[, key]) -> the legacy root of key (handoff_root unless given; expanded
# and clean) or undef (STATE-ROOT). `for` asks only while key comes from the default (from_default).
# Undef when the folder is missing or is the root itself. Settings without a source (a plain values
# hash) give undef.
sub legacy {
    my ($settings, $root, $key) = @_;
    $key //= 'handoff_root';
    return undef unless ref $settings eq 'HASH' && ref $settings->{source} eq 'HASH' && defined $root && $MOVED{$key};
    my $l = util::clean_path($MOVED{$key}[1]);
    return undef if !defined $l || $l eq $root || !-d $l;
    my ($rl, $rr) = (util::real_path($l), util::real_path($root));
    return undef if defined $rl && defined $rr && $rl eq $rr;
    return $l;
}

sub sid_dir { my ($p, $sid) = @_; return "$p->{watch}/$sid" }

1;
