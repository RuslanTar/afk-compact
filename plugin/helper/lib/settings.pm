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
# note `<key>: settings file only`. That file is the account's ~/.claude/settings.json: a
# CLAUDE_CONFIG_DIR or HOME naming another folder gives the consent keys their safe values
# (CR-F34, config_dir_foreign). Paths (dir and file keys) are UTF-8 bytes whatever
# their source, as env, flag and file-system values are (SR 1.1).
use strict;
use warnings;
use utf8;

# The 32 keys of MOD-SPEC §1.2: type; fallback (used only when the manifest lacks the key:
# defaults and min/max come from plugin.json userConfig, one source; the config-defaults gate
# holds the fallback equal to the manifest default); export class (W-BETA D, AT-WB-08: num,
# bool, enum, path, list or drop; export_view()).
our @KEYS = (
    [handoff_root                => 'dir',  '~/.claude/handoffs',      'path'],
    [log_dir                     => 'dir',  '',                        'path'],
    [disposable_root             => 'dir',  '~/.claude/trash-staging', 'path'],
    [disposable_keep_days        => 'num',  0,                         'num'],
    [evidence_quota_mb           => 'num',  500,                       'num'],
    [queue_cmd                   => 'file', '',                        'path'],
    [triggers                    => 'bool', 1,                         'bool'],
    [compact_target_tokens       => 'num',  400000,                    'num'],
    [compact_soft_max_tokens     => 'num',  600000,                    'num'],
    [native_window_tokens        => 'num',  0,                         'num'],
    [boundary_delay_ms           => 'num',  2000,                      'num'],
    [cooldown_ms                 => 'num',  30000,                     'num'],
    [max_auto_continues_per_hour => 'num',  6,                         'num'],    # owner 2026-10-22 04:10 (S-SETTINGS A)
    [measured_block              => 'bool', 0,                         'bool'],
    [auto_evidence               => 'bool', 1,                         'bool'],
    [warn_ui                     => 'bool', 1,                         'bool'],
    [watcher                     => 'str',  'shadow',                  'enum'],
    [stall_min                   => 'num',  60,                        'num'],
    [cache_ttl_s                 => 'num',  300,                       'num'],
    [otel_log_path               => 'file', '',                        'path'],
    [deny_class_patterns         => 'str',  '',                        'list'],
    # design pass of 2026-10-21: D-18 (mod keys), D-12 and Dev-1 (helper keys)
    [handoff_turn                => 'str',  'halt',                    'enum'],
    [handoff_turn_max_tokens     => 'num',  64000,                     'num'],
    [repo_roots                  => 'str',  '',                        'list'],
    [relaunch_auto               => 'str',  'on',                      'enum'],
    [relaunch_allow              => 'str',  '',                        'list'],
    [relaunch_quiet_s            => 'num',  120,                       'num'],
    # 2026-10-22: S-SETTINGS B (helper), D (mod; the default is OD-4 provisional, BLD-08), IC-1 (mod)
    [unattended_prod_reads       => 'str',  'forbid',                  'enum'],
    [prod_patterns               => 'str',  '',                        'list'],
    [precompact_turn             => 'str',  'model',                   'enum'],
    [idle_handoff_turn           => 'str',  'off',                     'enum'],
    [idle_handoff_min_tokens     => 'num',  200000,                    'num'],
);
our %TYPE = map { $_->[0] => $_->[1] } @KEYS;
our %EXPORT = map { $_->[0] => $_->[3] } @KEYS;
# The values an enum key exports as is (W-BETA D); any other value exports as `other`.
our %ENUM = (watcher => [qw(shadow off)], handoff_turn => [qw(halt off)], relaunch_auto => [qw(on shadow off)],
             unattended_prod_reads => [qw(forbid allow)], precompact_turn => [qw(model code)], idle_handoff_turn => [qw(off on)]);

# DP-3: keys that let the plugin act without asking. Read from the settings file only, and
# given their %SAFE value when the settings folder is not the account's ~/.claude (CR-F34).
# queue_cmd is one (Q-ADAPTER QA-B1, QU-02: an injected flag would run a program), and so is
# unattended_prod_reads (S-SETTINGS B).
our %FILE_ONLY = map { $_ => 1 } qw(repo_roots relaunch_auto relaunch_allow unattended_prod_reads queue_cmd);
# Protective keys (S-SETTINGS B, MOD-SPEC §2.6): they can only make the plugin ask or withhold
# more. Flags and env are ignored with the same note; the value comes from the config dir's
# settings file, and a foreign config dir does not reset it (that would weaken protection).
our %NO_FLAG = map { $_ => 1 } qw(prod_patterns);

# Flag spellings: --<key with dashes>, plus the short forms the skills pass.
our %FLAG_ALIAS = (
    'root' => 'handoff_root', 'log-dir' => 'log_dir', 'disposable-root' => 'disposable_root',
    'keep-days' => 'disposable_keep_days', 'quota-mb' => 'evidence_quota_mb',
    # consent and protective keys: every subcommand takes the flag and ignores it with the note
    # `<key>: settings file only` (DP-3, DP-17 / E-C-6), never a usage error
    'repo-roots' => 'repo_roots', 'relaunch-auto' => 'relaunch_auto', 'relaunch-allow' => 'relaunch_allow',
    'unattended-prod-reads' => 'unattended_prod_reads', 'prod-patterns' => 'prod_patterns', 'queue-cmd' => 'queue_cmd',
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
    return util::text("$v");    # a text value is characters (§2.6); paths above stay bytes (SR 1.1)
}

sub config_dir { return $ENV{CLAUDE_CONFIG_DIR} && $ENV{CLAUDE_CONFIG_DIR} ne '' ? util::expand_tilde($ENV{CLAUDE_CONFIG_DIR}) : util::home() . '/.claude' }

# CR-F34 (DP-3, provisional): the consent keys come from ~/.claude/settings.json only,
# where ~ is the account's home from the user database (getpwuid), not $HOME. A command
# the model runs can set CLAUDE_CONFIG_DIR and HOME, so a settings file they name cannot
# grant consent: when the settings folder is another folder than the account's ~/.claude,
# each consent key takes its safe value (%SAFE: no repository accepted, automatic relaunch
# off, no allow patterns) with the note `<key>: CLAUDE_CONFIG_DIR is not ~/.claude, safe
# value used` (CLAUDE_CONFIG_DIR set) or `<key>: HOME is not the account home, safe value
# used`. Test seam: the helper test runner's staged plugin copy holds the file
# $TEST_CONSENT_MARK at its root; only there and with STORE_TEST_MODE=1 is the consent
# folder $HOME/.claude (each case runs in a fresh HOME). The shipped plugin has no such
# file, so env alone cannot move the consent folder.
our %SAFE = (repo_roots => '', relaunch_auto => 'off', relaunch_allow => '', unattended_prod_reads => 'forbid', queue_cmd => '');
our $TEST_CONSENT_MARK = '.test-consent-home';
sub account_home { my $h = (getpwuid($<))[7]; return defined $h && $h ne '' ? $h : undef }
sub consent_dir {
    my $r = ctx::root();
    return util::home() . '/.claude' if util::test_mode() && defined $r && -f "$r/$TEST_CONSENT_MARK";
    my $h = account_home();
    return defined $h ? "$h/.claude" : undef;
}
sub config_dir_foreign {
    my $cd = config_dir();
    my $home = consent_dir();
    return 1 unless defined $home;
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
        my ($key, $type, $fallback) = @$k[0 .. 2];
        my $default = ref $uc->{$key} eq 'HASH' && exists $uc->{$key}{default} ? $uc->{$key}{default} : $fallback;
        my ($v, $s);
        my $env = $ENV{ 'CLAUDE_PLUGIN_OPTION_' . uc $key };
        my $file_only = $FILE_ONLY{$key};
        my $no_flag = $NO_FLAG{$key};
        push @notes, "$key: settings file only" if ($file_only || $no_flag) && (!_unset($flags->{$key}) || !_unset($env));
        if ($file_only && $foreign) {
            push @notes, ($ENV{CLAUDE_CONFIG_DIR} // '') ne '' ? "$key: CLAUDE_CONFIG_DIR is not ~/.claude, safe value used"
                                                             : "$key: HOME is not the account home, safe value used";
            ($v, $s) = ($SAFE{$key}, 'safe');
        }
        elsif (!$file_only && !$no_flag && !_unset($flags->{$key})) { ($v, $s) = ($flags->{$key}, 'flag') }
        elsif (!$file_only && !$no_flag && !_unset($env)) { ($v, $s) = ($env, 'env') }
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
#   allow_active => 1, invalid => [{key, value}], clamped => [{key, configured, used}]}
# (Dev-1 config keys): another relaunch_auto value -> off; a relaunch_allow pattern that
# does not start with ^, is over 200 chars or does not compile is dropped; at most 32;
# relaunch_quiet_s clamped to the manifest's min/max (30-3600). `allow_active` is 1: the
# allow list takes effect (owner Q-J1-1, 2026-10-22 03:10; S-SETTINGS C). A match makes class
# `local` only for a single command with no shell chaining (skills' jobs.pm checks that).
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
    return { auto => $auto, allow => \@allow, quiet_s => $used, allow_active => 1, invalid => \@invalid, clamped => \@clamped };
}

# ---------------------------------------------------------------- production (S-SETTINGS B)
# prod(resolved) -> {reads => forbid|allow, classes => [{id, re}], user => n, invalid => [{key, index?, value}]}
# `unattended_prod_reads` (consent key, file only): trimmed and case-folded, `forbid` or `allow`,
# anything else `forbid` plus an invalid entry. The production classes are the shipped ones
# (handoff-spec `prod_classes`, id `prod-token`), then `prod_patterns` (protective, file only)
# as `user-prod-<n>` (n = 1-based position in the setting): at most 32, each at most 200 chars,
# compiling, within the Dev-7 limits (no `(?{`, `(??{`, `(*`); no `^` is required. A dropped
# pattern is an invalid entry {key: prod_patterns, index: n}; rows never carry the pattern.
our $PROD_MAX = 32;
our $PROD_LEN = 200;
# Used only when the spec asset has no `prod_classes` (an asset older than T-TEXT E2): the same
# literal as the handoff-spec block, so a missing key never makes the plugin ask less.
our @PROD_FALLBACK = ({ id => 'prod-token', re => '(^|[^A-Za-z0-9])([Pp][Rr][Oo][Dd]|[Pp][Rr][Oo][Dd][Uu][Cc][Tt][Ii][Oo][Nn]|[Pp][Rr][Dd])([^A-Za-z0-9]|$)' });

# pattern_ok(text, max_len) -> compiled regex, or undef (too long, an eval group or verb, or not compiling)
sub pattern_ok {
    my ($p, $max) = @_;
    return undef unless defined $p && !ref $p && $p ne '' && length($p) <= ($max // $PROD_LEN);
    return undef if $p =~ /\(\?\??\{|\(\*/;
    my $re = eval { local $SIG{__WARN__} = sub { }; qr/$p/ };
    return $re;
}

sub prod {
    my ($r) = @_;
    my $v = $r->{values} || {};
    my (@invalid, @classes);
    my $reads = lc($v->{unattended_prod_reads} // 'forbid');
    $reads =~ s/^\s+|\s+$//g;
    if ($reads !~ /^(forbid|allow)$/) { push @invalid, { key => 'unattended_prod_reads', value => $v->{unattended_prod_reads} }; $reads = 'forbid' }
    my @shipped = spec::has('prod_classes') ? spec::list('prod_classes') : @PROD_FALLBACK;
    for my $c (@shipped) {
        next unless ref $c eq 'HASH' && defined $c->{id} && defined $c->{re};
        my $re = eval { qr/$c->{re}/ } or next;
        push @classes, { id => $c->{id}, re => $re };
    }
    my @pats = list($v->{prod_patterns});
    my $user = 0;
    for my $i (0 .. $#pats) {
        my $re = $i < $PROD_MAX ? pattern_ok($pats[$i]) : undef;
        if ($re) { push @classes, { id => 'user-prod-' . ($i + 1), re => $re }; $user++ }
        else { push @invalid, { key => 'prod_patterns', index => $i + 1 } }
    }
    return { reads => $reads, classes => \@classes, user => $user, invalid => \@invalid };
}

# prod_class(text, prod) -> the id of the first production class the text matches, or undef
sub prod_class {
    my ($text, $p) = @_;
    return undef unless defined $text;
    for my $c (@{ ($p || {})->{classes} || [] }) { return $c->{id} if $text =~ $c->{re} }
    return undef;
}

# ---------------------------------------------------------------- export (W-BETA D)
# export_view(resolved) -> ordered object {key => exported value} for every key whose class is
# not `drop`: num/bool as is; enum the value when it is one of the key's values, else `other`;
# path `unset` (empty), `default`, `custom-in-home` or `custom` (never the path); list the
# entry count (never the entries).
sub export_view {
    my ($r) = @_;
    my $v = $r->{values} || {};
    my $uc = ctx::user_config();
    my $home = util::home();
    my @kv;
    for my $k (@KEYS) {
        my ($key, $type, $fallback, $class) = @$k;
        next if !defined $class || $class eq 'drop';
        my $x = $v->{$key};
        my $out;
        if ($class eq 'num') { $out = defined $x ? 0 + $x : undef }
        elsif ($class eq 'bool') { $out = jsonc::bool($x) }
        elsif ($class eq 'enum') {
            my $c = lc($x // '');
            $c =~ s/^\s+|\s+$//g;
            $out = (grep { $_ eq $c } @{ $ENUM{$key} || [] }) ? $c : 'other';
        }
        elsif ($class eq 'list') { $out = scalar(my @e = list($x)) }
        elsif ($class eq 'path') {
            my $default = ref $uc->{$key} eq 'HASH' && exists $uc->{$key}{default} ? $uc->{$key}{default} : $fallback;
            my $d = defined $default && $default ne '' ? util::expand_tilde(util::to_bytes("$default")) : '';
            my $p = defined $x ? util::to_bytes("$x") : '';
            $out = $p eq '' ? 'unset'
                 : ($d ne '' && util::clean_path($p) eq util::clean_path($d)) ? 'default'
                 : ($home ne '' && $home ne '/' && index(util::clean_path($p) . '/', util::to_bytes($home) . '/') == 0) ? 'custom-in-home'
                 : 'custom';
        }
        else { next }
        push @kv, $key => $out;
    }
    return jsonc::obj(@kv);
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
