package settings;
# lib/settings.pm: settings order of BUILD-PLAN §3.1 / MOD-SPEC §2.6. Owner: WP-core.
#   explicit flag -> CLAUDE_PLUGIN_OPTION_<KEY> -> pluginConfigs[<key>].options in
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json -> userConfig default.
# Empty values and values starting `${user_config.` count as unset; a leading ~ is
# expanded. pluginConfigs key (E-14, provisional): `<name>@inline` when
# CLAUDE_PLUGIN_ROOT is set and not under the config dir's plugins/; otherwise the
# single key whose part before `@` is the brand; several -> defaults + ambiguous.
use strict;
use warnings;

# The 21 keys of MOD-SPEC §1.2 with their types; defaults come from plugin.json
# userConfig (one source), the third column only when the manifest lacks the key.
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
);
our %TYPE = map { $_->[0] => $_->[1] } @KEYS;

# Flag spellings: --<key with dashes>, plus the short forms the skills pass.
our %FLAG_ALIAS = (
    'root' => 'handoff_root', 'log-dir' => 'log_dir', 'disposable-root' => 'disposable_root',
    'keep-days' => 'disposable_keep_days', 'quota-mb' => 'evidence_quota_mb', 'queue-cmd' => 'queue_cmd',
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
    if ($t eq 'dir' || $t eq 'file') { return util::expand_tilde("$v") }
    return "$v";
}

sub config_dir { return $ENV{CLAUDE_CONFIG_DIR} && $ENV{CLAUDE_CONFIG_DIR} ne '' ? util::expand_tilde($ENV{CLAUDE_CONFIG_DIR}) : util::home() . '/.claude' }

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
    for my $k (@KEYS) {
        my ($key, $type, $fallback) = @$k;
        my $default = ref $uc->{$key} eq 'HASH' && exists $uc->{$key}{default} ? $uc->{$key}{default} : $fallback;
        my ($v, $s);
        if (!_unset($flags->{$key})) { ($v, $s) = ($flags->{$key}, 'flag') }
        elsif (!_unset($ENV{ 'CLAUDE_PLUGIN_OPTION_' . uc $key })) { ($v, $s) = ($ENV{ 'CLAUDE_PLUGIN_OPTION_' . uc $key }, 'env') }
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
