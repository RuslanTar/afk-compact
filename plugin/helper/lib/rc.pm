package rc;
# lib/rc.pm: the run context of one helper call: session id, settings, paths, root
# checks, the row envelope and once-per-session markers. Owner: WP-core.
use strict;
use warnings;

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

sub cc_version {
    return $R{cc_version} if exists $R{cc_version};
    my $v;
    if (defined $R{watch}) {
        my $raw = util::read_file("$R{watch}/version.json");
        my $j = defined $raw ? eval { jsonc::decode($raw) } : undef;
        $v = $j->{lastVersion} if ref $j eq 'HASH' && defined $j->{lastVersion} && !ref $j->{lastVersion};
    }
    $v //= exec_version();
    $R{cc_version} = $v;
    return $v;
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

# Rows every subcommand writes once per session: test mode, unsafe roots, ambiguity.
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
}

1;
