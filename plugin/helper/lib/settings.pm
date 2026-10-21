package settings;
# lib/settings.pm: settings order of BUILD-PLAN §3.1 / MOD-SPEC §2.6. Owner: WP-core.
#   explicit flag -> CLAUDE_PLUGIN_OPTION_<KEY> -> pluginConfigs[<key>].options in
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json -> userConfig default.
# Empty values and values starting `${user_config.` count as unset; a leading ~ is
# expanded. pluginConfigs key (E-14, provisional): `<name>@inline` when
# CLAUDE_PLUGIN_ROOT is set and not under the config dir's plugins/; otherwise the
# single key whose part before `@` is the brand; several -> defaults + ambiguous.
# Consent keys (DP-3, REVIEW A-3; %FILE_ONLY) are read from the settings file only: a
# model-run Bash call can pass flags and env, so those two sources are ignored with the
# note `<key>: settings file only`. That file is ~/.claude/settings.json: a
# CLAUDE_CONFIG_DIR naming another folder gives the consent keys their safe values
# (CR-F34, config_dir_foreign). Paths (dir and file keys) are UTF-8 bytes whatever
# their source, as env, flag and file-system values are (SR 1.1).
use strict;
use warnings;

# The 27 keys of MOD-SPEC §1.2 with their types; defaults (and min/max) come from
# plugin.json userConfig (one source), the third column only when the manifest lacks the key.
our @KEYS = (
    [handoff_root                => 'dir',  '~/.claude/handoffs'],
    [log_dir                     => 'dir',  ''],
    [disposable_root             => 'dir',  '~/.claude/trash-staging'],
    [disposable_keep_days        => 'num',  0],
    [evidence_quota_mb           => 'num',  500],
    [queue_cmd                   => 'file', ''],
    [triggers                    => 'bool', 1],
    [compact_target_tokens       => 'num',  400000],
    [compact_soft_max_tokens     => 'num',  600000],
    [native_window_tokens        => 'num',  0],
    [boundary_delay_ms           => 'num',  2000],
    [cooldown_ms                 => 'num',  30000],
    [max_auto_continues_per_hour => 'num',  3],
    [measured_block              => 'bool', 0],
    [auto_evidence               => 'bool', 1],
    [warn_ui                     => 'bool', 1],
    [watcher                     => 'str',  'shadow'],
    [stall_min                   => 'num',  60],
    [cache_ttl_s                 => 'num',  300],
    [otel_log_path               => 'file', ''],
    [deny_class_patterns         => 'str',  ''],
    # design pass of 2026-10-21: D-18 (mod keys), D-12 and Dev-1 (helper keys)
    [handoff_turn                => 'str',  'halt'],
    [handoff_turn_max_tokens     => 'num',  64000],
    [repo_roots                  => 'str',  ''],
    [relaunch_auto               => 'str',  'on'],
    [relaunch_allow              => 'str',  ''],
    [relaunch_quiet_s            => 'num',  120],
);
our %TYPE = map { $_->[0] => $_->[1] } @KEYS;

# DP-3: keys that let the plugin act without asking. Read from the settings file only.
our %FILE_ONLY = map { $_ => 1 } qw(repo_roots relaunch_auto relaunch_allow);

# Flag spellings: --<key with dashes>, plus the short forms the skills pass.
our %FLAG_ALIAS = (
    'root' => 'handoff_root', 'log-dir' => 'log_dir', 'disposable-root' => 'disposable_root',
    'keep-days' => 'disposable_keep_days', 'quota-mb' => 'evidence_quota_mb', 'queue-cmd' => 'queue_cmd',
    # consent keys: every subcommand takes the flag and ignores it with the note (DP-3)
    'repo-roots' => 'repo_roots', 'relaunch-auto' => 'relaunch_auto', 'relaunch-allow' => 'relaunch_allow',
);

sub _unset {
    my ($v) = @_;
    return 1 unless defined $v;
    return 1 if !ref $v && ($v eq '' || index($v, '${user_config.') == 0);
    return 0;
}

sub _coerce {
    my ($key, $v) = @_;
    my $t = $TYPE{$key} // 'str';
    if ($t eq 'bool') {
        return $v ? 1 : 0 if ref $v;
        return ($v =~ /^(1|true|yes|on)$/i) ? 1 : 0;
    }
    if ($t eq 'num') {
        return undef unless defined $v && "$v" =~ /^-?[0-9]+(\.[0-9]+)?$/;
        return 0 + $v;
    }
    if ($t eq 'dir' || $t eq 'file') { return util::expand_tilde(util::to_bytes("$v")) }
    return "$v";
}

sub config_dir { return $ENV{CLAUDE_CONFIG_DIR} && $ENV{CLAUDE_CONFIG_DIR} ne '' ? util::expand_tilde($ENV{CLAUDE_CONFIG_DIR}) : util::home() . '/.claude' }

# CR-F34 (DP-3, provisional): the consent keys come from ~/.claude/settings.json only. A
# command the model runs can set CLAUDE_CONFIG_DIR, so a settings file it names cannot
# grant consent: when CLAUDE_CONFIG_DIR names another folder than ~/.claude, each consent
# key takes its safe value (%SAFE: no repository accepted, automatic relaunch off, no
# allow patterns) with the note `<key>: CLAUDE_CONFIG_DIR is not ~/.claude, safe value used`.
our %SAFE = (repo_roots => '', relaunch_auto => 'off', relaunch_allow => '');
sub consent_dir { return util::home() . '/.claude' }
sub config_dir_foreign {
    my $cd = config_dir();
    my $home = consent_dir();
    return 0 if util::clean_path($cd) eq util::clean_path($home);
    my ($rc, $rh) = (util::real_path($cd), util::real_path($home));
    return 0 if defined $rc && defined $rh && $rc eq $rh;
    my @a = stat $cd;
    my @b = stat $home;
    return 0 if @a && @b && $a[0] == $b[0] && $a[1] == $b[1];
    return 1;
}

# Returns (options hashref or undef, note) from the user's settings file.
sub _settings_file_options {
    my $brand = ctx::brand();
    my $file = config_dir() . '/settings.json';
    my $raw = util::read_file($file);
    return (undef, undef) unless defined $raw;
    my $s = eval { jsonc::decode($raw) };
    return (undef, undef) unless ref $s eq 'HASH' && ref $s->{pluginConfigs} eq 'HASH';
    my $pc = $s->{pluginConfigs};
    my $pr = $ENV{CLAUDE_PLUGIN_ROOT};
    if (defined $pr && $pr ne '') {
        my $plugins = util::clean_path(config_dir() . '/plugins');
        my $p = util::clean_path($pr);
        if (index("$p/", "$plugins/") != 0) {
            my $k = "$brand\@inline";
            return (ref $pc->{$k} eq 'HASH' ? $pc->{$k}{options} : undef, $k);
        }
    }
    my @cand = grep { (split /\@/, $_, 2)[0] eq $brand } sort keys %$pc;
    return (undef, undef) unless @cand;
    return (undef, 'ambiguous') if @cand > 1;
    my $opts = ref $pc->{ $cand[0] } eq 'HASH' ? $pc->{ $cand[0] }{options} : undef;
    return (ref $opts eq 'HASH' ? $opts : undef, $cand[0]);
}

# resolve(\%flags) -> {values => {key => v}, source => {key => flag|env|settings|default},
#   notes => [..], ambiguous => 0|1, config_key => key-or-undef}
sub resolve {
    my ($flags) = @_;
    $flags ||= {};
    my %val;
    my %src;
    my @notes;
    my ($opts, $ckey) = _settings_file_options();
    my $ambiguous = (defined $ckey && $ckey eq 'ambiguous') ? 1 : 0;
    my $uc = ctx::user_config();
    my $foreign = config_dir_foreign();
    for my $k (@KEYS) {
        my ($key, $type, $fallback) = @$k;
        my $default = ref $uc->{$key} eq 'HASH' && exists $uc->{$key}{default} ? $uc->{$key}{default} : $fallback;
        my ($v, $s);
        my $env = $ENV{ 'CLAUDE_PLUGIN_OPTION_' . uc $key };
        my $file_only = $FILE_ONLY{$key};
        push @notes, "$key: settings file only" if $file_only && (!_unset($flags->{$key}) || !_unset($env));
        if ($file_only && $foreign) {
            push @notes, "$key: CLAUDE_CONFIG_DIR is not ~/.claude, safe value used";
            ($v, $s) = ($SAFE{$key}, 'safe');
        }
        elsif (!$file_only && !_unset($flags->{$key})) { ($v, $s) = ($flags->{$key}, 'flag') }
        elsif (!$file_only && !_unset($env)) { ($v, $s) = ($env, 'env') }
        elsif (!$ambiguous && ref $opts eq 'HASH' && !_unset($opts->{$key})) { ($v, $s) = ($opts->{$key}, 'settings') }
        else { ($v, $s) = ($default, 'default') }
        my $c = _coerce($key, $v);
        if (!defined $c) {
            push @notes, "$key: not a number, default used";
            ($c, $s) = (_coerce($key, $default), 'default');
        }
        $val{$key} = $c;
        $src{$key} = $s;
    }
    return { values => \%val, source => \%src, notes => \@notes, ambiguous => $ambiguous,
             config_key => ($ambiguous ? undef : $ckey) };
}

# list(value) -> entries of a `;`-separated list key (REVIEW B-5, escalation E-B-1:
# the encoding of `deny_class_patterns` until probe P-D12-2), trimmed, empty ones dropped.
sub list {
    my ($v) = @_;
    return () unless defined $v && !ref $v;
    return grep { $_ ne '' } map { my $x = $_; $x =~ s/^\s+|\s+$//g; $x } split /;/, $v;
}

# limits(key) -> (min, max) from the manifest's userConfig, else undef
sub limits {
    my ($key) = @_;
    my $u = ctx::user_config()->{$key};
    return (undef, undef) unless ref $u eq 'HASH';
    my ($lo, $hi) = map { (defined $_ && !ref $_ && /^-?\d+(\.\d+)?$/) ? 0 + $_ : undef } ($u->{min}, $u->{max});
    return ($lo, $hi);
}

# repo_roots(resolved) -> {roots => [real paths], stale => [entries], invalid => [entries]}
# (D-12 §1.5.4): each entry is absolute after `~` expansion; at most 64 entries; a missing
# or non-directory entry is stale; entries are compared by real path.
our $REPO_ROOTS_MAX = 64;
sub repo_roots {
    my ($r) = @_;
    my (@roots, @stale, @invalid, %seen);
    my @e = list($r->{values}{repo_roots});
    push @invalid, splice(@e, $REPO_ROOTS_MAX) if @e > $REPO_ROOTS_MAX;
    for my $x (@e) {
        my $p = util::expand_tilde(util::to_bytes($x));
        if ($p !~ m{^/}) { push @invalid, $x; next }
        if (!-d $p) { push @stale, $x; next }
        my $real = util::real_path($p) // $p;
        push @roots, $real unless $seen{$real}++;
    }
    return { roots => \@roots, stale => \@stale, invalid => \@invalid };
}

# relaunch(resolved) -> {auto => on|shadow|off, allow => [qr], quiet_s => n,
#   allow_active => 0, invalid => [{key, value}], clamped => [{key, configured, used}]}
# (Dev-1 config keys): another relaunch_auto value -> off; a relaunch_allow pattern that
# does not start with ^, is over 200 chars or does not compile is dropped; at most 32;
# relaunch_quiet_s clamped to the manifest's min/max (30-3600). `allow_active` is 0: the
# allow list is built but has no effect until the owner answers Q-J1-1 (DP-10).
our $ALLOW_MAX = 32;
our $ALLOW_LEN = 200;
sub relaunch {
    my ($r) = @_;
    my $v = $r->{values};
    my (@invalid, @clamped, @allow);
    my $auto = lc($v->{relaunch_auto} // 'on');
    $auto =~ s/^\s+|\s+$//g;
    if ($auto !~ /^(on|shadow|off)$/) { push @invalid, { key => 'relaunch_auto', value => $v->{relaunch_auto} }; $auto = 'off' }
    my @pats = list($v->{relaunch_allow});
    for my $i (0 .. $#pats) {
        my $p = $pats[$i];
        my $re = ($i < $ALLOW_MAX && $p =~ /^\^/ && length($p) <= $ALLOW_LEN) ? eval { qr/$p/ } : undef;
        if ($re) { push @allow, $re } else { push @invalid, { key => 'relaunch_allow', value => $p } }
    }
    my $q = $v->{relaunch_quiet_s};
    my ($lo, $hi) = limits('relaunch_quiet_s');
    ($lo, $hi) = ($lo // 30, $hi // 3600);
    my $used = !defined $q ? 120 : $q < $lo ? $lo : $q > $hi ? $hi : $q;
    push @clamped, { key => 'relaunch_quiet_s', configured => $q, used => $used } if defined $q && $used != $q;
    return { auto => $auto, allow => \@allow, quiet_s => $used, allow_active => 0, invalid => \@invalid, clamped => \@clamped };
}

# Pull settings flags out of a parsed-flag hash (keys as given on the command line).
sub flags_from {
    my ($opt) = @_;
    my %f;
    for my $k (keys %$opt) {
        my $key = $FLAG_ALIAS{$k};
        if (!$key) { (my $u = $k) =~ tr/-/_/; $key = $u if exists $TYPE{$u} }
        $f{$key} = $opt->{$k} if $key;
    }
    return \%f;
}

1;
