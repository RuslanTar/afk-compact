package rc;
# lib/rc.pm: the run context of one helper call: session id, settings, paths, root
# checks, the row envelope and once-per-session markers. Owner: WP-core.
use strict;
use warnings;
use utf8;

our %R;

# init(sid => S, writer => classic|helper, actor => ..., flags => \%settings_flags)
sub init {
    my (%a) = @_;
    %R = ();
    $R{sid} = $a{sid};
    $R{writer} = $a{writer} // 'helper';
    $R{actor} = $a{actor} // 'unknown';
    $R{settings} = settings::resolve($a{flags} || {});
    $R{paths} = paths::for($R{settings}, $R{sid});
    $R{roots} = roots::check($R{settings});
    # Effective watch dir: log_dir, else the default <root>/.watch when log_dir is unsafe.
    my $w = $R{paths}{watch};
    if (!$R{roots}{log_dir}{ok}) {
        my $def = $R{paths}{watch_default};
        my $dr = roots::check_path($def);
        $w = ($dr->{ok} && $def ne $R{paths}{watch}) ? $def : undef;
    }
    $R{watch} = $w;
    return \%R;
}

sub sid      { $R{sid} }
sub set_sid  { $R{sid} = $_[0] }
sub settings { $R{settings} }
sub val      { $R{settings}{values}{ $_[0] } }
sub paths    { $R{paths} }
sub root     { $R{paths}{root} }
sub watch    { $R{watch} }
sub sid_dir  { return defined $R{watch} && defined $R{sid} ? "$R{watch}/$R{sid}" : undef }
sub root_ok  { my ($key) = @_; return $R{roots}{$key}{ok} ? 1 : 0 }
sub root_reason { my ($key) = @_; return $R{roots}{$key}{reason} }

sub claude {
    $R{claude} ||= identity::claude_pid();
    return $R{claude};
}

# cc_version() / cc_version_src() (PKG-RUNTIME D.2, MOD-SPEC §2.5): the first source present
# wins: `mod` the matched dispatch record's cc_version (a mod-channel record: $.session.version(),
# exact for the compaction; note_dispatch), `exec` the CLAUDE_CODE_EXECPATH basename (exact for
# this process), `transcript` the version of the newest row in the last 64 KB of the payload's
# transcript (exact for this session; note_transcript), `mirror` <watch>/version.json
# lastVersion (machine-wide, the last version any session's mod saw); otherwise undef.
sub cc_version { _cc(); return $R{cc_version} }
sub cc_version_src { _cc(); return $R{cc_version_src} }

sub _cc {
    return if exists $R{cc_version};
    my ($v, $src);
    my $d = $R{cc_dispatch};
    if (ref $d eq 'HASH' && ($d->{channel} // '') =~ /^mod-/ && _ver_ok($d->{cc_version})) { ($v, $src) = ($d->{cc_version}, 'mod') }
    elsif (defined(my $e = exec_version())) { ($v, $src) = ($e, 'exec') }
    elsif (defined $R{cc_transcript} && defined(my $t = transcript::version($R{cc_transcript}))) { ($v, $src) = ($t, 'transcript') }
    elsif (defined $R{watch}) {
        my $raw = util::read_file("$R{watch}/version.json");
        my $j = defined $raw ? eval { jsonc::decode($raw) } : undef;
        ($v, $src) = ($j->{lastVersion}, 'mirror') if ref $j eq 'HASH' && _ver_ok($j->{lastVersion});
    }
    $R{cc_version} = $v;
    $R{cc_version_src} = defined $v ? $src : undef;
}

sub _ver_ok { my ($v) = @_; return defined $v && !ref $v && $v =~ /^\d+\.\d+\.\d+([.+-][0-9A-Za-z.+-]*)?$/ ? 1 : 0 }

# The dispatch record this call matched (a mod record is source 1) and the payload's
# transcript path (source 3); each resets the cached value.
sub note_dispatch { my ($rec) = @_; $R{cc_dispatch} = $rec; delete @R{qw(cc_version cc_version_src)} }
sub note_transcript {
    my ($p) = @_;
    return unless defined $p && !ref $p && $p ne '';
    $R{cc_transcript} = $p;
    delete @R{qw(cc_version cc_version_src)};
}

# C1h hint: basename of CLAUDE_CODE_EXECPATH when it looks like a version.
sub exec_version {
    my $e = $ENV{CLAUDE_CODE_EXECPATH};
    return undef unless defined $e && $e ne '';
    my $b = util::basename($e);
    return $b =~ /^\d+\.\d+\.\d+([.+-][0-9A-Za-z.+-]*)?$/ ? $b : undef;
}

sub stream_path {
    my ($stream) = @_;
    return undef unless defined $R{watch};
    return $stream if $stream =~ m{/};
    my $sid = $R{sid} // 'unknown';
    return "$R{watch}/$sid.classic.jsonl" if $stream eq 'classic';
    return "$R{watch}/$sid.jsonl"         if $stream eq 'mod';
    return "$R{watch}/$sid/compactions.jsonl" if $stream eq 'compactions';
    return "$R{watch}/$sid/paths.jsonl"   if $stream eq 'paths';
    return "$R{watch}/$sid.alerts.jsonl"  if $stream eq 'alerts';
    return undef;
}

sub envelope {
    my (%o) = @_;
    my $c = claude();
    return { sid => $R{sid}, actor => $o{actor} // $R{actor}, writer => $o{writer} // $R{writer},
             pid => $c->{pid}, cc_version => cc_version(), turn_seq => undef, ts => $o{ts} };
}

# emit(ev, fields, stream => classic|mod|compactions|<path>, actor => .., ts => ISO)
# (ts: a row written later for an earlier event, e.g. reconcile's rollup of a deferred save)
sub emit {
    my ($ev, $fields, %o) = @_;
    my $path = stream_path($o{stream} // 'classic');
    return 0 unless defined $path;
    my $row = log::row($ev, $fields, envelope(%o));
    my $ok = eval { log::append($path, $row); 1 };
    return $ok ? 1 : 0;
}

# once(name) -> 1 the first time for this session (exclusive create), else 0.
sub once {
    my ($name) = @_;
    my $d = sid_dir() // return 0;
    $name =~ s{[^A-Za-z0-9._-]}{_}g;
    my $ok = eval { util::write_excl("$d/once/$name", '', 0600) };
    return $ok ? 1 : 0;
}

# mode(cwd) -> the handoff-root mode of cwd's worktree (lib/repomode.pm, MOD-SPEC §1.5),
# decided once per call; the first call for each distinct (mode, reason) in a session
# logs `handoff_mode {mode, reason, declared, accepted}`.
sub mode {
    my ($cwd) = @_;
    my $m = repomode::decide($cwd);
    emit('handoff_mode', [mode => $m->{mode}, reason => $m->{reason}, declared => jsonc::bool($m->{declared}),
                          accepted => jsonc::bool($m->{accepted})])
        if once("handoff_mode.$m->{mode}.$m->{reason}");
    return $m;
}

# Rows every subcommand writes once per session: test mode, unsafe roots, ambiguity,
# and the settings notes (consent keys given as a flag or env: `config_note`).
sub preamble {
    return unless defined $R{watch} && defined $R{sid};
    emit('test_mode', []) if util::test_mode() && once('test_mode');
    for my $key (qw(handoff_root log_dir disposable_root)) {
        my $r = $R{roots}{$key};
        if ($r->{ok} && $r->{ignored}) {
            emit('root_in_git', [key => $key, ignored => jsonc::true()]) if once("root_in_git.$key");
        } elsif (!$r->{ok} && ($r->{reason} // '') =~ /^root-in-(git|planning)$/) {
            emit('root_in_git', [key => $key, ignored => jsonc::false(), reason => $r->{reason}]) if once("root_in_git.$key");
        }
    }
    emit('config_ambiguous', [candidates => 'several']) if $R{settings}{ambiguous} && once('config_ambiguous');
    for my $n (@{ $R{settings}{notes} || [] }) {
        if ($n =~ /^([a-z_]+): settings file only$/) {
            emit('config_note', [key => $1, note => 'settings-file-only']) if once("config_note.$1");
        } elsif ($n =~ /^([a-z_]+): CLAUDE_CONFIG_DIR is not ~\/\.claude, safe value used$/) {
            emit('config_note', [key => $1, note => 'config-dir-not-home']) if once("config_note.$1.config-dir");
        } elsif ($n =~ /^([a-z_]+): HOME is not the account home, safe value used$/) {
            emit('config_note', [key => $1, note => 'home-not-account']) if once("config_note.$1.home");
        }
    }
    # S-SETTINGS B: an invalid unattended_prod_reads value (forbid used) or a dropped
    # prod_patterns entry, once per session each; the row names the position, never the pattern.
    my $p = eval { settings::prod($R{settings}) };
    for my $x (@{ $p ? $p->{invalid} : [] }) {
        my $tag = defined $x->{index} ? "$x->{key}.$x->{index}" : $x->{key};
        emit('config_invalid', [key => $x->{key}, (defined $x->{index} ? (index => $x->{index}) : ())]) if once("config_invalid.$tag");
    }
}

1;
