package gsd;
# lib/gsd.pm: the GSD position and the active driver of THIS session (OD-8, S-13; owner
# 2026-10-26 21:37, GSD re-entry per session). Owner: WP-core. Read-only: never writes STATE.md
# or anything under .planning/.
#
# What a session works with is decided by its own transcript (its main rows; the file starts
# again at a /clear), never by what the worktree holds: five sessions may share one worktree,
# and only those that worked with GSD get a GSD line, each with its own workstream. Signals,
# matched per row (no row text leaves this module; only skill names, short plain arguments,
# workstream names and paths do):
#   - a typed slash command (`<command-name>`) in a user row that is not meta, a compact summary
#     or a sidechain; `/clear` forgets everything before it;
#   - a Skill tool call in a main assistant row (skill, args);
#   - a Bash tool call that runs gsd-tools (`gsd_run <verb>`, `gsd-tools[.cjs] <verb>`,
#     `node …/gsd-tools.cjs <verb>`) at a command position, outside a heredoc body, with its
#     `--ws` and `--cwd`; a mention in a search pattern, a quoted string or prose does not count;
#   - an Edit, Write, MultiEdit or NotebookEdit of a GSD state file (<root>/.planning/STATE.md,
#     ROADMAP.md, REQUIREMENTS.md, PROJECT.md, HANDOFF.json, .continue-here*, phases/…, and
#     the same files under workstreams/<ws>/; another file dropped into a workstream folder is
#     not GSD work). A Read never counts and never names a workstream.
# A session uses GSD when one of these is a GSD command (`gsd-*` or `gsd:*`; not the maintenance
# commands in %NOT_WORK; `gsd-workstreams` only with switch or resume), any other command or
# skill invoked with `--ws <name>` where that workstream's folder exists (a skill that drives GSD
# work, such as a phase loop), a gsd-tools run or a state-file write. Its workstream is the newest one those signals name
# (`--ws <name>`, `--ws=<name>`, `gsd-workstreams switch|resume <name>`, a state-file write
# under workstreams/<name>/) whose folder exists under the GSD root; the shared
# .planning/active-workstream pointer never names one. With none named the session works flat.
# The driver is the newest typed or Skill-invoked skill of %DRIVERS or skill that drives a GSD
# workstream (above): a loop that drives the session; /loop and /goal keep themselves and are
# never listed.
use strict;
use warnings;
use utf8;

our $SCAN_MS = 1500;                  # one scan's time budget; a scan over it reads `not measured (timeout)`
our $ROW_MAX = 4 * 1024 * 1024;       # a longer row is never decoded
our $WS_KEEP = 8;                     # newest workstream names kept
our $ARGS_MAX = 100;                  # longer arguments are not shown
our $LINE_MAX = 400;                  # characters of the GSD line (the driver line is never cut: its
                                      # parts are bounded, and a cut would break a re-enter command)
our $CACHE = 'gsd-scan.json';         # <watch>/<sid>/: read offset and facts so far
our %DRIVERS = map { $_ => 1 } qw(gsd-autonomous gsd-execute-phase gsd-manager
                                  superpowers:executing-plans superpowers:subagent-driven-development);
our %NOT_WORK = map { $_ => 1 } qw(gsd-help gsd-settings gsd-config gsd-update gsd-health);
my $WS = qr/[A-Za-z0-9][A-Za-z0-9._-]{0,63}/;
my $STATE_FILE = qr{\A(?:workstreams/($WS)/)?(?:STATE\.md|ROADMAP\.md|REQUIREMENTS\.md|PROJECT\.md|HANDOFF\.json|\.continue-here[^/]*|phases/.+)\z};
my $CMD_AT = qr{(?:\A|[;&|\n(`]|\$\()[ \t]*(?:(?:[A-Za-z_][A-Za-z0-9_]*=[^\s;&|]*|env|command|exec|time)[ \t]+)*};
my $TOOL = qr{(?:gsd_run|gsd-tools(?:\.cjs)?|node[ \t]+(?:"[^"\n]*gsd-tools\.cjs"|'[^'\n]*gsd-tools\.cjs'|[^\s;&|]*gsd-tools\.cjs)|"[^"\n]*/gsd-tools(?:\.cjs)?"|[^\s;&|"'`]*/gsd-tools(?:\.cjs)?)};
my %NOT_VERB = map { $_ => 1 } qw(help runtime-identity version);
my %EDIT = map { $_ => 1 } qw(Edit Write MultiEdit NotebookEdit);

# transcript_path(sid, given, dir…) -> this session's main transcript, or undef: the given path,
# else the hook payload's (rc), else <config dir>/projects/<slug of a dir>/<sid>.jsonl, else the
# one project folder that holds <sid>.jsonl.
sub transcript_path {
    my ($sid, $given, @dirs) = @_;
    return $given if defined $given && !ref $given && $given ne '' && -f $given;
    return undef unless defined $sid && !ref $sid && $sid =~ /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/;
    my $rt = eval { rc::transcript() };
    return $rt if defined $rt && -f $rt && util::basename($rt) eq "$sid.jsonl";
    my $cfg = (defined $ENV{CLAUDE_CONFIG_DIR} && $ENV{CLAUDE_CONFIG_DIR} ne '') ? $ENV{CLAUDE_CONFIG_DIR} : util::home() . '/.claude';
    my %seen;
    for my $d (grep { defined && $_ ne '' } map { ($_, util::real_path($_)) } grep { defined && $_ ne '' } @dirs) {
        next if $seen{$d}++;
        (my $slug = $d) =~ s/[^A-Za-z0-9]/-/g;
        my $p = "$cfg/projects/$slug/$sid.jsonl";
        return $p if -f $p;
    }
    my @hit = grep { -f "$cfg/projects/$_/$sid.jsonl" } util::list_dir("$cfg/projects");
    return @hit == 1 ? "$cfg/projects/$hit[0]/$sid.jsonl" : undef;
}

sub _norm {
    my ($n) = @_;
    $n = lc($n // '');
    $n =~ s{\A/}{};
    $n =~ s/\Agsd:/gsd-/;
    return $n;
}

# Arguments as shown in a re-enter command: one line, plain characters, <= $ARGS_MAX; undef
# when they cannot be shown.
sub _args {
    my ($a) = @_;
    return '' unless defined $a && !ref $a;
    $a =~ s/\s+/ /g;
    $a =~ s/\A | \z//g;
    return '' if $a eq '';
    return undef if length($a) > $ARGS_MAX || $a =~ m{[^A-Za-z0-9 ._:/=,@+#%~-]};
    return $a;
}

sub _ws_from_args {
    my ($name, $args) = @_;
    return undef unless defined $args && !ref $args;
    return $2 if $args =~ /(?:\A|\s)--ws(?:\s+|=)(['"]?)($WS)\1(?![A-Za-z0-9._-])/;
    return $1 if $name eq 'gsd-workstreams' && $args =~ /\A\s*(?:switch|resume)\s+($WS)/;
    return undef;
}

sub _cwd_from_args {
    my ($args) = @_;
    return undef unless defined $args && !ref $args;
    return $2 if $args =~ /(?:\A|\s)--cwd(?:\s+|=)(['"]?)(\/[^'"\s;&|]+)\1/;
    return undef;
}

sub _is_gsd_cmd {
    my ($name, $args) = @_;
    return 0 if $NOT_WORK{$name};
    if ($name eq 'gsd-workstreams') { return (defined $args && $args =~ /\A\s*(?:switch|resume)\s/) ? 1 : 0 }
    return 1 if $name =~ /\Agsd-[a-z0-9]/;
    return 0;
}

# The workstream folder of name under the GSD root at or above dir (a trailing dot of prose
# dropped): [root, name], or ().
sub _ws_dir {
    my ($dir, $name) = @_;
    return () unless defined $name;
    my $r = _gsd_root($dir) // return ();
    for my $n ($name, ($name =~ /\A(.+?)\.+\z/ ? $1 : ())) {
        return ($r, $n) if $n ne 'none' && -d "$r/.planning/workstreams/$n";
    }
    return ();
}

# bash_calls(command) -> [{verb, ws, cwd}…]: the gsd-tools runs of one Bash command.
sub bash_calls {
    my ($c) = @_;
    return [] unless defined $c && !ref $c && (index($c, 'gsd-tools') >= 0 || index($c, 'gsd_run') >= 0);
    $c =~ s/<<-?[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n.*?\n[ \t]*\2[ \t]*(?=\n|\z)//gs;
    my @out;
    while ($c =~ /$CMD_AT$TOOL[ \t]+(?:query[ \t]+)?([a-z][A-Za-z0-9._-]*)([^;&|\n]*)/g) {
        my ($verb, $rest) = ($1, $2);
        next if $NOT_VERB{$verb};
        my %e = (verb => $verb);
        $e{ws} = $2 if $rest =~ /(?:\A|\s)--ws(?:[ \t]+|=)(['"]?)($WS)\1(?![A-Za-z0-9._-])/;
        $e{cwd} = $2 if $rest =~ /(?:\A|\s)--cwd(?:[ \t]+|=)(['"]?)(\/[^'"\s;&|]+)\1/;
        push @out, \%e;
    }
    return \@out;
}

sub _push_ws {
    my ($st, $name, $root, $ts) = @_;
    return unless defined $name && $name =~ /\A$WS\z/ && $name ne 'none';
    my @w = grep { !($_->{name} eq $name && ($_->{root} // '') eq ($root // '')) } @{ $st->{ws} || [] };
    push @w, { name => $name, root => $root, ts => $ts };
    shift @w while @w > $WS_KEEP;
    $st->{ws} = \@w;
}

# One typed command or Skill call.
sub _invoked {
    my ($st, $via, $raw, $args, $cwd, $ts) = @_;
    my $name = _norm($raw);
    return unless $name =~ /\A[a-z0-9][a-z0-9:._-]*\z/;
    if ($via eq 'typed' && $name eq 'clear') { %$st = (); return }
    my $shown = _args($args);
    my %e = (via => $via, name => $name, args => $shown, hidden => (defined $shown ? 0 : 1), ts => $ts);
    my $ws = _ws_from_args($name, $args);
    $e{ws} = $ws unless defined $shown;
    my $root = _cwd_from_args($args) // $cwd;
    my $gsd = _is_gsd_cmd($name, $args);
    # Another skill invoked with an existing GSD workstream drives GSD work (a phase loop).
    my $loop = !$gsd && $name !~ /\Agsd-/ && _ws_dir($root, $ws) ? 1 : 0;
    if ($gsd || $loop) {
        $st->{gsd} = { %e, root => $root };
        _push_ws($st, $ws, $root, $ts);
    }
    $st->{driver} = \%e if $DRIVERS{$name} || $loop;
}

sub _row {
    my ($st, $j, $cwd0) = @_;
    return unless ref $j eq 'HASH' && !$j->{isSidechain};
    my $type = $j->{type} // '';
    my $ts = util::parse_iso($j->{timestamp} // '');
    my $cwd = (defined $j->{cwd} && !ref $j->{cwd} && $j->{cwd} ne '') ? $j->{cwd} : $cwd0;
    my $c = ref $j->{message} eq 'HASH' ? $j->{message}{content} : undef;
    if ($type eq 'user') {
        return if $j->{isMeta} || $j->{isCompactSummary} || $j->{isVisibleInTranscriptOnly};
        my $t = !ref $c ? ($c // '')
              : ref $c eq 'ARRAY' ? join("\n", map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @$c) : '';
        while ($t =~ m{<command-name>/?([^<\s]+)</command-name>(?:\s*<command-args>(.*?)</command-args>)?}gs) {
            _invoked($st, 'typed', $1, $2, $cwd, $ts);
        }
        return;
    }
    return unless $type eq 'assistant' && ref $c eq 'ARRAY';
    for my $it (@$c) {
        next unless ref $it eq 'HASH' && ($it->{type} // '') eq 'tool_use' && ref $it->{input} eq 'HASH';
        my ($n, $in) = ($it->{name} // '', $it->{input});
        if ($n eq 'Skill') {
            _invoked($st, 'Skill', $in->{skill}, $in->{args}, $cwd, $ts) if defined $in->{skill} && !ref $in->{skill};
        } elsif ($n eq 'Bash') {
            for my $b (@{ bash_calls($in->{command}) }) {
                my $root = $b->{cwd} // $cwd;
                $st->{gsd} = { via => 'Bash', name => "gsd-tools $b->{verb}", args => '', hidden => 0, ts => $ts, root => $root };
                _push_ws($st, $b->{ws}, $root, $ts);
            }
        } elsif ($EDIT{$n}) {
            my $p = $in->{file_path} // $in->{notebook_path};
            next unless defined $p && !ref $p && index($p, '.planning/') >= 0;
            $p = "$cwd/$p" if $p !~ m{\A/} && defined $cwd;
            next unless $p =~ m{\A(/.*?)/\.planning/(.+)\z};
            my ($root, $rel) = ($1, $2);
            next unless $rel =~ $STATE_FILE;
            my $ws = $1;
            my ($pre, $short) = $rel =~ m{\A(workstreams/[^/]+/)(.+)\z} ? ($1, $2) : ('', $rel);
            $short =~ s{\A(?:[^/]+/)+}{…/};
            $short = $pre . $short;
            $st->{gsd} = { via => $n, name => ".planning/$short", args => '', hidden => 0, ts => $ts, root => $root, file => 1 };
            _push_ws($st, $ws, $root, $ts);
        }
    }
}

# The bytes just before offset (up to 256), hashed: a cached offset is reused only while they are
# unchanged (a transcript only grows; a file rewritten in place is read again from the start).
sub _mark {
    my ($fh, $off) = @_;
    return '' unless $off;
    my $n = $off < 256 ? $off : 256;
    seek($fh, $off - $n, 0) or return '';
    my $got = CORE::read($fh, my $buf, $n);
    return (defined $got && $got == $n) ? sha::hex256($buf) : '';
}

# scan(path, %o{cache, budget_ms}) -> (state, 'ok' | 'timeout' | 'unread'). Reads the transcript
# from the cached offset (the same file, not shorter than the offset, the same bytes before it),
# else from the start.
sub scan {
    my ($path, %o) = @_;
    my $deadline = util::clock_ms() + ($o{budget_ms} // $SCAN_MS);
    my @s = stat $path;
    return ({}, 'unread') unless @s;
    my ($st, $off, $cwd0) = ({}, 0, undef);
    open(my $fh, '<:raw', $path) or return ({}, 'unread');
    if (defined $o{cache} && -f $o{cache}) {
        my $c = eval { jsonc::decode(util::read_file($o{cache}, 256 * 1024) // '') };
        if (ref $c eq 'HASH' && ($c->{v} // 0) == 1 && ($c->{path} // '') eq $path && ($c->{dev} // -1) == $s[0]
            && ($c->{ino} // -1) == $s[1] && ($c->{offset} // -1) >= 0 && $c->{offset} <= $s[7] && ref $c->{state} eq 'HASH'
            && ($c->{mark} // '') eq _mark($fh, $c->{offset})) {
            ($st, $off, $cwd0) = ($c->{state}, $c->{offset}, $c->{cwd});
        }
    }
    seek($fh, $off, 0);
    my ($n, $status) = (0, 'ok');
    while (my $l = <$fh>) {
        last unless substr($l, -1) eq "\n";    # a row still being written: next time
        $off += length $l;
        if (++$n % 256 == 0 && util::clock_ms() > $deadline) { $status = 'timeout'; last }
        # metadata rows (request blobs, titles, modes) lead with their type; message rows do not
        next if index($l, '{"type":"') == 0 && index($l, '{"type":"user"') != 0 && index($l, '{"type":"assistant"') != 0;
        next if index($l, '"isSidechain":true') >= 0;
        my $user = index($l, '"type":"user"') >= 0;
        if ($user) { next unless index($l, '<command-name>') >= 0 }
        else {
            next unless index($l, '"type":"assistant"') >= 0 && index($l, '"tool_use"') >= 0
                && (index($l, '"Skill"') >= 0 || index($l, 'gsd') >= 0 || index($l, '.planning/') >= 0);
        }
        next if length($l) > $ROW_MAX;
        my $j = eval { jsonc::decode($l) } or next;
        $cwd0 //= $j->{cwd} if ref $j eq 'HASH' && defined $j->{cwd} && !ref $j->{cwd};
        _row($st, $j, $cwd0);
    }
    if (defined $o{cache}) {
        my $mark = _mark($fh, $off);
        eval { util::write_atomic($o{cache}, jsonc::encode_bytes({ v => 1, path => $path, dev => $s[0], ino => $s[1],
                                                                   offset => $off, mark => $mark, cwd => $cwd0, state => $st }) . "\n", 0600) };
    }
    close $fh;
    return ($st, $status);
}

# The folder holding .planning/ at or above dir, or undef.
sub _gsd_root {
    my ($dir) = @_;
    return undef unless defined $dir && $dir =~ m{\A/};
    for (1 .. 24) {
        return $dir if -d "$dir/.planning";
        last if $dir eq '/' || $dir eq '';
        $dir =~ s{/[^/]*\z}{};
        $dir = '/' if $dir eq '';
    }
    return undef;
}

sub _cut { my ($s, $n) = @_; $s =~ s/\s+/ /g; return length($s) > $n ? substr($s, 0, $n - 1) . '…' : $s }

# state(path) -> {status, phase, stopped_at, last_activity} from STATE.md: the frontmatter keys
# (status, current_phase, stopped_at, last_activity), else the matching prose lines.
sub state {
    my ($path) = @_;
    my $raw = util::read_file($path, 256 * 1024) // return undef;
    $raw = util::text($raw);
    $raw =~ s/\r\n?/\n/g;
    my %f;
    if ($raw =~ s/\A---\n(.*?)\n---\n//s) {
        for my $l (split /\n/, $1) {
            next unless $l =~ /\A([a-z_]+):[ \t]*(.*?)[ \t]*\z/;
            my ($k, $v) = ($1, $2);
            $v =~ s/\A(["'])(.*)\1\z/$2/;
            $f{$k} //= $v if $v ne '';
        }
    }
    my %prose = (status => qr/status/i, current_phase => qr/(?:current )?phase/i, stopped_at => qr/stopped at/i,
                 last_activity => qr/last activity/i);
    for my $k (sort keys %prose) {
        next if defined $f{$k};
        $f{$k} = $1 if $raw =~ /^[ \t>*-]*\**$prose{$k}\**[ \t]*:\**[ \t]*(\S.*?)[ \t]*$/m;
    }
    return { status => $f{status}, phase => $f{current_phase}, stopped_at => $f{stopped_at}, last_activity => $f{last_activity} };
}

sub _state_text {
    my ($sp) = @_;
    return 'not found' unless -f $sp;
    my $s = state($sp) or return 'unreadable';
    my @p;
    push @p, 'status ' . _cut($s->{status}, 30) if defined $s->{status};
    push @p, 'phase ' . _cut($s->{phase}, 40) if defined $s->{phase};
    push @p, 'stopped at ' . _cut($s->{stopped_at}, 60) if defined $s->{stopped_at};
    push @p, 'last activity ' . _cut($s->{last_activity}, 30) if defined $s->{last_activity};
    return @p ? join(' · ', @p) : 'no position recorded';
}

# A command as invoked (`shown`: arguments that cannot be shown are named so), or as re-entered
# (such arguments are left out but their `--ws`).
sub _cmd {
    my ($e, $shown) = @_;
    my $c = '/' . $e->{name};
    return $c . " $e->{args}" if defined $e->{args} && $e->{args} ne '';
    return $c . ' (arguments not shown)' if $e->{hidden} && $shown;
    return $c . (defined $e->{ws} ? " --ws $e->{ws}" : '');
}

sub _when { my ($e) = @_; return defined $e->{ts} ? "$e->{via}, " . util::stamp($e->{ts}) : $e->{via} }

# session(sid, transcript, cwd, worktree, cache_dir, budget_ms) -> {status: gsd | driver | none |
# timeout | unread, lines => [GSD line?, Active driver line?], line, driver, state (the STATE.md
# path, GSD only), workstream, root, reenter => [commands]}. No line for a session that worked
# with neither GSD nor a driver skill, nor for one whose transcript is not found.
sub session {
    my (%a) = @_;
    my $path = transcript_path($a{sid}, $a{transcript}, $a{cwd}, $a{worktree});
    return { status => 'unread', lines => [] } unless defined $path;
    my $cache = defined $a{cache_dir} ? "$a{cache_dir}/$CACHE" : undef;
    my ($st, $status) = scan($path, cache => $cache, budget_ms => $a{budget_ms});
    return { status => 'unread', lines => [] } if $status eq 'unread';
    return { status => 'timeout', lines => ['GSD: not measured (timeout)'] } if $status eq 'timeout';
    my ($g, $d) = ($st->{gsd}, $st->{driver});
    return { status => 'none', lines => [] } unless $g || $d;
    my %out = (status => ($g ? 'gsd' : 'driver'), lines => []);
    my @re;
    if ($g) {
        my $here = $a{worktree} // $a{cwd};
        my ($ws, $root);
        for my $w (reverse @{ $st->{ws} || [] }) {
            ($root, $ws) = _ws_dir($w->{root} // $here, $w->{name});
            last if defined $ws;
        }
        $root //= _gsd_root($g->{root} // $here) // _gsd_root($here);
        my $sp = defined $root ? (defined $ws ? "$root/.planning/workstreams/$ws/STATE.md" : "$root/.planning/STATE.md") : undef;
        my $line = 'GSD (this session): ' . (defined $ws ? "workstream $ws" : 'no workstream named') . ' · '
                 . (defined $sp ? util::abbrev($sp) . ': ' . _state_text($sp) : 'no .planning folder found');
        $out{line} = _cut($line, $LINE_MAX);
        @out{qw(workstream root)} = ($ws, $root);
        $out{state} = $sp if defined $sp && -f $sp;
        push @re, '/gsd-resume-work' . (defined $ws ? " --ws $ws" : '');
    }
    push @re, _cmd($d) if $d;
    my $what = $d ? _cmd($d, 1) . ' (' . _when($d) . ')'
             : 'GSD (newest: ' . ($g->{via} eq 'typed' || $g->{via} eq 'Skill' ? _cmd($g, 1) : _cut($g->{name}, 120)) . ', ' . _when($g) . ')';
    $out{driver} = "Active driver: $what · re-enter: " . join(', then ', @re);
    $out{reenter} = \@re;
    $out{lines} = [ grep { defined } $out{line}, $out{driver} ];
    return \%out;
}

1;
