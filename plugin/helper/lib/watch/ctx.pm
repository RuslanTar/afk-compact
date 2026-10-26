package watch::ctx;
# lib/watch/ctx.pm: the context every watcher entry point works from.
# Owner: WP-watch.
#
# Contract with the caller (WP-core `hook <Event>`, `status`; BUILD-PLAN §3.6).
# ctx is a hashref; every key is optional except `sid`:
#   sid            full session id
#   payload        the decoded hook payload (hashref)
#   settings       resolved settings (MOD-SPEC §1.2 keys, snake_case)
#   watch          the watch dir (<log_dir>, default <root>/.watch)
#   root           the handoff root
#   plugin_root    the plugin folder (default: four levels above this file)
#   pid, pid_lstart  the Claude Code process (identity.claude_pid)
#   cc_version     Claude Code version when known
#   cc_version_src which source gave cc_version (mod, exec, transcript, mirror; MOD-SPEC §2.5)
#   detect         PostCompact: core's result {scan => detect.summary result, verdict,
#                  scope, seat_state, id6, channel, scope_deferred}. ALIAS: the flat
#                  detect.summary result (no `scan`), still read, marked for removal
#                  after one release (PKG-RUNTIME D.1)
#   instructions   PreCompact: detect.instructions result {found, nonce, scope,
#                  has_record}. ALIAS `instr`: the older name, still read, marked for
#                  removal after one release (PKG-RUNTIME D.1; core never passes it)
#   dispatch       PostCompact: the dispatch record matched by core, if any
#   secret_hits    PostCompact: [rule ids] from secrets.scan on the summary
#   keyset_hash    C5 sha8 of this payload's key set, as core computes it
#   mod_alive_this_turn  PostCompact: core's liveness answer (MOD-SPEC §3.3)
#   refused        a roots.check refusal: the watcher then writes nothing
#   append         sub(path, row): core's appender (default: watch::io)
#   row            sub(ev, fields, ctx): core's envelope builder
#   sha256         sub(bytes) -> hex: core's sha256 with its fallbacks
#   spec           the decoded spec-literals block (default: assets file)
#   now            epoch seconds (default: watch::io::now)
# Missing keys are derived here so the watcher also runs before core lands.
# Text may come as character strings (core's JSON codec); the entry points in
# lib/watch.pm turn every plain ctx value into UTF-8 bytes first.
use strict;
use warnings;
use utf8;
use Cwd ();
use File::Basename ();
use watch::io;
use watch::json;

my %DEFAULTS = (
    handoff_root                => '~/.claude/handoffs',
    log_dir                     => '',
    watcher                     => 'shadow',
    stall_min                   => 60,
    cache_ttl_s                 => 300,
    compact_target_tokens       => 400000,
    compact_soft_max_tokens     => 600000,
    native_window_tokens        => 0,
    max_auto_continues_per_hour => 6,
    evidence_quota_mb           => 500,
    triggers                    => 'true',
    deny_class_patterns         => '',
    handoff_turn                => 'halt',
    handoff_turn_max_tokens     => 64000,
    # SK-6 (owner xxxxxxxx-14, S-SETTINGS E6): the watch folder size that raises A-24 (0 = off)
    watch_quota_mb              => 50,
    # owner xxxxxxxx-29: the user's add-only protected branches (a protective key: _settings
    # takes it from the resolved settings only, never from env)
    protected_branches          => '',
);

my $THIS_DIR = File::Basename::dirname(Cwd::abs_path(__FILE__));

sub plugin_root_default {
    my $p = Cwd::abs_path("$THIS_DIR/../../..");
    return defined $p ? $p : "$THIS_DIR/../../..";
}

sub _expand {
    my ($v) = @_;
    return undef unless defined $v;
    return undef if $v eq '' || index($v, '${user_config.') == 0;
    if ($v eq '~' || $v =~ m{\A~/}) {
        my $home = defined $ENV{HOME} ? $ENV{HOME} : '';
        $v = $home . substr($v, 1);
    }
    return $v;
}

sub _settings {
    my ($ctx) = @_;
    my %s;
    my $given = ref $ctx->{settings} eq 'HASH' ? $ctx->{settings} : undef;
    unless ($given) {
        my $r;
        $r = eval { local $SIG{__DIE__}; settings::resolve({}) } if defined &settings::resolve;
        $given = $r if ref $r eq 'HASH';
    }
    # Core passes settings::resolve's shape {values => {...}, source, notes} (rc::settings),
    # and the fallback above returns it too; the keys live under `values` (CR-F15). A flat
    # hash (key => value) is read as it is.
    $given = $given->{values} if $given && ref $given->{values} eq 'HASH';
    for my $k (keys %DEFAULTS) {
        my $v;
        $v = $given->{$k} if $given && exists $given->{$k};
        if ($k eq 'protected_branches') {
            # Protective (settings.pm %NO_FLAG): the resolved value or nothing; an env value
            # would make the watcher's protected-push reading differ from the approvals'.
            $s{$k} = (defined $v && !ref $v) ? $v : $DEFAULTS{$k};
            next;
        }
        $v = _expand($v) if defined $v && !ref $v;
        unless (defined $v) {
            $v = _expand($ENV{'CLAUDE_PLUGIN_OPTION_' . uc $k});
        }
        $v = $DEFAULTS{$k} unless defined $v;
        $s{$k} = $v;
    }
    $s{handoff_root} = _expand($s{handoff_root}) || _expand($DEFAULTS{handoff_root});
    for my $k (qw(stall_min cache_ttl_s compact_target_tokens compact_soft_max_tokens
                  native_window_tokens max_auto_continues_per_hour evidence_quota_mb
                  handoff_turn_max_tokens watch_quota_mb)) {
        $s{$k} = $DEFAULTS{$k} unless defined $s{$k} && $s{$k} =~ /\A[0-9]+(?:\.[0-9]+)?\z/;
        $s{$k} = 0 + $s{$k};
    }
    # `triggers` is a bool: resolve gives 1/0, env and flat callers may give text. The rules
    # read `true`/`false`; the coercion is settings::_coerce's (1|true|yes|on is on).
    my $t = $s{triggers};
    $t = UNIVERSAL::isa($t, 'SCALAR') ? ($$t ? 1 : 0) : undef if ref $t;
    $s{triggers} = (defined $t && !ref $t && $t =~ /\A\s*(?:1|true|yes|on)\s*\z/i) ? 'true' : 'false';
    # `handoff_turn` as the mod parses it (config.ts handoffTurn): trimmed and case-folded;
    # anything but `halt` or `off` is the default. It sets the clamp's reserve (rules::thresholds).
    my $ht = _trim(lc(ref $s{handoff_turn} ? '' : $s{handoff_turn}));
    $s{handoff_turn} = ($ht eq 'halt' || $ht eq 'off') ? $ht : $DEFAULTS{handoff_turn};
    ($s{watcher}, $s{watcher_unknown}) = _watcher_value($given);
    return \%s;
}

# `watcher` (WATCHER-SPEC §8 item 6; REVIEW B-22): trimmed and case-folded; `shadow` and
# `off` are the only values, anything else (`of`, `Shadow2`, an empty string) counts as
# `shadow` and is flagged, so a typo can never switch the watcher on or off unseen.
# Returns (value, unknown). Unset, or an unresolved `${user_config.` placeholder, is the
# default and not unknown.
sub _watcher_value {
    my ($given) = @_;
    my $raw;
    $raw = $given->{watcher} if $given && exists $given->{watcher} && defined $given->{watcher} && !ref $given->{watcher};
    $raw = $ENV{CLAUDE_PLUGIN_OPTION_WATCHER} unless defined $raw;
    return ('shadow', 0) if !defined $raw || index($raw, '${user_config.') == 0;
    my $v = _trim(lc $raw);
    return ($v, 0) if $v eq 'shadow' || $v eq 'off';
    return ('shadow', 1);
}

# _trim(text) -> text without leading and trailing white space, in linear time (U-06 review:
# s/\A\s+|\s+\z//g is quadratic in a long inner run of spaces; settings::trim does the same)
sub _trim {
    my ($s) = @_;
    return $s unless defined $s;
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

# One `config_note` row per session when the `watcher` value was not `shadow`/`off`
# (marker file, exclusive create). Content-free: the value itself is never logged.
sub note_watcher_value {
    my ($ctx) = @_;
    return 0 unless $ctx->{settings}{watcher_unknown};
    return 0 unless watch::io::excl_create(sid_dir($ctx) . '/config-note-watcher', '');
    return log_row($ctx, 'config_note', { key => 'watcher', note => 'watcher_value_unknown' });
}

# Fill the derived keys in place and return ctx.
sub init {
    my ($ctx) = @_;
    $ctx ||= {};
    return $ctx if $ctx->{_init};
    $ctx->{_init} = 1;
    $ctx->{settings} = _settings($ctx);
    $ctx->{root} = _expand($ctx->{root}) || $ctx->{settings}{handoff_root};
    my $watch = _expand($ctx->{watch}) || _expand($ctx->{settings}{log_dir});
    $ctx->{watch} = defined $watch ? $watch : $ctx->{root} . '/.watch';
    $ctx->{watch} =~ s{/+\z}{};
    $ctx->{plugin_root} ||= plugin_root_default();
    $ctx->{now} = watch::io::now() unless defined $ctx->{now};
    my $manifest = watch::io::read_json_file($ctx->{plugin_root} . '/.claude-plugin/plugin.json') || {};
    $ctx->{brand} ||= $manifest->{name};
    $ctx->{plugin_version} ||= $manifest->{version};
    _identity($ctx);
    $ctx->{spec} = load_spec($ctx) unless ref $ctx->{spec} eq 'HASH';
    return $ctx;
}

sub _identity {
    my ($ctx) = @_;
    return if defined $ctx->{pid};
    my $id;
    $id = eval { local $SIG{__DIE__}; identity::claude_pid() } if defined &identity::claude_pid;
    if (ref $id eq 'HASH' && defined $id->{pid}) {
        $ctx->{pid} = $id->{pid};
        $ctx->{pid_lstart} = $id->{lstart} unless defined $ctx->{pid_lstart};
        return;
    }
    if (($ENV{STORE_TEST_MODE} || '') eq '1' && ($ENV{STORE_TEST_CLAUDE_PID} || '') =~ /\A([0-9]+):(.*)\z/) {
        $ctx->{pid} = 0 + $1;
        $ctx->{pid_lstart} = $2 unless defined $ctx->{pid_lstart};
    }
}

sub load_spec {
    my ($ctx) = @_;
    my $path = $ctx->{spec_path} || ($ctx->{plugin_root} . '/assets/handoff-spec.json');
    my $spec = watch::io::read_json_file($path);
    return ref $spec eq 'HASH' ? $spec : {};
}

sub watcher_on {
    my ($ctx) = @_;
    return (($ctx->{settings}{watcher} || 'shadow') ne 'off') ? 1 : 0;
}

# The watcher writes nothing when its root is unsafe (WATCH §6.1).
sub refused {
    my ($ctx) = @_;
    return $ctx->{refused} if exists $ctx->{refused};
    my $r;
    if (defined &roots::check) {
        $r = eval { local $SIG{__DIE__}; roots::check($ctx->{settings}) };
    }
    $ctx->{refused} = (defined $r && !ref $r && $r ne 'ok' && $r ne '1') ? $r
                    : (ref $r eq 'HASH' && $r->{refused}) ? $r->{refused} : 0;
    return $ctx->{refused};
}

sub sid8 { return substr($_[0]{sid} || 'unknown', 0, 8) }

sub classic_log { return $_[0]{watch} . '/' . $_[0]{sid} . '.classic.jsonl' }
sub mod_log     { return $_[0]{watch} . '/' . $_[0]{sid} . '.jsonl' }
sub alerts_log  { return $_[0]{watch} . '/' . $_[0]{sid} . '.alerts.jsonl' }
sub sid_dir     { return $_[0]{watch} . '/' . $_[0]{sid} }

# WATCH §6.2 envelope; every key present, unknown = null.
sub row {
    my ($ctx, $ev, $fields, %o) = @_;
    if (ref $ctx->{row} eq 'CODE') {
        my $r = eval { $ctx->{row}->($ev, $fields, $ctx) };
        if (ref $r eq 'HASH') {
            # Core's builder takes (ev, fields, ctx) only: keep the actor and
            # writer this row was written for.
            $r->{actor} = $o{actor} if defined $o{actor};
            $r->{writer} = $o{writer} if defined $o{writer};
            return $r;
        }
    }
    my %r = (
        v              => 1,
        ts             => watch::io::iso($ctx->{now}),
        ev             => $ev,
        sid            => $ctx->{sid},
        actor          => defined $o{actor} ? $o{actor} : 'unknown',
        writer         => $o{writer} || 'classic',
        pid            => $ctx->{pid},
        plugin_version => $ctx->{plugin_version},
        cc_version     => $ctx->{cc_version},
        turn_seq       => undef,
    );
    for my $k (keys %{ $fields || {} }) { $r{$k} = $fields->{$k} }
    return \%r;
}

# Append a row to a file under <watch>. Never dies; returns 1 or 0.
sub write_row {
    my ($ctx, $path, $row) = @_;
    my $ok = eval {
        if (ref $ctx->{append} eq 'CODE') { $ctx->{append}->($path, $row) }
        else { watch::io::append_row($path, $row) }
        1;
    };
    return $ok ? 1 : 0;
}

sub log_row {
    my ($ctx, $ev, $fields, %o) = @_;
    my $path = $o{file} || classic_log($ctx);
    my $r = row($ctx, $ev, $fields, %o);
    return 1 if write_row($ctx, $path, $r);
    # A row that could not be written (too large, unwritable) leaves a trace.
    my $class = length(watch::json::encode($r)) + 1 > $watch::io::MAX_ROW ? 'row-too-large' : 'write-failed';
    write_row($ctx, classic_log($ctx), row($ctx, 'watch_error', { stage => $ev, error_class => $class })) if $ev ne 'watch_error';
    return 0;
}

# One content-free error row: stage and class only.
sub error_row {
    my ($ctx, $stage, $err) = @_;
    my $class = defined $err ? "$err" : 'unknown';
    $class =~ s/\s+\z//;
    $class = 'internal' unless $class =~ /\A[a-z][a-z0-9-]{0,39}\z/;
    return eval { log_row($ctx, 'watch_error', { stage => $stage, error_class => $class }) } || 0;
}

sub B { return $_[0] ? \1 : \0 }

1;
