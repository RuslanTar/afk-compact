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

# The keys of MOD-SPEC §1.2 (44 with idle_digest, restart_on_update and idle_handoff_near_limit): type; fallback (used only when the manifest lacks the key:
# defaults and min/max come from plugin.json userConfig, one source; the config-defaults gate
# holds the fallback equal to the manifest default); export class (W-BETA D, AT-WB-08: num,
# bool, enum, path, list or drop; export_view()).
our @KEYS = (
    [handoff_root                => 'dir',  '~/.local/state/<plugin>/handoffs', 'path'],    # STATE-ROOT (0.1.2); lib/paths.pm
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
    # owner 2026-10-30 (xxxxxxxx, "I want the handoff anyway"): `run` = the pre-idle handoff turn
    # also runs with a rate-limit window at 90% or more; `skip` = it skips there (near-limit)
    [idle_handoff_near_limit     => 'str',  'run',                     'enum'],
    # IDLE-COMPACT-SPEC (D9): `auto` = the plugin compacts an idle session itself while Claude
    # Code's own idle compaction is off (`"idleCompaction": false`); `off` = never
    [idle_compact                => 'str',  'auto',                    'enum'],
    # away digest phase 1 (owner 2026-10-27 12:5x, xxxxxxxx-09): the digest turn right after an
    # idle compaction of a finished or blocked lane (`submit`), or none until the next turn
    # (`return`); `off` (owner rule (c), 2026-10-28: on only after a live PASS) asks for no digest
    [idle_digest                 => 'str',  'off',                     'enum'],
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
    # the shipped list (lib/gsd.pm %DRIVERS) and the skills whose own text runs gsd-tools, that a
    # session re-enters when it invoked them
    [driver_skills               => 'str',  '',                        'list'],
    # SESSION-RESTART D1 (owner 19:08, 2026-10-27): `on` = move a session onto a newly installed
    # Claude Code at a compaction boundary; `shadow` = log the verdict only; `off` = never. A
    # consent key (settings file only); any other value reads as off with a note.
    [restart_on_update           => 'str',  'off',                     'enum'],
);
# 0.1.2 onboarding (the settings flow, `settings show`): the section and tier of every key, here
# because plugin.json cannot hold keys Claude Code does not know. `common` keys are asked by
# the flow section by section; `advanced` ones (rare tuning: ms timings, quotas, patterns) only
# by its advanced tier. The settings-sections gate holds this table equal to the manifest's
# userConfig keys, so a new key cannot miss the flow.
our @SECTIONS = (
    [compaction => 'Compaction'],
    [idle       => 'Idle sessions'],
    [handoffs   => 'Handoffs'],
    [logs       => 'Warnings and logs'],
    [jobs       => 'Background jobs'],
    [safety     => 'Safety'],
);
our %SECTION = (
    triggers                    => [qw(compaction common)],
    compact_target_tokens       => [qw(compaction common)],
    native_window_tokens        => [qw(compaction common)],
    max_auto_continues_per_hour => [qw(compaction common)],
    handoff_turn                => [qw(compaction common)],
    precompact_turn             => [qw(compaction common)],
    compact_soft_max_tokens     => [qw(compaction advanced)],
    boundary_delay_ms           => [qw(compaction advanced)],
    cooldown_ms                 => [qw(compaction advanced)],
    cache_ttl_s                 => [qw(compaction advanced)],
    handoff_turn_max_tokens     => [qw(compaction advanced)],
    driver_skills               => [qw(compaction advanced)],
    idle_compact                => [qw(idle common)],
    idle_handoff_turn           => [qw(idle common)],
    idle_digest                 => [qw(idle common)],
    idle_handoff_min_tokens     => [qw(idle common)],
    idle_handoff_near_limit     => [qw(idle advanced)],
    handoff_root                => [qw(handoffs common)],
    log_dir                     => [qw(handoffs common)],
    disposable_root             => [qw(handoffs common)],
    resume_proceed              => [qw(handoffs common)],
    handoff_reuse_window_min    => [qw(handoffs common)],
    disposable_keep_days        => [qw(handoffs advanced)],
    evidence_quota_mb           => [qw(handoffs advanced)],
    evidence_total_max_mb       => [qw(handoffs advanced)],
    ticket_pattern              => [qw(handoffs advanced)],
    warn_ui                     => [qw(logs common)],
    watcher                     => [qw(logs common)],
    stall_min                   => [qw(logs common)],
    measured_block              => [qw(logs common)],
    auto_evidence               => [qw(logs common)],
    watch_quota_mb              => [qw(logs advanced)],
    otel_log_path               => [qw(logs advanced)],
    relaunch_quiet_s            => [qw(jobs common)],
    relaunch_auto               => [qw(jobs common)],
    relaunch_allow              => [qw(jobs common)],
    queue_cmd                   => [qw(jobs common)],
    repo_roots                  => [qw(safety common)],
    unattended_prod_reads       => [qw(safety common)],
    restart_on_update           => [qw(safety common)],
    prod_patterns               => [qw(safety common)],
    secret_extra_rules          => [qw(safety common)],
    protected_branches          => [qw(safety common)],
    deny_class_patterns         => [qw(safety advanced)],
);
our %TYPE = map { $_->[0] => $_->[1] } @KEYS;
our %EXPORT = map { $_->[0] => $_->[3] } @KEYS;
# The values an enum key exports as is (W-BETA D); any other value exports as `other`.
our %ENUM = (watcher => [qw(shadow off)], handoff_turn => [qw(halt off)], relaunch_auto => [qw(on shadow off)],
             unattended_prod_reads => [qw(forbid allow)], precompact_turn => [qw(model code)], idle_handoff_turn => [qw(auto off)], idle_compact => [qw(auto off)],
             idle_handoff_near_limit => [qw(run skip)],
             idle_digest => [qw(submit return off)],
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
# real path or device and inode); config_dir_foreign() adds the same-file rule on top of it.
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
    # no account home (a uid with no user database entry): no consent folder, so safe values
    return 1 unless defined $home;
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

# inline_key() -> `<name>@inline` when CLAUDE_PLUGIN_ROOT is set and not under the config dir's
# plugins/ (a --plugin-dir run, E-14), else undef.
sub inline_key {
    my $pr = $ENV{CLAUDE_PLUGIN_ROOT};
    return undef unless defined $pr && $pr ne '';
    my $plugins = util::clean_path(config_dir() . '/plugins');
    my $p = util::clean_path($pr);
    return index("$p/", "$plugins/") != 0 ? ctx::brand() . '@inline' : undef;
}

# Returns (options hashref or undef, note) from the user's settings file.
sub _settings_file_options {
    my $o = options_source();
    return ($o->{ambiguous} ? (undef, 'ambiguous') : ($o->{options}, $o->{key}));
}

# options_key(pluginConfigs hash) -> (key or undef, [candidates]): the plugin's key in
# pluginConfigs (E-14): `<name>@inline` when CLAUDE_PLUGIN_ROOT is set and not under the config
# dir's plugins/; otherwise the single key whose part before `@` is the brand. Several such keys:
# (undef, [them]), ambiguous.
sub options_key {
    my ($pc) = @_;
    my $brand = ctx::brand();
    if (defined(my $k = inline_key())) {
        return ($k, [$k]);
    }
    my @cand = grep { (split /\@/, $_, 2)[0] eq $brand } sort keys %{ ref $pc eq 'HASH' ? $pc : {} };
    return (undef, \@cand) if @cand != 1;
    return ($cand[0], \@cand);
}

# options_source() -> {file, exists, json (0|1: decodes as plain JSON), key, candidates,
#   ambiguous, options (hash or undef)}: where the plugin's saved options are, read-only.
sub options_source {
    my $file = config_dir() . '/settings.json';
    my %o = (file => $file, exists => (-e util::fsb($file) ? 1 : 0), json => 0, key => undef, candidates => [], ambiguous => 0);
    my $raw = util::read_file($file);
    return \%o unless defined $raw;
    my $s = eval { jsonc::decode($raw) };
    return \%o unless ref $s eq 'HASH';
    $o{json} = 1;
    return \%o unless ref $s->{pluginConfigs} eq 'HASH';
    my $pc = $s->{pluginConfigs};
    my ($k, $cand) = options_key($pc);
    $o{candidates} = $cand;
    if (!defined $k) { $o{ambiguous} = @$cand > 1 ? 1 : 0; return \%o }
    $o{key} = $k;
    my $opts = ref $pc->{$k} eq 'HASH' ? $pc->{$k}{options} : undef;
    $o{options} = $opts if ref $opts eq 'HASH';
    return \%o;
}

# config_key_info() -> {state, key}: the user's settings file as a settings writer would see it
# (0.1.2 onboarding). state: absent (no file, no pluginConfigs or no key for the plugin),
# unreadable (the path exists, as a dangling link too, but cannot be read as a file: no
# permission, a folder; a writer refuses it, never takes it for absent), unparseable (the file
# is not a JSON object, its pluginConfigs is not one, or the plugin's entry or that entry's
# options is there but not an object: a writer cannot merge into it and refuses it), ambiguous
# (two or more keys for the plugin), found (one key, its options an object or missing).
# key: that key, also when its entry is unparseable; under --plugin-dir the @inline key, also
# while the file lacks it; else undef.
sub config_key_info {
    my $inline = inline_key();
    my $file = config_dir() . '/settings.json';
    my $raw = util::read_file($file);
    if (!defined $raw) {
        return { state => 'unreadable', key => undef } if -e $file || -l $file;
        return { state => 'absent', key => $inline };
    }
    my $s = eval { jsonc::decode($raw) };
    return { state => 'unparseable', key => undef }
        unless ref $s eq 'HASH' && (!defined $s->{pluginConfigs} || ref $s->{pluginConfigs} eq 'HASH');
    my $pc = $s->{pluginConfigs} || {};
    my $entry = sub {
        my ($k) = @_;
        my $e = $pc->{$k};
        return 'unparseable' unless ref $e eq 'HASH' && (!exists $e->{options} || ref $e->{options} eq 'HASH');
        return 'found';
    };
    return { state => (exists $pc->{$inline} ? $entry->($inline) : 'absent'), key => $inline } if defined $inline;
    my $brand = ctx::brand();
    my @cand = grep { (split /\@/, $_, 2)[0] eq $brand } sort keys %$pc;
    return { state => 'absent', key => undef } unless @cand;
    return { state => 'ambiguous', key => undef } if @cand > 1;
    return { state => $entry->($cand[0]), key => $cand[0] };
}

# resolve(\%flags) -> {values => {key => v}, source => {key => flag|env|settings|default},
#   notes => [..], ambiguous => 0|1, config_key => key-or-undef,
#   defaults => {key => the default used: the manifest's, else the @KEYS fallback, as written}}
sub resolve {
    my ($flags) = @_;
    $flags ||= {};
    my %val;
    my %src;
    my %def;
    my @notes;
    my ($opts, $ckey) = _settings_file_options();
    my $ambiguous = (defined $ckey && $ckey eq 'ambiguous') ? 1 : 0;
    my $uc = ctx::user_config();
    my $foreign = config_dir_foreign();
    for my $k (@KEYS) {
        my ($key, $type, $fallback) = @$k[0 .. 2];
        my $default = ref $uc->{$key} eq 'HASH' && exists $uc->{$key}{default} ? $uc->{$key}{default} : (defined &paths::named ? paths::named($fallback) : $fallback);
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
        # ON-5 (0.1.2): only the settings file holds JSON values. An array of strings or numbers
        # for a `;` list key reads as its entries joined with `;` (a protective list written as an
        # array still adds its entries); any other array or object is invalid: the default.
        if (ref $v eq 'ARRAY' && ($EXPORT{$key} // '') eq 'list' && !grep { !defined || ref } @$v) {
            push @notes, "$key: a JSON list, read as its entries joined with ;";
            $v = join ';', @$v;
        }
        elsif (ref $v eq 'ARRAY' || ref $v eq 'HASH') {
            push @notes, "$key: not a single value, default used";
            ($v, $s) = ($default, 'default');
        }
        my $c = _coerce($key, $v);
        if (!defined $c) {
            push @notes, "$key: not a number, default used";
            ($c, $s) = (_coerce($key, $default), 'default');
        }
        $val{$key} = $c;
        $src{$key} = $s;
        $def{$key} = $default;
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
    # idle_handoff_near_limit (owner 2026-10-30, as config.ts reads it): trimmed and case-folded;
    # run or skip, else the default run with a note. A blank value is unset: the default.
    {
        my $x = trim(lc($val{idle_handoff_near_limit} // 'run'));
        if ($x eq '') { $x = 'run'; $src{idle_handoff_near_limit} = 'default' }
        if ($x !~ /\A(?:run|skip)\z/) { push @notes, 'idle_handoff_near_limit: not run or skip, run used'; $x = 'run' }
        $val{idle_handoff_near_limit} = $x;
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
             config_key => ($ambiguous ? undef : $ckey), defaults => \%def };
}

# ---------------------------------------------------------------- SK-7 helpers (2026-10-23)
# The whole-number keys: the number keys the mod's config.ts rounds down (Math.floor) before its
# clamp (bounded(), handoffTokens() and max_auto_continues_per_hour in parseOptions), as the
# watcher's rules.pm does for handoff_turn_max_tokens. whole(key, number) -> the number as the
# plugin reads it: those keys rounded down (0.5 is 0, -0.5 is -1), every other key as is (the
# helper reads handoff_reuse_window_min and the MB keys with their fraction).
our %WHOLE = map { $_ => 1 } qw(max_auto_continues_per_hour handoff_turn_max_tokens idle_handoff_min_tokens);
sub whole {
    my ($key, $v) = @_;
    return $v unless $WHOLE{$key} && defined $v && !ref $v;
    my $i = int($v);
    return 0 + ($i > $v ? $i - 1 : $i);
}

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
    $v = whole($key, $v);
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

# ---------------------------------------------------------------- visible defaults (0.1.2)
# The ten keys `settings reset --all` leaves (OPEN-2 of the visible-defaults spec, its
# recommendation): the six consent keys, the three protective lists and resume_proceed. Named
# on its own one is reset, with what its default does (%RESET_EFFECT).
our %RESET_KEEP = map { $_ => 1 } (keys %FILE_ONLY, keys %NO_FLAG, 'resume_proceed');
our %RESET_EFFECT = (
    repo_roots => 'its default accepts no repository for exports', relaunch_auto => 'its default on lets a lost background job start again by itself (looser than now)',
    relaunch_allow => 'its default allows no command to start again by itself', unattended_prod_reads => 'its default forbid asks before production reads',
    queue_cmd => 'its default runs no queue program', restart_on_update => 'its default off restarts nothing on an update',
    prod_patterns => 'its default leaves only the built-in production rule (looser than now)',
    secret_extra_rules => 'its default leaves only the built-in secret rules (looser than now)',
    protected_branches => 'its default leaves only the built-in protected branches (looser than now)',
    resume_proceed => 'its default auto lets a resume you start go on after its report (looser than now)',
);
# Source labels (spec Behaviour 1).
our %SOURCE_LABEL = (settings => 'your settings.json', default => 'default', env => 'plugin option', flag => 'flag', safe => 'safe value');

sub manifest_default {
    my ($key) = @_;
    my $uc = ctx::user_config();
    return $uc->{$key}{default} if ref $uc->{$key} eq 'HASH' && exists $uc->{$key}{default};
    my ($row) = grep { $_->[0] eq $key } @KEYS;
    return $row ? $row->[2] : undef;
}

# show_value(key, value) -> the value as /status and `settings show` print it: true/false; a
# number (a whole-number key rounded down, whole()); a path (~ for the home) or `empty`; a list key's entry count (never its entries);
# ticket_pattern built-in, custom or invalid (never the pattern); any other text trimmed and cut
# to 40 characters.
sub show_value {
    my ($key, $v) = @_;
    my $t = $TYPE{$key} // 'str';
    my $class = $EXPORT{$key} // '';
    if ($t eq 'bool') { return (ref $v ? ($$v ? 1 : 0) : _coerce($key, $v // 0)) ? 'true' : 'false' }
    if ($key eq 'ticket_pattern') {
        return 'built-in' if _unset($v) || ref $v || $v eq $TICKET_DEFAULT;
        return pattern_ok($v, 200) ? 'custom' : 'invalid';
    }
    if ($class eq 'list') {
        my $n = scalar(my @e = list(ref $v ? undef : $v));
        return $n == 0 ? 'empty' : $n == 1 ? '1 entry' : "$n entries";
    }
    return 'empty' if _unset($v) || ref $v;
    if ($t eq 'dir' || $t eq 'file') {
        my $p = util::text(util::abbrev(util::expand_tilde(util::to_bytes("$v"))));
        $p =~ s/[\x00-\x1f\x7f]/ /g;
        return $p;
    }
    if ($t eq 'num') { return "$v" =~ /\A-?[0-9]+(\.[0-9]+)?\z/ ? whole($key, 0 + $v) : 'not a number' }
    my $s = trim(util::text("$v"));
    $s =~ s/[\x00-\x1f\x7f]/ /g;
    return length($s) > 40 ? substr($s, 0, 39) . '…' : $s;
}

# effective_rows([resolved]) -> [{key, value, source, label, default, at_default, clamped_from,
#   saved (present in the saved options), saved_empty}] in @KEYS order (spec Behaviour 1, 3):
# the value each key has for the plugin, where it comes from and the manifest default, all as
# show_value prints them. A number key with min/max says what it was clamped from.
sub effective_rows {
    my ($r) = @_;
    $r //= _current();
    my $v = $r->{values} || {};
    my $src = $r->{source} || {};
    my $o = options_source();
    my $saved = !$o->{ambiguous} && ref $o->{options} eq 'HASH' ? $o->{options} : {};
    my @rows;
    for my $k (@KEYS) {
        my $key = $k->[0];
        my $s = $src->{$key} // 'default';
        my $val = $v->{$key};
        my ($shown, $from);
        if ($TYPE{$key} eq 'num' && defined $val) {
            my ($used, $cl) = num_clamped($key, $r);
            ($shown, $from) = (defined $used ? $used : show_value($key, $val), $cl ? whole($key, 0 + $val) : undef);
        } else {
            $shown = show_value($key, $val);
        }
        my $def = show_value($key, manifest_default($key));
        push @rows, { key => $key, value => $shown, source => $s, label => $SOURCE_LABEL{$s} // $s, default => $def,
                      # by the value alone (spec Behaviour 1): a value saved equal to its default
                      # (the configure dialog saves every on/off key) is at its default
                      at_default => ($shown eq $def && !defined $from) ? 1 : 0, clamped_from => $from,
                      saved => exists $saved->{$key} ? 1 : 0,
                      saved_empty => (exists $saved->{$key} && defined $saved->{$key} && !ref $saved->{$key} && $saved->{$key} eq '') ? 1 : 0 };
    }
    return \@rows;
}

# row_text(row) -> `<value>[, clamped from N] (<source>; default <default>)`, or `(default)` for
# a default the plugin fills in. A value set equal to its default still names where it is set
# (`triggers true (your settings.json; default true)`, spec Behaviour 3), as `settings reset`
# lists it; only the status block's grouping and count go by the value alone (at_default).
sub row_text {
    my ($w) = @_;
    my $v = $w->{value} . (defined $w->{clamped_from} ? ", clamped from $w->{clamped_from}" : '');
    return $w->{at_default} && $w->{source} eq 'default' ? "$v (default)" : "$v ($w->{label}; default $w->{default})";
}

# value_warnings(rows, store word) -> the warning lines of Behaviour 2 (a saved "" per key) and
# of an ambiguous options key.
sub value_warnings {
    my ($rows, $store) = @_;
    my @l;
    my $o = options_source();
    if ($o->{ambiguous}) {
        push @l, 'warning: several plugin option keys in your settings.json (' . join(', ', map { '"' . util::text($_) . '"' } @{ $o->{candidates} })
                 . '): every key is at its default; remove the one no longer used';
    }
    for my $w (grep { $_->{saved_empty} } @$rows) {
        push @l, "warning: $w->{key}: saved empty, the plugin uses the default; Claude Code passes \"\" to the hooks; clear it with "
                 . (defined $store ? '! ' . util::text($store) . " settings reset $w->{key} --apply" : "a settings reset of $w->{key}");
    }
    return @l;
}

# ---------------------------------------------------------------- view (0.1.2 onboarding)
# view(\%flags[, tier]) -> ordered object: one row per key (key, title, section, tier, kind,
# default, min, max, values, value, source, clamped, class) in @SECTIONS order (@KEYS order inside a
# section), with the pluginConfigs key in use (config_key_info) and why a write there would be
# refused. Min and max are the manifest's; default, value and source are resolve()'s (one place
# works the default out). tier: common, advanced or all (default). A key with no %SECTION row
# goes to section `other`, tier advanced, and is listed in `unsectioned` (the settings-sections
# gate fails on it). `clamped`: true for a key the clamp moves (a number outside its min/max, a
# window below the floor, a soft max or target over the window's clamp), the watcher's export
# flags (watch::export::clamped_keys); `value` stays the configured one (a whole-number key
# rounded down as the plugin reads it, whole()); null when they cannot be
# worked out. Read-only.
our %KIND = (num => 'number', bool => 'boolean', enum => 'enum', path => 'path', list => 'list', drop => 'text');
sub view {
    my ($flags, $tier) = @_;
    $tier //= 'all';
    my $r = resolve($flags || {});
    my $uc = ctx::user_config();
    my (%rows, %by, @unsectioned);
    my $cl = eval { require watch::export; watch::export::clamped_keys($r, scalar eval { spec::load() }) };
    for my $k (@KEYS) {
        my ($key, $type, undef, $class) = @$k;
        my ($sec, $t) = @{ $SECTION{$key} || [] };
        if (!defined $sec) { push @unsectioned, $key; ($sec, $t) = ('other', 'advanced') }
        next unless $tier eq 'all' || $tier eq $t;
        my $u = ref $uc->{$key} eq 'HASH' ? $uc->{$key} : {};
        my $default = $r->{defaults}{$key};
        my $v = $r->{values}{$key};
        my ($lo, $hi) = limits($key);
        if ($type eq 'bool') { ($default, $v) = (jsonc::bool(_coerce($key, $default)), jsonc::bool($v)) }
        elsif ($type eq 'num') { $default = 0 + $default if defined $default && "$default" =~ /\A-?[0-9]+(\.[0-9]+)?\z/; $v = whole($key, 0 + $v) if defined $v }
        $rows{$key} = jsonc::obj(
            key => $key, title => $u->{title}, section => $sec, tier => $t, kind => $KIND{$class // ''} // 'text',
            default => $default, min => $lo, max => $hi,
            values => ($ENUM{$key} ? [ @{ $ENUM{$key} } ] : undef),
            value => $v, source => $r->{source}{$key},
            clamped => (ref $cl eq 'HASH' ? jsonc::bool($cl->{$key}) : undef),
            class => ($FILE_ONLY{$key} ? 'consent' : $NO_FLAG{$key} ? 'protective' : undef));
        push @{ $by{$sec} }, $key;
    }
    my @sections;
    for my $s (@SECTIONS, ['other' => 'Other']) {
        push @sections, jsonc::obj(id => $s->[0], title => $s->[1], keys => $by{ $s->[0] }) if $by{ $s->[0] };
    }
    my $ci = config_key_info();
    my $state = $ci->{state};
    my $inline = inline_key();
    my $foreign = config_dir_foreign();
    # Why a write would be refused, the first that holds: another settings folder
    # (config-dir-foreign under CLAUDE_CONFIG_DIR, home-foreign when HOME is not the account
    # home), a file that cannot be read or that a writer cannot merge into, a --plugin-dir run,
    # two keys for the plugin.
    my $refused = $foreign ? (($ENV{CLAUDE_CONFIG_DIR} // '') ne '' ? 'config-dir-foreign' : 'home-foreign')
        : ($state eq 'unreadable' || $state eq 'unparseable') ? $state : defined $inline ? 'inline'
        : $state eq 'ambiguous' ? 'ambiguous' : undef;
    return jsonc::obj(
        config_file => config_dir() . '/settings.json', config_key => $ci->{key}, config_key_state => $state,
        inline => jsonc::bool(defined $inline), config_dir_foreign => jsonc::bool($foreign), write_refused => $refused,
        sections => \@sections, settings => jsonc::obj(map { my $s = $_; map { $_ => $rows{$_} } @{ $by{ $s->[0] } || [] } } @SECTIONS, ['other']),
        unsectioned => \@unsectioned, notes => $r->{notes});
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
