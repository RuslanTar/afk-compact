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
require "userre.pm";    # U-06: the time bound for the user's own patterns

# The keys of MOD-SPEC §1.2 (42 with restart_on_update): type; fallback (used only when the manifest lacks the key:
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
    # 2026-10-22: S-SETTINGS B (helper), D (mod; the default `model` is the owner's xxxxxxxx-18,
    # 2026-10-23 01:48, E-1 checks it; PT-1), IC-1 (mod)
    [unattended_prod_reads       => 'str',  'forbid',                  'enum'],
    [prod_patterns               => 'str',  '',                        'list'],
    [precompact_turn             => 'str',  'model',                   'enum'],
    # idle D3 (owner 2026-10-23 02:4x, IA-1): `auto` = the plugin's pre-idle turn only while
    # Claude Code's own idle compaction is off; `off` = never (the old `on` reads as auto)
    [idle_handoff_turn           => 'str',  'auto',                    'enum'],
    [idle_handoff_min_tokens     => 'num',  200000,                    'num'],
    # IDLE-COMPACT-SPEC (D9): `auto` = the plugin compacts an idle session itself while Claude
    # Code's own idle compaction is off (`"idleCompaction": false`); `off` = never
    [idle_compact                => 'str',  'auto',                    'enum'],
    # SK-7 (owner 2026-10-23 xxxxxxxx-12/-13/-14, "Add both keys"; S-SETTINGS E1-E6)
    [ticket_pattern              => 'str',  '[A-Z][A-Z0-9]+-[0-9]+',   'drop'],
    [secret_extra_rules          => 'str',  '',                        'list'],
    [resume_proceed              => 'str',  'auto',                    'enum'],
    [handoff_reuse_window_min    => 'num',  15,                        'num'],
    [evidence_total_max_mb       => 'num',  50,                        'num'],
    [watch_quota_mb              => 'num',  50,                        'num'],
    # owner xxxxxxxx-29 (2026-10-23, "add the add-only setting now"): branches added to the
    # shipped protected list (protected() below); a protective key
    [protected_branches          => 'str',  '',                        'list'],
    # owner 2026-10-26 (GSD re-entry per session; review of the first build): loop skills, beside
    # the shipped list (lib/gsd.pm %DRIVERS), that a session re-enters when it invoked them
    [driver_skills               => 'str',  '',                        'list'],
    # SESSION-RESTART D1 (owner 19:08, 2026-10-27): `on` = move a session onto a newly installed
    # Claude Code at a compaction boundary; `shadow` = log the verdict only; `off` = never. A
    # consent key (settings file only); any other value reads as off with a note.
    [restart_on_update           => 'str',  'off',                     'enum'],
);
our %TYPE = map { $_->[0] => $_->[1] } @KEYS;
our %EXPORT = map { $_->[0] => $_->[3] } @KEYS;
# The values an enum key exports as is (W-BETA D); any other value exports as `other`.
our %ENUM = (watcher => [qw(shadow off)], handoff_turn => [qw(halt off)], relaunch_auto => [qw(on shadow off)],
             unattended_prod_reads => [qw(forbid allow)], precompact_turn => [qw(model code)], idle_handoff_turn => [qw(auto off)], idle_compact => [qw(auto off)],
             resume_proceed => [qw(auto confirm)], restart_on_update => [qw(off shadow on)]);

# DP-3: keys that let the plugin act without asking. Read from the settings file only, and
# given their %SAFE value when the settings folder is not the account's ~/.claude (CR-F34).
# queue_cmd is one (Q-ADAPTER QA-B1, QU-02: an injected flag would run a program), and so is
# unattended_prod_reads (S-SETTINGS B).
# restart_on_update is one (SESSION-RESTART D1): it lets the plugin end and restart a session.
our %FILE_ONLY = map { $_ => 1 } qw(repo_roots relaunch_auto relaunch_allow unattended_prod_reads queue_cmd restart_on_update);
# Protective keys (S-SETTINGS B, MOD-SPEC §2.6): they can only make the plugin ask or withhold
# more. Flags and env are ignored with the same note; the value comes from the config dir's
# settings file, and a foreign config dir does not reset it (that would weaken protection).
# protected_branches is one (owner xxxxxxxx-29): a flag or env value that replaced the file's
# list would drop the user's own entries.
our %NO_FLAG = map { $_ => 1 } qw(prod_patterns secret_extra_rules protected_branches);
# Tighten-only keys (S-SETTINGS E3): every source counts and the strictest value wins, so a flag
# or env can make the plugin stricter, never looser than the settings file. Values from loose to
# strict.
our %TIGHTEN = (resume_proceed => [qw(auto confirm)]);
# Owner xxxxxxxx-13 (2026-10-26, "Off + common words"; SPEC-DELTAS IA-1 / AT-IA-01): an
# idle_handoff_turn value of false, no, none, disabled or 0 reads as off; true, yes, 1 or on as
# auto; any other value reads as $IDLE_INVALID with a note (/status), the value with no extra
# plugin action, as for the other keys. The same lists and value as config.ts IDLE_OFF_WORDS,
# IDLE_AUTO_WORDS and IDLE_INVALID_READS_AS.
our @IDLE_OFF_WORDS = qw(off false no none disabled 0);
our @IDLE_AUTO_WORDS = qw(auto true yes 1 on);
our $IDLE_INVALID = 'off';

# Flag spellings: --<key with dashes>, plus the short forms the skills pass.
our %FLAG_ALIAS = (
    'root' => 'handoff_root', 'log-dir' => 'log_dir', 'disposable-root' => 'disposable_root',
    'keep-days' => 'disposable_keep_days', 'quota-mb' => 'evidence_quota_mb',
    # consent and protective keys: every subcommand takes the flag and ignores it with the note
    # `<key>: settings file only` (DP-3, DP-17 / E-C-6), never a usage error
    'repo-roots' => 'repo_roots', 'relaunch-auto' => 'relaunch_auto', 'relaunch-allow' => 'relaunch_allow',
    'unattended-prod-reads' => 'unattended_prod_reads', 'prod-patterns' => 'prod_patterns', 'queue-cmd' => 'queue_cmd',
    'secret-extra-rules' => 'secret_extra_rules', 'protected-branches' => 'protected_branches',
    'restart-on-update' => 'restart_on_update',
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
# Owner 2026-10-27 20:38 (SESSION-RESTART §9 Q1 (a)): a settings folder whose settings.json
# is the account's ~/.claude/settings.json (a symlink to it, or a hard link: the same file
# by its real path or its device and inode) counts as that folder for every consent key: it is
# the same bytes, so no new trust. Another file there still gives the safe values.
our %SAFE = (repo_roots => '', relaunch_auto => 'off', relaunch_allow => '', unattended_prod_reads => 'forbid', queue_cmd => '',
             restart_on_update => 'off');
our $TEST_CONSENT_MARK = '.test-consent-home';
sub account_home { my $h = (getpwuid($<))[7]; return defined $h && $h ne '' ? $h : undef }
sub consent_dir {
    my $r = ctx::root();
    return util::home() . '/.claude' if util::test_mode() && defined $r && -f "$r/$TEST_CONSENT_MARK";
    my $h = account_home();
    return defined $h ? "$h/.claude" : undef;
}
# config_dir_other() -> 1 when the settings folder is not the consent folder itself (by its path,
# real path or device and inode). The owner-local trial keeps this rule (trial::owner_skip).
sub config_dir_other {
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

# config_dir_foreign() -> 1 when the consent keys take their safe values: another settings folder
# whose settings.json is not the consent folder's own (owner 2026-10-27 20:38).
sub config_dir_foreign {
    return 0 unless config_dir_other();
    my $cd = config_dir();
    my $home = consent_dir();
    return same_settings_file("$cd/settings.json", "$home/settings.json") ? 0 : 1;
}

# same_settings_file(a, b) -> 1 when both name one existing regular file: the same real path
# (a symlink to the other, or to the same target) or the same device and inode (a hard link).
# Two files with equal bytes are not the same file.
sub same_settings_file {
    my ($a, $b) = @_;
    return 0 unless -f $a && -f $b;
    require Cwd;
    my ($ra, $rb) = (Cwd::abs_path($a), Cwd::abs_path($b));
    return 1 if defined $ra && defined $rb && $ra eq $rb;
    my @x = stat $a;
    my @y = stat $b;
    return (@x && @y && $x[0] == $y[0] && $x[1] == $y[1]) ? 1 : 0;
}

# The plugin's names before its rename (NM-2; rename-order ruling xxxxxxxx-32, 2026-10-23): a
# `pluginConfigs` key `<former name>@<marketplace>` holds options this plugin never reads, and
# /status says so. The stale-name gate allows a former name on this declaration line only.
our @FORMER_NAMES = ('compactinue');

# former_name_keys() -> ([key, option count]…): the settings file's pluginConfigs keys that start
# `<former name>@` (the current name excluded), sorted. Read-only; key names and counts, no value.
sub former_name_keys {
    my $brand = ctx::brand() // '';
    my @names = grep { $_ ne $brand } @FORMER_NAMES;
    return () unless @names;
    my $raw = util::read_file(config_dir() . '/settings.json');
    return () unless defined $raw;
    my $s = eval { jsonc::decode($raw) };
    return () unless ref $s eq 'HASH' && ref $s->{pluginConfigs} eq 'HASH';
    my $pc = $s->{pluginConfigs};
    my @out;
    for my $k (sort keys %$pc) {
        next unless grep { index($k, "$_\@") == 0 } @names;
        my $o = ref $pc->{$k} eq 'HASH' ? $pc->{$k}{options} : undef;
        push @out, [ $k, scalar(keys %$o) ] if ref $o eq 'HASH' && %$o;
    }
    return @out;
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
    # Tighten-only keys (S-SETTINGS E3): the strictest valid value of flag, env, settings file
    # and default wins; an invalid value counts as unset (with a note).
    for my $key (sort keys %TIGHTEN) {
        my @order = @{ $TIGHTEN{$key} };
        my %rank = map { $order[$_] => $_ } 0 .. $#order;
        my $env = $ENV{ 'CLAUDE_PLUGIN_OPTION_' . uc $key };
        my $uck = ref $uc->{$key} eq 'HASH' && exists $uc->{$key}{default} ? $uc->{$key}{default} : undef;
        my ($best, $bsrc);
        for my $cand (['settings', (!$ambiguous && ref $opts eq 'HASH') ? $opts->{$key} : undef], ['flag', $flags->{$key}],
                      ['env', $env], ['default', $uck // (grep { $_->[0] eq $key } @KEYS)[0]->[2]]) {
            my ($s, $v) = @$cand;
            next if _unset($v) || ref $v;
            my $x = trim(lc $v);
            if (!exists $rank{$x}) { push @notes, "$key: '$s' value is not " . join(' or ', @order) . ', ignored' if $s ne 'default'; next }
            ($best, $bsrc) = ($x, $s) if !defined $best || $rank{$x} > $rank{$best};
        }
        $best //= $order[0];
        push @notes, "$key: the stricter $best ($bsrc) is used" if defined $bsrc && $bsrc ne ($src{$key} // '') && $src{$key} ne 'default';
        ($val{$key}, $src{$key}) = ($best, $bsrc // 'default');
    }
    # idle D3 (IA-1, as config.ts reads it): trimmed and case-folded; the old value `on` reads as
    # `auto` with a note; the common words read as off or auto (@IDLE_OFF_WORDS, @IDLE_AUTO_WORDS,
    # owner xxxxxxxx-13); any other value is $IDLE_INVALID with a note.
    {
        my $x = trim(lc($val{idle_handoff_turn} // 'auto'));
        if ($x eq '') {
            # Blank once trimmed (spaces, a tab) is unset, as config.ts unset() reads it: the
            # default, no note (review r2: /status said off while the hooks ran auto).
            my $d = ref $uc->{idle_handoff_turn} eq 'HASH' && exists $uc->{idle_handoff_turn}{default}
                ? $uc->{idle_handoff_turn}{default} : (grep { $_->[0] eq 'idle_handoff_turn' } @KEYS)[0]->[2];
            $x = trim(lc($d // 'auto'));
            $src{idle_handoff_turn} = 'default';
        }
        if ($x eq 'on') { push @notes, 'idle_handoff_turn: on reads as auto'; $x = 'auto' }
        elsif (grep { $_ eq $x } @IDLE_OFF_WORDS) { $x = 'off' }
        elsif (grep { $_ eq $x } @IDLE_AUTO_WORDS) { $x = 'auto' }
        else { push @notes, "idle_handoff_turn: not auto, off or a yes/no word, $IDLE_INVALID used"; $x = $IDLE_INVALID }
        $val{idle_handoff_turn} = $x;
    }
    # idle_compact (IDLE-COMPACT-SPEC §5, as config.ts reads it): the same word lists and invalid
    # value as idle_handoff_turn; a new key, so no legacy `on` note (`on` is an auto word).
    {
        my $x = trim(lc($val{idle_compact} // 'auto'));
        if ($x eq '') {
            my $d = ref $uc->{idle_compact} eq 'HASH' && exists $uc->{idle_compact}{default}
                ? $uc->{idle_compact}{default} : (grep { $_->[0] eq 'idle_compact' } @KEYS)[0]->[2];
            $x = trim(lc($d // 'auto'));
            $src{idle_compact} = 'default';
        }
        if (grep { $_ eq $x } @IDLE_OFF_WORDS) { $x = 'off' }
        elsif (grep { $_ eq $x } @IDLE_AUTO_WORDS) { $x = 'auto' }
        else { push @notes, "idle_compact: not auto, off or a yes/no word, $IDLE_INVALID used"; $x = $IDLE_INVALID }
        $val{idle_compact} = $x;
    }
    # restart_on_update (SESSION-RESTART D1): trimmed and case-folded; off, shadow or on, else
    # off with a note (never the value). A blank value is unset: the default.
    {
        my $x = trim(lc($val{restart_on_update} // 'off'));
        if ($x eq '') { $x = 'off'; $src{restart_on_update} = 'default' }
        if ($x !~ /\A(?:off|shadow|on)\z/) { push @notes, 'restart_on_update: not off, shadow or on, off used'; $x = 'off' }
        $val{restart_on_update} = $x;
    }
    # SK-1 / SK-2: an invalid ticket_pattern or secret_extra_rules entry is noted (never echoed).
    my $tr = ticket_re({ values => \%val });
    push @notes, 'ticket_pattern: invalid, the default is used' if $tr->{invalid};
    my $sx = secret_extra({ values => \%val });
    push @notes, "secret_extra_rules: entry $_ dropped (invalid)" for @{ $sx->{invalid} };
    return { values => \%val, source => \%src, notes => \@notes, ambiguous => $ambiguous,
             config_key => ($ambiguous ? undef : $ckey) };
}

# ---------------------------------------------------------------- SK-7 helpers (2026-10-23)
# num_clamped(key[, resolved]) -> (value, clamped 0|1): a number key within the manifest's
# min/max (S-SETTINGS E4-E6: handoff_reuse_window_min 0-60, evidence_total_max_mb 10-500,
# watch_quota_mb 0-10000); unset or not a number gives the @KEYS fallback.
sub num_clamped {
    my ($key, $r) = @_;
    $r //= _current();
    my $v = ref $r eq 'HASH' && ref $r->{values} eq 'HASH' ? $r->{values}{$key} : undef;
    my ($row) = grep { $_->[0] eq $key } @KEYS;
    my $fb = $row ? $row->[2] : undef;
    my $uc = eval { ctx::user_config()->{$key} };
    $fb = $uc->{default} if ref $uc eq 'HASH' && defined $uc->{default} && !ref $uc->{default};
    $v = $fb unless defined $v && !ref $v && "$v" =~ /\A-?[0-9]+(\.[0-9]+)?\z/;
    return (undef, 0) unless defined $v;
    my ($lo, $hi) = eval { limits($key) };
    my $used = (defined $lo && $v < $lo) ? $lo : (defined $hi && $v > $hi) ? $hi : 0 + $v;
    return ($used, $used == $v ? 0 : 1);
}

# The resolved settings of this run (rc), else a fresh resolve.
sub _current {
    my $r = eval { rc::settings() };
    return $r if ref $r eq 'HASH';
    return eval { resolve({}) } // { values => {} };
}

# ticket_pattern (SK-1, S-SETTINGS E1): one ticket rule for the bucket (bucket.pm), the skills
# (gitfacts::ticket) and the queue lane slug. ticket_re([resolved]) -> {re, custom 0|1, invalid
# 0|1}: the user's pattern when it is at most 200 characters, compiles and keeps the Dev-7
# limits (no `(?{`, `(??{`, `(*`), else the shipped default (invalid 1). ticket(text[, resolved,
# default_only]) -> the id (group 1 when the pattern has one, else the whole match) when it
# matches \A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z, else undef (no `..` or `/` in a bucket path).
# The subject is cut to 256 characters (a branch name). A custom pattern runs with the time
# bound of lib/userre.pm (U-06): one that is stopped gives no ticket.
our $TICKET_DEFAULT = '[A-Z][A-Z0-9]+-[0-9]+';
our $TICKET_ID = qr/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/;
sub ticket_re {
    my ($r) = @_;
    $r //= _current();
    my $p = ref $r eq 'HASH' && ref $r->{values} eq 'HASH' ? $r->{values}{ticket_pattern} : undef;
    return { re => qr/$TICKET_DEFAULT/, custom => 0, invalid => 0 } if _unset($p) || ref $p || $p eq $TICKET_DEFAULT;
    my $re = pattern_ok($p, 200);
    return $re ? { re => $re, custom => 1, invalid => 0 } : { re => qr/$TICKET_DEFAULT/, custom => 0, invalid => 1 };
}
sub ticket {
    my ($s, $r, $default_only) = @_;
    return undef unless defined $s && !ref $s && $s ne '';
    $s = substr($s, 0, 256);
    my $tr = $default_only ? { re => qr/$TICKET_DEFAULT/, custom => 0 } : ticket_re($r);
    my ($s0, $e0, $s1, $e1);
    if ($tr->{custom}) {
        my ($st, $pos) = userre::capture('ticket_pattern', { re => $tr->{re}, at => 1 }, $s);
        return undef unless $st eq 'ok' && $pos;
        ($s0, $e0, $s1, $e1) = @$pos;
    } else {
        return undef unless $s =~ $tr->{re};
        ($s0, $e0) = ($-[0], $+[0]);
        ($s1, $e1) = ($-[1], $+[1]) if @- > 1 && defined $-[1];
    }
    my $id = defined $s1 ? substr($s, $s1, $e1 - $s1) : substr($s, $s0, $e0 - $s0);
    return $id =~ $TICKET_ID ? $id : undef;
}

# secret_extra_rules (SK-2, S-SETTINGS E2): `;` list of HARD:<re>, WARN:<re>, NAME:<glob>
# (`\x3b` for a literal `;` in a glob; a regex reads it as `;` itself). At most 32 entries; a
# regex at most 200 characters, compiling, within the Dev-7 limits; a glob one name with * and ?.
# Additive only: the shipped rules and their exceptions always apply, so a user rule can only
# withhold more. Ids user-hard-<n>, user-warn-<n>, user-name-<n> (n = 1-based position); rows
# never carry the pattern. secret_extra([resolved]) -> {rules => [{id, class, re, at}],
# names => [{id, re}], invalid => [n…]}. A HARD or WARN rule runs with the time bound of
# lib/userre.pm (secrets.pm; a stopped rule withholds); a glob compiles to a regex that cannot
# backtrack (glob_re).
our $EXTRA_MAX = 32;
sub secret_extra {
    my ($r) = @_;
    $r //= _current();
    my $v = ref $r eq 'HASH' && ref $r->{values} eq 'HASH' ? $r->{values}{secret_extra_rules} : undef;
    my (@rules, @names, @invalid);
    my @e = list($v);
    for my $i (0 .. $#e) {
        my $n = $i + 1;
        my ($kind, $body) = $e[$i] =~ /\A(HARD|WARN|NAME):(.+)\z/s;
        if ($i >= $EXTRA_MAX || !defined $kind) { push @invalid, $n; next }
        if ($kind eq 'NAME') {
            (my $g = $body) =~ s/\\x3b/;/gi;
            if ($g =~ m{/} || length($g) > 200) { push @invalid, $n; next }
            push @names, { id => "user-name-$n", re => glob_re($g) };
            next;
        }
        my $re = pattern_ok($body, 200);
        if (!$re) { push @invalid, $n; next }
        push @rules, { id => 'user-' . lc($kind) . "-$n", class => $kind, re => $re, at => $n };
    }
    return { rules => \@rules, names => \@names, invalid => \@invalid };
}

# glob_re(glob[, flags]) -> a regex for a glob of literal characters, `?` (one character but `/`),
# `*` (any characters but `/`) and `**` (any characters with `flags` `**`; else two `*`), over the
# whole subject. U-06: `\A[^/]*a[^/]*a…\z`, the plain translation, backtracks polynomially (ten
# stars on a 200-character name ran for minutes). Here every star but the last is an atomic group
# that stops at the leftmost place where the next run of literals and `?` matches. With only `*`
# stars, or only `**` stars, the leftmost place is never worse than a later one (the runs have a
# fixed length; a later place leaves the stars after it less room, and a `*` from the earlier
# place reaches whatever it reaches from the later one), so the answer is the plain
# translation's, in time linear in the subject times the glob's length; the last star backtracks
# alone. glob_linear(glob, flags) -> 0 for a glob that mixes `*` and `**`, where that does not
# hold: the caller matches the plain translation with the time bound of lib/userre.pm.
sub glob_linear {
    my ($g, $flags) = @_;
    return 1 unless ($flags // '') eq '**';
    my @st = $g =~ /(\*+)/g;
    my %k = map { ($_ eq '*' ? '*' : '**') => 1 } @st;
    return keys(%k) > 1 ? 0 : 1;
}
sub glob_re {
    my ($g, $flags) = @_;
    my $dbl = ($flags // '') eq '**';
    my @tok = grep { $_ ne '' } split($dbl ? qr/(\*\*|\*|\?)/ : qr/(\*|\?)/, $g);
    # collapse runs of stars (`*` `*` reads as `*`, `**` `*` as `**`)
    my @t;
    for my $x (@tok) {
        my $star = $x eq '*' || $x eq '**';
        if ($star && @t && ($t[-1] eq '*' || $t[-1] eq '**')) { $t[-1] = '**' if $x eq '**'; next }
        push @t, $x;
    }
    my $lit = sub { join '', map { $_ eq '?' ? '[^/]' : quotemeta($_) } @_ };
    my @stars = grep { $t[$_] eq '*' || $t[$_] eq '**' } 0 .. $#t;
    my $rx = '\A';
    my $at = 0;
    for my $k (0 .. $#stars) {
        my $si = $stars[$k];
        $rx .= $lit->(@t[$at .. $si - 1]) if $si > $at;
        my $q = $t[$si] eq '**' ? '.*' : '[^/]*';
        my $end = $k < $#stars ? $stars[$k + 1] - 1 : $#t;
        my $seg = $lit->(@t[$si + 1 .. $end]);
        $rx .= $k < $#stars ? "(?>$q?$seg)" : "$q$seg";
        $at = $end + 1;
    }
    $rx .= $lit->(@t[$at .. $#t]) if !@stars && @t;
    $rx .= '\z';
    return qr/$rx/s;
}

# list(value) -> entries of a `;`-separated list key (REVIEW B-5, escalation E-B-1:
# the encoding of `deny_class_patterns` until probe P-D12-2), trimmed, empty ones dropped.
sub list {
    my ($v) = @_;
    return () unless defined $v && !ref $v;
    return grep { $_ ne '' } map { trim($_) } split /;/, $v;
}

# trim(text) -> text without leading and trailing white space. Two anchored substitutions, as
# s/^\s+|\s+$//g tries \s+$ from every space of an inner run: 40,000 spaces inside a value
# took 0.5 s, 400,000 took 43 s, before any length cap (U-06 review).
sub trim {
    my ($s) = @_;
    return $s unless defined $s;
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;
    return $s;
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
# does not start with ^ or that pattern_ok refuses (over 200 chars, an eval group or verb, a
# wildcard property, not compiling) is dropped; at most 32;
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
    $auto = trim($auto);
    if ($auto !~ /^(on|shadow|off)$/) { push @invalid, { key => 'relaunch_auto', value => $v->{relaunch_auto} }; $auto = 'off' }
    my @pats = list($v->{relaunch_allow});
    my @at;
    for my $i (0 .. $#pats) {
        my $p = $pats[$i];
        my $re = ($i < $ALLOW_MAX && $p =~ /^\^/) ? pattern_ok($p, $ALLOW_LEN) : undef;
        if ($re) { push @allow, $re; push @at, $i + 1 } else { push @invalid, { key => 'relaunch_allow', value => $p } }
    }
    my $q = $v->{relaunch_quiet_s};
    my ($lo, $hi) = limits('relaunch_quiet_s');
    ($lo, $hi) = ($lo // 30, $hi // 3600);
    my $used = !defined $q ? 120 : $q < $lo ? $lo : $q > $hi ? $hi : $q;
    push @clamped, { key => 'relaunch_quiet_s', configured => $q, used => $used } if defined $q && $used != $q;
    return { auto => $auto, allow => \@allow, allow_at => \@at, quiet_s => $used, allow_active => 1, invalid => \@invalid, clamped => \@clamped };
}

# relaunch_allowed(command, relaunch) -> 1 when a relaunch_allow pattern matches the command. The
# patterns run with the time bound of lib/userre.pm (U-06): one that is stopped does not match.
sub relaunch_allowed {
    my ($cmd, $rl) = @_;
    return 0 unless defined $cmd && !ref $cmd && ref $rl eq 'HASH' && ref $rl->{allow} eq 'ARRAY' && @{ $rl->{allow} };
    my @at = ref $rl->{allow_at} eq 'ARRAY' ? @{ $rl->{allow_at} } : ();
    my @e = map { { re => $rl->{allow}[$_], at => $at[$_] // $_ + 1 } } 0 .. $#{ $rl->{allow} };
    return defined userre::first('relaunch_allow', \@e, [$cmd], 'skip') ? 1 : 0;
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

# pattern_ok(text, max_len) -> compiled regex, or undef (too long, an eval group or verb, a
# wildcard property, or not compiling). The pattern compiles here, in the helper, with no time
# bound, so nothing that runs while it compiles may be the user's: perl 5.30 and later match a
# wildcard property (\p{name=/.../}, \P{gc:/.../}) against every value of the property while
# the pattern compiles, and a 35-character one ran past 20 s (U-06 review). Any \p{ or \P{ whose
# value starts with a punctuation character after = or : is refused.
our $WILDCARD_RE = qr/\\[pP]\s*\{[^}]*?[=:]\s*[^\w\s}]/;
sub wildcard_prop { my ($p) = @_; return (defined $p && !ref $p && $p =~ $WILDCARD_RE) ? 1 : 0 }
sub pattern_ok {
    my ($p, $max) = @_;
    return undef unless defined $p && !ref $p && $p ne '' && length($p) <= ($max // $PROD_LEN);
    return undef if $p =~ /\(\?\??\{|\(\*/ || wildcard_prop($p);
    my $re = eval { local $SIG{__WARN__} = sub { }; qr/$p/ };
    return $re;
}

sub prod {
    my ($r) = @_;
    my $v = $r->{values} || {};
    my (@invalid, @classes);
    my $reads = lc($v->{unattended_prod_reads} // 'forbid');
    $reads = trim($reads);
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
        if ($re) { push @classes, { id => 'user-prod-' . ($i + 1), re => $re, user => 1, at => $i + 1 }; $user++ }
        else { push @invalid, { key => 'prod_patterns', index => $i + 1 } }
    }
    return { reads => $reads, classes => \@classes, user => $user, invalid => \@invalid };
}

# prod_class(text or [texts], prod) -> the id of the first production class a text matches, or
# undef. The shipped classes match here; the user's (`user` set) run with the time bound of
# lib/userre.pm (U-06), where one that is stopped counts as a match: production.
sub prod_class {
    my ($text, $p) = @_;
    my @t = grep { defined && !ref } (ref $text eq 'ARRAY' ? @$text : ($text));
    return undef unless @t;
    my @c = grep { ref $_ eq 'HASH' && defined $_->{re} } @{ (ref $p eq 'HASH' ? $p->{classes} : undef) || [] };
    my $user = sub { $_[0]{user} || ($_[0]{id} // '') =~ /\Auser-/ };
    my $ship;
    for my $i (0 .. $#c) {
        next if $user->($c[$i]);
        my $re = $c[$i]{re};
        if (grep { $_ =~ $re } @t) { $ship = $i; last }
    }
    # the user's classes listed before the first shipped one that matches
    my @u = grep { $user->($c[$_]) && (!defined $ship || $_ < $ship) } 0 .. $#c;
    if (@u) {
        my $k = userre::first('prod_patterns', [map { { re => $c[$_]{re}, at => $c[$_]{at} } } @u], \@t, 'match');
        return $c[ $u[$k] ]{id} // 'prod' if defined $k;
    }
    return defined $ship ? ($c[$ship]{id} // 'prod') : undef;
}

# ---------------------------------------------------------------- protected branches (owner xxxxxxxx-29)
# protected_branches (owner xxxxxxxx-29, 2026-10-23: "add the add-only setting now"; protective,
# %NO_FLAG): a `;` list of branch names or globs ADDED to the shipped protected list (the spec's
# protected_branch_re and the remote's default branch, which every caller still checks first and
# on its own), so no entry can remove a shipped one: there is no exclusion form. A glob has `*`
# (any characters but `/`), `**` (any characters) and `?` (one character but `/`); every other
# character stands for itself; a leading `refs/heads/` is dropped. An entry is matched against
# the lower-cased branch name, as the shipped rule is, so it is case-insensitive. At most 32
# entries, each at most 200 characters. An invalid entry is ignored (a `config_invalid {key,
# index}` row and a /status warning; the rest of the list and the shipped list still apply): one
# that starts with `!` (an exclusion is never honoured), `-` or `/`, ends with `/`, `.` or
# `.lock`, holds `..`, `//`, `@{`, a space or control character, one of ~ ^ : [ ] \ ( ) { } | $
# (an entry is a name or a glob, not a regular expression), or a part that starts with `.`, or
# is `@`. Rows never carry the entry.
# protected([resolved]) -> {globs => [{id => user-branch-<n>, re}], user => n, invalid => [{key, index}]}
our $PROTECTED_MAX = 32;
our $PROTECTED_LEN = 200;
sub protected {
    my ($r) = @_;
    my $v = ref $r eq 'HASH' && ref $r->{values} eq 'HASH' ? $r->{values}{protected_branches} : undef;
    my (@globs, @invalid);
    my @e = list($v);
    for my $i (0 .. $#e) {
        (my $g = lc $e[$i]) =~ s{\Arefs/heads/}{};
        if ($i >= $PROTECTED_MAX || !_branch_glob_ok($g)) { push @invalid, { key => 'protected_branches', index => $i + 1 }; next }
        # U-06: glob_re cannot backtrack; a glob that mixes `*` and `**` keeps the plain
        # translation and is matched with the time bound (protected_user)
        if (glob_linear($g, '**')) { push @globs, { id => 'user-branch-' . ($i + 1), re => glob_re($g, '**'), at => $i + 1, linear => 1 }; next }
        my $rx = join '', map { $_ eq '**' ? '.*' : $_ eq '*' ? '[^/]*' : $_ eq '?' ? '[^/]' : quotemeta($_) }
                          grep { $_ ne '' } split /(\*\*|\*|\?)/, $g;
        push @globs, { id => 'user-branch-' . ($i + 1), re => qr/\A$rx\z/s, at => $i + 1, linear => 0 };
    }
    return { globs => \@globs, user => scalar(@globs), invalid => \@invalid };
}

sub _branch_glob_ok {
    my ($g) = @_;
    return 0 if !defined $g || $g eq '' || $g eq '@' || length($g) > $PROTECTED_LEN;
    return 0 if $g =~ m{\A[!/-]} || $g =~ m{(?:/|\.|\.lock)\z} || $g =~ m{\.\.|//|\@\{};
    return 0 if $g =~ m{[\x00-\x20\x7f~^:\[\]\\(){}|\$]};
    return 0 if grep { /\A\./ } split m{/}, $g;
    return 1;
}

# protected_user(name, protected) -> the id of the first of the user's entries that names the
# branch (lower-cased), else undef. The shipped list is the caller's own check.
sub protected_user {
    my ($name, $p) = @_;
    return undef unless defined $name && !ref $name && $name ne '';
    my $n = lc $name;
    my @g = grep { ref $_ eq 'HASH' && defined $_->{re} } @{ ref $p eq 'HASH' && ref $p->{globs} eq 'ARRAY' ? $p->{globs} : [] };
    my $lin;
    for my $i (0 .. $#g) {
        next if defined $g[$i]{linear} && !$g[$i]{linear};
        if ($n =~ $g[$i]{re}) { $lin = $i; last }
    }
    # an entry kept as the plain translation, listed before that one: with the time bound, where
    # one that is stopped counts as protected (U-06)
    my @b = grep { defined $g[$_]{linear} && !$g[$_]{linear} && (!defined $lin || $_ < $lin) } 0 .. $#g;
    if (@b) {
        my $k = userre::first('protected_branches', [map { { re => $g[$_]{re}, at => $g[$_]{at} } } @b], [$n], 'match');
        return $g[ $b[$k] ]{id} if defined $k;
    }
    return defined $lin ? $g[$lin]{id} : undef;
}

# ---------------------------------------------------------------- export (W-BETA D)
# export_view([resolved]) -> ordered object {key => exported value} for every key whose class is
# not `drop`: num/bool as is; enum the value when it is one of the key's values, else `other`;
# path `unset` (empty), `default`, `custom-in-home` or `custom` (never the path); list the
# entry count (never the entries).
sub export_view {
    my ($r) = @_;
    # No argument: this call's resolved settings (the watcher's `report` calls it so); with no
    # run context (no rc::init, e.g. report.pl) resolve them here, never export empty values.
    $r //= rc::settings() // resolve({});
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
            $c = trim($c);
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
