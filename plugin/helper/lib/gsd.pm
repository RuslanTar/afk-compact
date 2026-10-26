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
#     `node …/gsd-tools.cjs <verb>`) at a command position, outside a heredoc body and outside
#     quoted text (a quoted gsd-tools path is kept, and so is a `$(…)` inside double quotes),
#     with a verb that reads or changes planning state (%STATE_VERB: not the maintenance and
#     config verbs a /gsd-update runs), with its `--ws` and `--cwd`; a mention in a search
#     pattern, a quoted string or prose does not count;
#   - an Edit, Write, MultiEdit or NotebookEdit of a GSD state file (<root>/.planning/STATE.md,
#     ROADMAP.md, REQUIREMENTS.md, PROJECT.md, HANDOFF.json, .continue-here*, phases/…, and
#     the same files under workstreams/<ws>/; another file dropped into a workstream folder is
#     not GSD work). A Read never counts and never names a workstream.
# A session uses GSD when one of these is a GSD command (`gsd-*` or `gsd:*`; not the maintenance
# commands in %NOT_WORK; `gsd-workstreams` only with switch or resume), a gsd-tools run, a
# state-file write, or a driver skill (below) invoked with `--ws` of an existing workstream.
# Any other command or skill with `--ws <name>` only names a workstream (for a session that uses
# GSD); it is neither GSD work nor a driver (a handoff or catch-up skill is one-shot).
# Its workstream is the newest one those signals name (`--ws <name>`, `--ws=<name>`,
# `gsd-workstreams switch|resume <name>`, a state-file write under workstreams/<name>/) whose
# folder exists under a GSD root the session touched (the row's cwd, `--cwd`, `--repo`, a
# state-file write's root); the shared .planning/active-workstream pointer never names one.
# With none named the session works flat.
# The driver is the newest typed or Skill-invoked loop skill: one of %DRIVERS, one the owner lists
# in the `driver_skills` setting, or the first one the user chained into a typed GSD command that
# names an existing workstream, with `and` or `then` (`/gsd-resume-work --ws X and /<loop>`).
# /loop and /goal keep themselves and are never listed.
# Only a driver gets an `Active driver:` line (the resume protocol's [driver] re-entry keys on it);
# a session that only used GSD gets its GSD line and a passive `GSD re-entry` line.
use strict;
use warnings;
use utf8;

our $SCAN_MS = 1500;                  # one scan's time budget; a scan over it reads `not measured (timeout)`
our $ROW_MAX = 4 * 1024 * 1024;       # a longer row is never decoded
our $WS_KEEP = 8;                     # newest workstream names kept
our $ROOTS_KEEP = 8;                  # newest GSD roots kept
our $SKILLS_KEEP = 64;                # newest invoked skill names kept (one entry each)
our $ARGS_MAX = 100;                  # longer arguments are not shown
our $LINE_MAX = 400;                  # characters of the GSD line (the driver line is never cut: its
                                      # parts are bounded, and a cut would break a re-enter command)
our $CACHE = 'gsd-scan.json';         # <watch>/<sid>/: read offset and facts so far
our $CACHE_V = 2;
our %DRIVERS = map { $_ => 1 } qw(gsd-autonomous gsd-execute-phase gsd-manager
                                  superpowers:executing-plans superpowers:subagent-driven-development);
our %NOT_WORK = map { $_ => 1 } qw(gsd-help gsd-settings gsd-config gsd-update gsd-health);
# Claude Code's own commands: never a skill, never a chained loop.
our %BUILTIN = map { $_ => 1 } qw(clear compact loop goal model effort resume config help exit quit context cost
                                  status memory init review login logout permissions hooks agents mcp plugin
                                  plugins doctor add-dir export rewind fork btw usage);
# gsd-tools verbs that read or change planning state (the first part, before a dot). `workstream`
# counts except with list or get.
our %STATE_VERB = map { $_ => 1 } qw(state state-snapshot init roadmap phase phases phase-plan-index find-phase
                                     commit commit-to-subrepo verify verify-summary verification validate progress
                                     milestone requirements summary-extract todo list-todos uat audit-uat audit-open
                                     history-digest frontmatter scaffold template planning quick-tasks-append stats
                                     task user-story learnings list-seeds gap-analysis workstream);
my $WS = qr/[A-Za-z0-9][A-Za-z0-9._-]{0,63}/;
my $STATE_FILE = qr{\A(?:workstreams/($WS)/)?(?:STATE\.md|ROADMAP\.md|REQUIREMENTS\.md|PROJECT\.md|HANDOFF\.json|\.continue-here[^/]*|phases/.+)\z};
my $CMD_AT = qr{(?:\A|[;&|\n(`]|\$\()[ \t]*(?:(?:[A-Za-z_][A-Za-z0-9_]*=[^\s;&|]*|env|command|exec|time)[ \t]+)*};
my $TOOL = qr{(?:gsd_run|gsd-tools(?:\.cjs)?|node[ \t]+(?:"[^"\n]*gsd-tools\.cjs"|'[^'\n]*gsd-tools\.cjs'|[^\s;&|]*gsd-tools\.cjs)|"[^"\n]*/gsd-tools(?:\.cjs)?"|[^\s;&|"'`]*/gsd-tools(?:\.cjs)?)};
my $PLAIN_PATH = qr{\A/[A-Za-z0-9._/@+-]+\z};
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

# The GSD root an invocation names: `--cwd`, `--repo` or `--project-dir` with an absolute path.
sub _root_from_args {
    my ($args) = @_;
    return undef unless defined $args && !ref $args;
    return $3 if $args =~ /(?:\A|\s)--(cwd|repo|project-dir)(?:\s+|=)(['"]?)(\/[^'"\s;&|]+)\2/;
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

# Quoted text of a Bash command, blanked: a span that is only a gsd-tools path stays (the
# command itself), and a double-quoted span keeps its `$(…)` substitutions (they run).
sub _unquote {
    my ($c) = @_;
    $c =~ s{("(?:[^"\\]|\\.)*"|'[^']*')}{
        my $q = $1;
        $q =~ m{\A(["'])[^"'\n|;&]*/gsd-tools(?:\.cjs)?\1\z} ? $q
          : substr($q, 0, 1) eq '"' ? join(' ', 'Q', map { "\$($_)" } $q =~ /\$\(([^()"]*)\)/g)
          : 'Q'
    }gse;
    return $c;
}

# bash_calls(command) -> [{verb, ws, cwd}…]: the gsd-tools runs of one Bash command that read or
# change planning state.
sub bash_calls {
    my ($c) = @_;
    return [] unless defined $c && !ref $c && (index($c, 'gsd-tools') >= 0 || index($c, 'gsd_run') >= 0);
    $c =~ s/<<-?[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n.*?\n[ \t]*\2[ \t]*(?=\n|\z)//gs;
    $c = _unquote($c);
    my @out;
    while ($c =~ /$CMD_AT$TOOL[ \t]+(?:query[ \t]+)?([a-z][A-Za-z0-9._-]*)([^;&|\n]*)/g) {
        my ($verb, $rest) = ($1, $2);
        my ($base, $sub) = $verb =~ /\A([^.]+)(?:\.(.*))?\z/;
        next unless $STATE_VERB{$base};
        if ($base eq 'workstream') {
            my $w = $sub // ($rest =~ /\A[ \t]+([a-z][a-z-]*)/ ? $1 : '');
            next if $w eq '' || $w eq 'list' || $w eq 'get';
        }
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

sub _push_root {
    my ($st, $dir) = @_;
    my $r = _gsd_root($dir) // return;
    my @r = grep { $_ ne $r } @{ $st->{roots} || [] };
    push @r, $r;
    shift @r while @r > $ROOTS_KEEP;
    $st->{roots} = \@r;
}

# One invoked skill (newest entry per name; ordered by seq).
sub _skill {
    my ($st, $e) = @_;
    my $s = $st->{skills} ||= {};
    $s->{ $e->{name} } = $e;
    if (keys %$s > $SKILLS_KEEP) {
        my ($old) = sort { $s->{$a}{seq} <=> $s->{$b}{seq} } keys %$s;
        delete $s->{$old};
    }
}

# One typed command or Skill call.
sub _invoked {
    my ($st, $via, $raw, $args, $cwd, $ts) = @_;
    my $name = _norm($raw);
    return unless $name =~ /\A[a-z0-9][a-z0-9:._-]*\z/;
    if ($via eq 'typed' && $name eq 'clear') { %$st = (); return }
    return if $BUILTIN{$name};
    my $shown = _args($args);
    my $ws = _ws_from_args($name, $args);
    my $named = _root_from_args($args);
    my $root = $named // $cwd;
    my %e = (via => $via, name => $name, args => $shown, hidden => (defined $shown ? 0 : 1), ts => $ts,
             seq => ++$st->{seq}, root => $root);
    $e{ws} = $ws if defined $ws;
    my $gsd = _is_gsd_cmd($name, $args);
    if ($gsd) {
        $st->{gsd} = { %e };
        _push_root($st, $root);
    }
    _push_root($st, $named) if defined $named && ($gsd || defined $ws);
    # A workstream named by any invocation; it decides only for a session that uses GSD.
    _push_ws($st, $ws, $root, $ts);
    _skill($st, \%e) unless $NOT_WORK{$name} || ($name =~ /\Agsd-/ && !$DRIVERS{$name});
    # The owner's form `/gsd-resume-work --ws X and /<loop>`: the first skill chained with `and` or
    # `then` on the same line into a typed GSD command that names a workstream drives that
    # workstream (checked at session()); a skill on a line of its own (`--ws X\n/catch-up`), after
    # the first, or after a GSD command without a workstream (`/gsd-resume-work and
    # /<handoff resumer> <file>`) is a one-shot request.
    if ($gsd && $via eq 'typed' && defined $ws && defined $args && !ref $args) {
        while ($args =~ m{(?:\A|[ \t,;])(?:and|then)[ \t]+/([a-z][a-z0-9:._-]*?)(?=[\s,;!?)]|\.(?:\s|\z)|\z)}g) {
            my $n = _norm($1);
            next if $BUILTIN{$n} || $NOT_WORK{$n} || $n eq $name || ($n =~ /\Agsd-/ && !$DRIVERS{$n});
            $st->{chained}{$n} = { ws => $ws, root => $root };
            my %c = (via => 'typed', name => $n, args => '', hidden => 0, ts => $ts, seq => ++$st->{seq}, root => $root,
                     chained => 1);
            $c{ws} = $ws if defined $ws;
            _skill($st, \%c);
            last;
        }
    }
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
                _push_root($st, $root);
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
            _push_root($st, $root);
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
        if (ref $c eq 'HASH' && ($c->{v} // 0) == $CACHE_V && ($c->{path} // '') eq $path && ($c->{dev} // -1) == $s[0]
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
        eval { util::write_atomic($o{cache}, jsonc::encode_bytes({ v => $CACHE_V, path => $path, dev => $s[0], ino => $s[1],
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

# The driver skill names: %DRIVERS plus the owner's `driver_skills` setting (`;`-separated).
sub driver_names {
    my %d = %DRIVERS;
    my $v = eval { rc::val('driver_skills') };
    $d{ _norm($_) } = 1 for eval { settings::list($v) };
    return \%d;
}

# A skill chained into a typed GSD command whose workstream exists (_invoked).
sub _chained {
    my ($st, $name, @roots) = @_;
    my $c = $st->{chained} && $st->{chained}{$name};
    return 0 unless ref $c eq 'HASH' && defined $c->{ws};
    return _ws_any($c->{ws}, $c->{root}, @roots) ? 1 : 0;
}

# The first workstream folder of name under one of the roots: (root, name) or ().
sub _ws_any {
    my ($name, @roots) = @_;
    my %seen;
    for my $r (grep { defined && !$seen{$_}++ } @roots) {
        my @hit = _ws_dir($r, $name);
        return @hit if @hit;
    }
    return ();
}

# Arguments with each `--ws <name>` written as the workstream folder it resolves to (a trailing
# dot of prose dropped).
sub _fix_ws {
    my ($args, @roots) = @_;
    return $args unless defined $args && $args ne '';
    $args =~ s{(\A|\s)--ws(\s+|=)($WS)(?![A-Za-z0-9._-])}{ my ($p, $s, $n) = ($1, $2, $3); my (undef, $v) = _ws_any($n, @roots); "$p--ws$s" . ($v // $n) }ge;
    return $args;
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
# timeout | unread, lines => [GSD line?, GSD re-entry line?, Active driver line?], line, reentry
# (the GSD re-entry line), driver (the Active driver line), state (the STATE.md path, GSD only),
# workstream, root, reenter => [the re-enter command]}. No line for a session that worked with
# neither GSD nor a driver skill, nor for one whose transcript is not found.
sub session {
    my (%a) = @_;
    my $path = transcript_path($a{sid}, $a{transcript}, $a{cwd}, $a{worktree});
    return { status => 'unread', lines => [] } unless defined $path;
    my $cache = defined $a{cache_dir} ? "$a{cache_dir}/$CACHE" : undef;
    my ($st, $status) = scan($path, cache => $cache, budget_ms => $a{budget_ms});
    return { status => 'unread', lines => [] } if $status eq 'unread';
    return { status => 'timeout', lines => ['GSD: not measured (timeout)'] } if $status eq 'timeout';
    my $here = $a{worktree} // $a{cwd};
    my @roots = (reverse(@{ $st->{roots} || [] }), $here);
    my $dn = driver_names();
    my ($d) = sort { $b->{seq} <=> $a->{seq} }
              grep { $dn->{ $_->{name} } || _chained($st, $_->{name}, @roots) } values %{ $st->{skills} || {} };
    my $g = $st->{gsd};
    # A driver invoked with an existing workstream drives GSD work.
    if (!$g && $d && defined $d->{ws} && _ws_any($d->{ws}, $d->{root}, @roots)) {
        $g = $d;
    }
    return { status => 'none', lines => [] } unless $g || $d;
    my %out = (status => ($g ? 'gsd' : 'driver'), lines => []);
    my ($ws, $root, $cwdflag) = (undef, undef, '');
    if ($g) {
        for my $w (reverse @{ $st->{ws} || [] }) {
            ($root, $ws) = _ws_any($w->{name}, $w->{root}, @roots);
            last if defined $ws;
        }
        $root //= _gsd_root($g->{root} // $here) // _gsd_root($here);
        my $sp = defined $root ? (defined $ws ? "$root/.planning/workstreams/$ws/STATE.md" : "$root/.planning/STATE.md") : undef;
        my $line = 'GSD (this session): ' . (defined $ws ? "workstream $ws" : 'no workstream named') . ' · '
                 . (defined $sp ? util::abbrev($sp) . ': ' . _state_text($sp) : 'no .planning folder found');
        $out{line} = _cut($line, $LINE_MAX);
        @out{qw(workstream root)} = ($ws, $root);
        $out{state} = $sp if defined $sp && -f $sp;
        # GSD work in another checkout than this session's: its commands need --cwd.
        my $hr = _gsd_root($here);
        $cwdflag = " --cwd $root" if defined $root && (!defined $hr || $hr ne $root) && $root =~ $PLAIN_PATH;
    }
    my $gsd_cmd = '/gsd-resume-work' . (defined $ws ? " --ws $ws" : '') . $cwdflag;
    my $re;
    if ($d) {
        my %e = %$d;
        $e{args} = _fix_ws($e{args}, $e{root}, @roots) if defined $e{args};
        if (defined $e{ws}) { my (undef, $v) = _ws_any($e{ws}, $e{root}, @roots); $e{ws} = $v // $e{ws} }
        $re = _cmd(\%e);
        # A GSD loop re-enters with the session's workstream and GSD root (a superpowers driver
        # takes no GSD flags).
        if ($g && ($e{name} =~ /\Agsd-/ || !$DRIVERS{ $e{name} })) {
            $re .= " --ws $ws" if defined $ws && $re !~ /(?:\A|\s)--ws(?:\s|=)/;
            $re .= $cwdflag if $cwdflag ne '' && $re !~ /(?:\A|\s)--(?:cwd|repo|project-dir)(?:\s|=)/;
        }
        $out{driver} = 'Active driver: ' . _cmd(\%e, 1) . ' (' . _when(\%e) . ") · re-enter: $re";
        $out{reentry} = "GSD re-entry (new session only): $gsd_cmd" if $g && !($e{name} =~ /\Agsd-/ || !$DRIVERS{ $e{name} });
    } else {
        $out{reentry} = "GSD re-entry (new session only): $gsd_cmd";
    }
    $out{reenter} = [ $d ? $re : $gsd_cmd ];
    $out{lines} = [ grep { defined } @out{qw(line reentry driver)} ];
    return \%out;
}

1;
