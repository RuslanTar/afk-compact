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
#   - a typed slash command: a user row that is not meta, a compact summary or a sidechain and
#     whose text starts with Claude Code's command tags (tags quoted inside a prompt are prose);
#     `/clear` forgets everything before it;
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
# commands in %NOT_WORK; `gsd-workstreams` only with switch or resume), a gsd-tools run or a
# state-file write; a gsd-tools run that only reads, in a session with no other GSD use so far and
# no driver open, is a look (a plain ask: "what phase is workstream-a at?"): it names no workstream
# of the session's own and alone gives no GSD line; once the session's own GSD work named a
# workstream, a read of another one only looks at it too ("meanwhile, what phase is B at?": it names
# nothing and moves no GSD root). Its workstream is the newest one named by
# those (`--ws <name>`, `--ws=<name>`, `gsd-workstreams switch|resume <name>`, a state-file
# write under workstreams/<name>/) or by its driver's own `--ws`, whose folder exists under a GSD
# root the session touched (the row's cwd, `--cwd`, `--repo`, a state-file write's root; GSD's own
# walk: up to the first folder holding .git, never $HOME). `--ws` on any other skill names nothing
# (a handoff or catch-up skill only looked at it); the shared .planning/active-workstream pointer
# never names one. With none named the session works flat.
# A loop skill is one of %DRIVERS, one the owner lists in the `driver_skills` setting, or a skill
# that is no GSD command but whose own text, as Claude Code loaded it into this session right after
# the invocation, runs gsd-tools in its code (a fenced block or a code span: a loop that drives GSD
# work). This plugin's own skills, other GSD commands and /loop, /goal are never one. A listed loop
# chained into a typed GSD command with `and`/`then` (`/gsd-resume-work --ws X and /<loop> <args>`)
# counts as invoked there, with its own arguments; an unlisted chained skill only through its own
# invocation.
# The driver (root ruling R1 of 2026-10-27) is the OUTERMOST loop this session invoked since its
# last /clear: a loop the model invokes through the Skill tool (or the user stacks after it in the
# same message) while the driver's own context holds (below) is that driver's own step
# (gsd-autonomous or gsd-manager running gsd-execute-phase), never a new driver, unless the driver
# is a listed loop that runs no other loop (%LEAF). Once that context ended, a GSD loop the model
# invokes for the driver's workstream (or naming none) is still that driver's step, named in its
# hint (`later step: …`), never the driver. The same loop invoked again, a loop the user types, or
# another loop the model invokes once the context ended (a superpowers loop, a GSD loop for
# another workstream) takes over.
# Whether it is Active (owner ruling 2026-10-27 20:57, binding): the imperative `Active driver:`
# line only while the loop is CLEARLY LIVE at the cut, else the `Was driving` hint. Its own context
# opens at its invocation (or re-invocation) and holds while nothing but the loop runs; the first of
# these ends it for good (only invoking the loop again opens it again):
#   - a prompt of any kind: a user row a person wrote, a command a person typed (a status look, a
#     pause, this plugin's own skills, /loop and the other Claude Code commands that start a turn;
#     not a local one such as /compact, /model or /effort), a shell command typed with `!`, or a
#     prompt Claude Code delivers inside a running turn (a queued_command attachment: a person's
#     prompt typed meanwhile, an auto-continuation, a coordinator's correction);
#   - an interruption mark ("[Request interrupted by user]", also "… for tool use");
#   - another session's message (a cross-session message, a cross-session notice, a teammate's or a
#     background agent's message that names no background work of the loop's, running or finished,
#     by its name, its id or its task id) and anything else that opens a turn and is not the loop's;
#   - a turn end (an assistant row with stop reason end_turn, or an API error that ends the turn)
#     with no agent, workflow, teammate or wake-up of its own still running;
#   - a pause (below), the checkpoint this plugin's nudge asked for saying `Step 1: none: task
#     done` (`Step 1:` on its line or the next, any dash after `none`), a single-phase loop's
#     (%STEP) own `phase.complete`, a bounded gsd-autonomous run (`--only N`, `--to N`) marking its
#     last phase complete in its context, a GSD command the model invokes after a single-phase loop,
#     and a GSD command or a gsd-tools run for a workstream not the driver's.
# Live at the cut is then: its context holds and a turn of its own runs (one of its steps is
# mid-turn), or an agent, workflow, teammate or ScheduleWakeup it launched in its context still
# runs. A turn of its own is the one its invocation runs in, or one that the notification of
# background work opens while its context holds (an agent's or workflow's task notification, a
# hand-back, its teammate's message, also one Claude Code queued while a turn ran and delivers as
# the next turn), or this plugin's auto-continue note after its compaction. Two turns are no stop:
# the turn this plugin's checkpoint nudge asked to close (the loop's step was mid-turn when the
# plugin asked; the loop goes on after the plugin's compaction), and a turn of this plugin's own
# (opened by its handoff note): the driver stays what it was. A background Bash command, a Monitor
# or a CronCreate task may be a server or a watch that outlives the loop: at a turn end the hint
# names it, never an Active line.
# Background work is the loop's when it launched it in its own context (never in a turn of this
# plugin's own): live are an Agent or Workflow until a task notification names its tool call or
# its task id, the agent hands back or a TaskStop names it; a teammate until its idle notification
# (not one sent before a SendMessage woke it), its shutdown approval, Claude Code's notice that it
# was terminated, or a TaskStop (a SendMessage that was sent sets it running again, under its own
# owner); a ScheduleWakeup until it is due. The same loop invoked again owns what it launched before.
# A pause: `/gsd-pause-work` (of the driver's workstream, or naming none; typed, invoked, or named in
# a prompt's prose: "when finished — /gsd-pause-work") pauses it once the pause's own HANDOFF.json or
# .continue-here file is written (an Edit or Write, a Bash redirect or tee into one, a commit naming
# one; never a `git rm`, `rm` or `mv` of one): before that it is `pause asked, its files not written
# yet` (and `then loop work` once a phase is begun, a GSD work command or loop step runs, or an agent
# is spawned), a request that holds until its files are written, the loop is invoked again or the
# next prompt comes (which may take it back). A loop that creates one of those files itself (a Write, a `>` redirect or a tee into
# one; not an Edit or an append, nor a commit, which a routine checkpoint or a resume consuming the
# file also makes) has paused itself. Work after a written pause (a GSD work command or loop step, a
# gsd-tools run that changes state other than a commit, a spawn, a write of a phase file, ROADMAP,
# REQUIREMENTS or PROJECT; after a later prompt only a phase file of these writes: the rest is an
# edit the person asked for) makes it `paused, then other work`; nothing a turn or a skill of this
# plugin's own does (its resume reconciling STATE.md, its handoff) ever counts. Only invoking the
# loop again ends a pause (R4: a resume shows the re-entry command of a paused loop, never runs it).
# It has ended after a finishing skill (%FINISH), a GSD work command for another workstream, or, for
# a single-phase loop, a GSD work command the user typed. While it was invoked with arguments that
# cannot be shown, none of them kept for its re-enter command, and no GSD work of its workstream
# followed, it is at most a hint (it may never have started).
# Which workstream: a driver with no workstream of its own takes the first one its own loop work
# names in its context; one named once that context ended is another workstream's work, and its
# re-enter command never gets a --ws its loop work did not name, nor a --cwd: its GSD root is the
# newest its own loop work used in its context (a read never moves it; R3), else the one its
# invocation names (or its folder's), else this checkout's.
# Only an Active driver gets an `Active driver:` line (the resume protocol's [driver] re-entry keys
# on it, and only that line is ever run); a paused one gets `Paused driver:` (re-enter in a new
# session only), any other the weaker `Was driving: … · re-enter only if Step 1 belongs to it: …`
# hint, an ended one no line; a GSD loop whose GSD root is another checkout whose path cannot be
# passed as a plain --cwd (a space, a non-ASCII letter) is at most that hint (R3: its command would
# run in this checkout). A flat GSD re-enter command beside the shared .planning/active-workstream
# pointer carries a caution in every form (GSD sends it to that workstream). A session that used GSD
# with no active GSD-command driver also gets a passive `GSD re-entry` line (with a caution for such
# a root).
use strict;
use warnings;
use utf8;

our $SCAN_MS = 1500;                  # one scan's time budget; a scan over it reads `not measured (timeout)`
our $ROW_MAX = 4 * 1024 * 1024;       # a longer row is never decoded
our $WS_KEEP = 8;                     # newest workstream names kept
our $ROOTS_KEEP = 8;                  # newest GSD roots kept
our $LOOPS_KEEP = 32;                 # skill names kept whose text runs gsd-tools
our $ARGS_MAX = 100;                  # longer arguments are not shown
our $LINE_MAX = 400;                  # characters of the GSD line (the driver line is never cut: its
                                      # parts are bounded, and a cut would break a re-enter command)
our $CACHE = 'gsd-scan.json';         # <watch>/<sid>/: read offset and facts so far
our $CACHE_V = 13;
our $BG_KEEP = 32;                    # newest background tasks kept while no notification names them
our %DRIVERS = map { $_ => 1 } qw(gsd-autonomous gsd-execute-phase gsd-manager
                                  superpowers:executing-plans superpowers:subagent-driven-development);
# A listed loop that runs one phase: what follows it is often its own step hook, its auto-advance or
# the session moving on, which the transcript does not tell apart.
our %STEP = map { $_ => 1 } qw(gsd-execute-phase);
# Listed loops that run no other loop: another loop invoked after one of them takes over (R1).
our %LEAF = map { $_ => 1 } qw(gsd-execute-phase superpowers:executing-plans superpowers:subagent-driven-development);
# gsd-tools runs that only read planning state (`<verb>.<sub>`, or a verb all of whose runs read).
our %READ_VERB = map { $_ => 1 } qw(state state.load state.get state.json state.snapshot roadmap.analyze
                                    roadmap.get-phase phase.next frontmatter.get);
our %READ_BASE = map { $_ => 1 } qw(init progress stats state-snapshot find-phase phase-plan-index list-todos
                                    list-seeds history-digest summary-extract verify verify-summary verification
                                    validate audit-uat audit-open);
# GSD status commands that only look at a workstream: their --ws, and that of the reads they run
# before the next prompt, never names the session's own (a loop typed after one is not bound to it).
our %LOOK = map { $_ => 1 } qw(gsd-progress gsd-stats);
# Skills that close a loop's work.
our %FINISH = map { $_ => 1 } qw(superpowers:finishing-a-development-branch gsd-complete-milestone);
# GSD commands that show or resume the position and change no work.
our %STATUS = map { $_ => 1 } qw(gsd-progress gsd-resume-work gsd-workstreams gsd-stats);
our %NOT_WORK = map { $_ => 1 } qw(gsd-help gsd-settings gsd-config gsd-update gsd-health);
# Claude Code's own commands: never a skill, never a chained loop.
our %BUILTIN = map { $_ => 1 } qw(clear compact loop goal model effort resume config help exit quit context cost
                                  status memory init review login logout permissions hooks agents mcp plugin
                                  plugins doctor add-dir export rewind fork btw usage);
# Those of them that start a turn of the model's when typed: a prompt (the others are local).
our %TURN_BUILTIN = map { $_ => 1 } qw(loop goal review init resume rewind fork);
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

# The parts of arguments that cannot be shown which a re-enter command keeps, in their order:
# `--ws <name>`, a `resume` word, and `--repo` / `--cwd` with a plain absolute path.
sub _keep {
    my ($a) = @_;
    return '' unless defined $a && !ref $a;
    my @t = split /\s+/, $a;
    my @k;
    for (my $i = 0; $i < @t; $i++) {
        my ($k, $v);
        if ($t[$i] eq 'resume') { push @k, 'resume'; next }
        if ($t[$i] =~ /\A--(ws|repo|cwd)=(.+)\z/) { ($k, $v) = ($1, $2) }
        elsif ($t[$i] =~ /\A--(ws|repo|cwd)\z/ && $i + 1 < @t) { ($k, $v) = ($1, $t[++$i]) }
        else { next }
        $v =~ s/\A(['"])(.*)\1\z/$2/;
        push @k, "--$k $v" if $k eq 'ws' ? $v =~ /\A$WS\z/ : $v =~ $PLAIN_PATH;
    }
    return join(' ', @k);
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

# bash_calls(command) -> [{verb, sub, n, ws, cwd}…]: the gsd-tools runs of one Bash command that read
# or change planning state (sub: the part after the verb's dot, else its first plain word).
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
        my $s = $sub // ($rest =~ /\A[ \t]+([a-z][a-z-]*)(?=[ \t]|\z)/ ? $1 : undef);
        $e{sub} = $s if defined $s;
        # the phase number it names first (`phase complete 3`, `phase.complete 3`)
        my $r = $rest;
        $r =~ s/\A[ \t]+\Q$s\E(?=[ \t]|\z)// if defined $s && !defined $sub;
        $e{n} = $1 if defined $s && $r =~ /\A[ \t]+([0-9]+(?:\.[0-9]+)*)(?=[ \t]|\z)/;
        $e{ws} = $2 if $rest =~ /(?:\A|\s)--ws(?:[ \t]+|=)(['"]?)($WS)\1(?![A-Za-z0-9._-])/;
        $e{cwd} = $2 if $rest =~ /(?:\A|\s)--cwd(?:[ \t]+|=)(['"]?)(\/[^'"\s;&|]+)\1/;
        push @out, \%e;
    }
    return \@out;
}

# Whether a gsd-tools run only reads planning state.
sub _read_run {
    my ($b) = @_;
    my ($base) = $b->{verb} =~ /\A([^.]+)/;
    return 1 if $READ_BASE{$base};
    return $READ_VERB{ defined $b->{sub} ? "$base.$b->{sub}" : $base } ? 1 : 0;
}

# look: named only by a status look (%LOOK); it names the session's workstream only while no other
# GSD work followed it.
sub _push_ws {
    my ($st, $name, $root, $ts, $seq, $look) = @_;
    return unless defined $name && $name =~ /\A$WS\z/ && $name ne 'none';
    my $same = sub { $_[0]{name} eq $name && ($_[0]{root} // '') eq ($root // '') };
    $look = 0 if grep { $same->($_) && !$_->{look} } @{ $st->{ws} || [] };    # named by work before
    my @w = grep { !$same->($_) } @{ $st->{ws} || [] };
    push @w, { name => $name, root => $root, ts => $ts, seq => $seq // $st->{seq} // 0, ($look ? (look => 1) : ()) };
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
our $DN;    # the listed loop names during one scan (driver_names(), or the caller's)

sub _wsn { my ($w) = @_; return undef unless defined $w; $w =~ s/\.+\z//; return $w }

# The driver (see the header). $st->{drv} = {e => the invocation it re-enters, mode => active |
# paused | ended, ws => its workstream (its own --ws, else the one the session had named, else the
# first its own loop work names), flat => it has none, and a workstream named once its context
# ended is another's, work => GSD work of that workstream followed it, root => its GSD root, id =>
# its own number (its background work's owner), lv => its own context holds (1 from its
# invocation, 0 for good once anything else happened), mt => a turn of its own runs, why => what
# ended its context, step => the GSD loop it ran as its step once its context had ended, pause =>
# {seq, ts, done => its files were written, self => it paused itself}, after => work after the
# pause, own => a turn of this plugin's own runs, oskill => one of this plugin's skills ran inside
# the loop's turn (until that turn ends), nudged / nmid => the turn this plugin's checkpoint nudge
# asked to close, and the message that closed it}.
sub _start {
    my ($st, $e) = @_;
    my $D = $st->{drv};
    my $open = ($D && $D->{mode} ne 'ended') ? 1 : 0;
    if ($open && $D->{e}{name} ne $e->{name} && ($e->{via} ne 'typed' || $e->{stacked}) && !$LEAF{ $D->{e}{name} }) {
        # R1: a loop the model invokes (or the user stacked after it in the same message) in the
        # driver's own context is that driver's step, unless the driver runs no other loop.
        if ($D->{mode} eq 'active' && $D->{lv}) { $D->{mt} = 1; return }
        # R1 once that context ended (a prompt, a pause asked, a stop): a GSD loop for the driver's
        # workstream (or naming none) is still its step (gsd-manager's typed choice, then its
        # gsd-execute-phase), named in the hint so the session sees which step it was in; never the
        # driver, never Active (owner 20:57).
        my $pend = ($D->{mode} eq 'paused' && !$D->{pause}{done}) ? 1 : 0;
        my $ws = _wsn($e->{ws});
        if (($D->{mode} eq 'active' || $pend) && $e->{name} =~ /\Agsd-/ && (!defined $ws || !defined $D->{ws} || $ws eq $D->{ws})) {
            $D->{step} = { map { defined $e->{$_} ? ($_ => $e->{$_}) : () } qw(via name args hidden keep ws root) };
            $D->{after} = 1 if $pend && !_plug($D);
            return;
        }
    }
    my $ws = _wsn($e->{ws});
    my $same = $D && $D->{e}{name} eq $e->{name};
    $ws //= $D->{ws} if $same;
    if (!defined $ws) { my ($w) = grep { !$_->{look} } reverse @{ $st->{ws} || [] }; $ws = _wsn($w->{name}) if $w }
    my $root = _gsd_root($e->{root}) // ($same ? $D->{root} : undef);
    my $N = { e => { %$e }, mode => 'active', ws => $ws, work => 0, id => $e->{seq} // 0, lv => 1, mt => 1,
              (defined $root ? (root => $root) : ()) };
    # (the turn this plugin's checkpoint nudge asked to close stays that turn)
    if ($open) { $N->{$_} = $D->{$_} for grep { defined $D->{$_} } qw(nudged nmid) }
    $st->{drv} = $N;
    $st->{wseq} = $e->{seq};
    # The same loop invoked again (its re-entry after a compaction) still owns the background work
    # it launched before; another loop does not.
    if ($same && $open) {
        for my $x (values %{ ref $st->{bg} eq 'HASH' ? $st->{bg} : {} }, values %{ ref $st->{bgend} eq 'HASH' ? $st->{bgend} : {} }) {
            $x->{d} = $N->{id} if ref $x eq 'HASH' && ($x->{d} // -1) == ($D->{id} // -2);
        }
    }
}

# The driver's own context ends (owner 2026-10-27 20:57: Active only while the loop is clearly
# live): from here on it is at most a `Was driving` hint, until the loop is invoked again. why: the
# first such event, its time, then tail.
sub _kill {
    my ($D, $why, $ts, $tail) = @_;
    return unless $D && $D->{mode} ne 'ended';
    delete $D->{mt};
    return unless $D->{lv};
    $D->{lv} = 0;
    $D->{why} = $why . ($ts ? ' ' . util::stamp($ts) : '') . ($tail // '');
}

# The driver's GSD root from its own loop work (dir: where that work ran).
sub _droot {
    my ($D, $dir) = @_;
    my $r = _gsd_root($dir);
    $D->{root} = $r if defined $r;
}

# What this plugin does (a turn of its own, or one of its skills the model ran inside the loop's
# turn): never the loop's work.
sub _plug {
    my ($D) = @_;
    return ($D->{own} || $D->{oskill}) ? 1 : 0;
}

# The loop's own work (no plugin turn or skill runs it) in its own context.
sub _mine {
    my ($D) = @_;
    return ($D && $D->{mode} eq 'active' && $D->{lv} && !_plug($D)) ? 1 : 0;
}

# Whether a gsd-tools run begins new work (a phase begun), as against the progress records of
# work that was running (a pause asked "when finished" holds against those).
sub _new_work {
    my ($b) = @_;
    my ($base) = $b->{verb} =~ /\A([^.]+)/;
    return ($base eq 'state' && ($b->{sub} // '') eq 'begin-phase') ? 1 : 0;
}

# The driver's background work at time ts: (live, loose). live: an agent, workflow or teammate or a
# ScheduleWakeup (before it is due) it launched still runs. loose: what else of its own still runs
# (a background command, a Monitor, persistent or one that times out before its time is up, a
# scheduled task): it may outlive the loop or only watch (a server, a stall watch while the loop
# waits for the user), so it never keeps the driver Active.
sub _running {
    my ($st, $D, $ts) = @_;
    my $bg = $st->{bg};
    return (0, undef) unless ref $bg eq 'HASH';
    my ($live, %loose) = (0);
    for my $k (keys %$bg) {
        my $x = $bg->{$k};
        next unless ref $x eq 'HASH' && defined $x->{d} && defined $D->{id} && $x->{d} == $D->{id};
        if (defined $x->{u} && defined $ts && $ts > $x->{u}) { delete $bg->{$k}; next }    # its time is up
        my $kd = $x->{k} // 'a';
        if ($kd eq 'a' || $kd eq 'w') { $live = 1 }
        else { $loose{ $kd eq 'm' ? 'monitor' : $kd eq 'c' ? 'scheduled task' : 'background command' } = 1 }
    }
    my @l = sort keys %loose;
    return ($live, @l ? join(' or ', @l) : undef);
}

# A pause of the driver (e: {seq, ts}; done: its files are written; self: the loop paused itself).
# Its context ends; only invoking the loop again ends the pause.
sub _pause {
    my ($D, $e, $done, $self) = @_;
    $D->{mode} = 'paused';
    $D->{lv} = 0;
    delete @$D{qw(after mt)};
    $D->{pause} = { seq => $e->{seq}, ts => $e->{ts}, ($done ? (done => 1) : ()), ($self ? (self => 1) : ()) };
}

# A row that opens a turn, for the open driver: 'loop' (the notification of background work, this
# plugin's auto-continue note: a turn of the loop's own while its context holds), 'plugin' (a turn of
# this plugin's own: the driver stays what it was), or 'stop' (a turn that is not the loop's, why:
# its context ends). No turn of this plugin's own, plugin skill or nudged checkpoint carries over
# from an earlier turn (one cut off has no end row).
sub _opened {
    my ($st, $kind, $ts, $why) = @_;
    my $D = $st->{drv};
    return unless $D && $D->{mode} ne 'ended';
    delete @$D{qw(own oskill nudged nmid)};
    if ($kind eq 'loop') { $D->{mt} = 1 if $D->{lv} }
    elsif ($kind eq 'plugin') { $D->{own} = 1 }
    else { _kill($D, $why, $ts) }
}

# A prompt (a person's row or typed command; mid: one Claude Code delivers inside the running
# turn): the driver's context ends (owner 20:57: a later prompt of any kind gives the hint).
sub _prompt {
    my ($st, $ts, $why, $mid) = @_;
    delete $st->{look};
    my $D = $st->{drv};
    return unless $D && $D->{mode} ne 'ended';
    delete @$D{qw(own oskill nudged nmid)} unless $mid;
    $why = ($why // 'a prompt') . ($ts ? ' ' . util::stamp($ts) : '');
    if ($D->{mode} eq 'paused' && !$D->{pause}{done}) {
        # A pause asked for whose files are not written yet holds only until the next prompt (which
        # may take it back or ask for something else): from here the loop is a plain hint.
        @$D{qw(mode lv)} = ('active', 0);
        delete @$D{qw(pause after mt)};
        $D->{why} //= $why;
        return;
    }
    # (after a pause, the person's own edits never make it `then other work`: _drv_write)
    $D->{pause}{prompted} = 1 if $D->{mode} eq 'paused';
    _kill($D, $why);
}

# A human prompt that names /gsd-pause-work in prose ("let the executor finish, then
# /gsd-pause-work"): the pause asked for, as the typed command (a hint until its files are written),
# unless it names another workstream than the driver's.
sub _prose_pause {
    my ($st, $t, $ts) = @_;
    my $D = $st->{drv} or return;
    return unless $D->{mode} eq 'active';
    return unless defined $t && $t =~ m~(?:\A|[\s(\[{"'`*_>])/gsd[-:]pause-work(?![A-Za-z0-9_-])([^\n]*)~;
    my $cw = _wsn(_ws_from_args('gsd-pause-work', $1));
    return if defined $cw && defined $D->{ws} && $cw ne $D->{ws};
    _pause($D, { seq => $st->{seq} // 0, ts => $ts });
}

# One of this plugin's own submitted notes (_note): the auto-continue note opens the loop's next
# turn; a handoff note opens a turn of the plugin's own, whose end is no stop.
sub _own_note {
    my ($st, $kind) = @_;
    _opened($st, $kind eq 'turn' ? 'plugin' : 'loop');
}

# A GSD command (typed or through the Skill tool), not the driver itself.
sub _drv_cmd {
    my ($st, $e) = @_;
    my $D = $st->{drv} or return;
    return if $D->{mode} eq 'ended' || $D->{e}{name} eq $e->{name};
    my ($n, $cw, $dw) = ($e->{name}, _wsn($e->{ws}), $D->{ws});
    if ($n eq 'gsd-pause-work') {
        _pause($D, $e) if !defined $cw || !defined $dw || $cw eq $dw;
        return;
    }
    my $mine = _mine($D);
    # A driver with no workstream takes the first one its own loop work names (a GSD work command
    # in its context); one a command names once that context ended is another workstream's work, and
    # so is any named after that. A status look names none.
    if (defined $cw && !defined $dw && !$STATUS{$n}) {
        if ($mine && !$D->{flat}) { $D->{ws} = $dw = $cw }
        else {
            $D->{flat} = 1;
            return _kill($D, 'a GSD command for a workstream it never named followed', $e->{ts});
        }
    }
    if (defined $cw && defined $dw && $cw ne $dw) {
        return _kill($D, 'a GSD command for another workstream followed', $e->{ts}) if $STATUS{$n};
        $D->{mode} = 'ended';
        return;
    }
    # (work after a pause; nothing a turn or a skill of this plugin's own does: R4)
    if ($D->{mode} eq 'paused') { $D->{after} = 1 unless $STATUS{$n} || _plug($D); return }
    $D->{work} = 1;
    return if $STATUS{$n};
    _droot($D, $e->{root}) if $mine;
    if ($e->{via} eq 'typed' && !$e->{stacked}) {
        # (a typed command is a prompt already)
        $D->{mode} = 'ended' if $STEP{ $D->{e}{name} };
    } elsif ($STEP{ $D->{e}{name} }) {
        # its own step hook, its auto-advance or the session moving on: unclear
        _kill($D, 'another GSD command followed', $e->{ts});
    }
}

# A gsd-tools state run.
sub _drv_tool {
    my ($st, $b, $ts, $dir) = @_;
    my $D = $st->{drv} or return;
    return if $D->{mode} eq 'ended';
    my $mine = _mine($D);
    my $read = _read_run($b);
    my ($cw, $dw) = (_wsn($b->{ws}), $D->{ws});
    # A driver with no workstream takes the first one its own loop work names (not a status look's
    # reads); one a run that changes state names once its context ended is another workstream's.
    if (defined $cw && !defined $dw) {
        if ($mine && !$D->{flat} && !($st->{look} && $read)) { $D->{ws} = $dw = $cw }
        elsif (!$read) { $D->{flat} = 1 }
    }
    return _kill($D, 'gsd-tools ran for another workstream', $ts)
        if defined $cw && (defined $dw ? $cw ne $dw : $D->{flat} && !$read);
    if ($D->{mode} eq 'paused') {
        # (the pause's own commit and reads are no work after it, nor anything of this plugin's
        # own, R4; a pause asked for holds against the progress records of the work the person
        # said to finish: only new work counts)
        $D->{after} = 1 if !$read && !_plug($D) && $b->{verb} !~ /\Acommit(?:\.|-|\z)/ && ($D->{pause}{done} || _new_work($b));
        return;
    }
    $D->{work} = 1;
    # (a read never moves the driver's GSD root, nor anything outside its context: R3)
    _droot($D, $dir) if $mine && !$read;
    # A single-phase loop's own completion (GSD's execute-phase runs it last).
    my $pc = ($b->{verb} =~ /\Aphase\z|\Aphase\.complete\z/ && ($b->{sub} // '') eq 'complete') ? 1 : 0;
    _kill($D, 'its phase was marked complete', $ts) if $pc && $STEP{ $D->{e}{name} };
    # A bounded run's own end (a loop that finished is not Active): gsd-autonomous with `--only N`
    # or `--to N` marked phase N complete in its context.
    if ($pc && $mine && defined $b->{n} && $D->{e}{name} eq 'gsd-autonomous') {
        my $last = _last_phase($D->{e}{args} // $D->{e}{keep});
        _kill($D, "its last phase ($last) was marked complete", $ts) if defined $last && _same_phase($last, $b->{n});
    }
}

# The last phase a bounded gsd-autonomous run names (`--only N`, `--to N`), or undef.
sub _last_phase {
    my ($a) = @_;
    return undef unless defined $a && !ref $a;
    return $2 if $a =~ /(?:\A|\s)--(only|to)(?:\s+|=)([0-9]+(?:\.[0-9]+)*)(?![A-Za-z0-9._-])/;
    return undef;
}

# Whether two phase numbers are the same (leading zeros aside: 03 and 3).
sub _same_phase {
    my ($x, $y) = @_;
    my @x = split /\./, $x;
    my @y = split /\./, $y;
    return 0 unless @x == @y;
    for my $i (0 .. $#x) { return 0 unless $x[$i] =~ /\A[0-9]+\z/ && $y[$i] =~ /\A[0-9]+\z/ && 0 + $x[$i] == 0 + $y[$i] }
    return 1;
}

# A state-file write (rel: the path under .planning/; tool: Edit, Write, …).
sub _drv_write {
    my ($st, $ws, $rel, $ts, $tool, $root) = @_;
    my $D = $st->{drv} or return;
    return if $D->{mode} eq 'ended';
    my ($cw, $dw) = (_wsn($ws), $D->{ws});
    return if defined $cw && defined $dw && $cw ne $dw;
    # A pause's own files: the asked-for pause took place, or the loop created one to pause itself
    # (an Edit of an existing one is a checkpoint note, no pause).
    if ($rel =~ m{(?:\A|/)(?:HANDOFF\.json|\.continue-here[^/]*)\z}) {
        if ($D->{mode} eq 'paused') {
            if (!$D->{pause}{done}) { $D->{pause}{done} = 1; delete $D->{after} }
            # (a loop that paused, then went on, creates one again: it paused again, from here on)
            elsif ($D->{after} && ($tool // '') eq 'Write') { @{ $D->{pause} }{qw(seq ts)} = ($st->{seq}, $ts); delete $D->{after} }
        }
        elsif (($tool // '') eq 'Write') { _pause($D, { seq => $st->{seq}, ts => $ts }, 1, 1) }
        return;
    }
    if ($D->{mode} eq 'paused') {
        # (STATE.md is the pause's own bookkeeping; a pause asked for holds against the files of the
        # work the person said to finish; after a later prompt only a phase file is work after it,
        # the rest an edit the person asked for; nothing of this plugin's own, R4)
        $D->{after} = 1 if $D->{pause}{done} && $rel !~ m{(?:\A|/)STATE\.md\z} && !_plug($D)
                           && (!$D->{pause}{prompted} || $rel =~ m{(?:\A|/)phases/});
        return;
    }
    $D->{work} = 1;
    _droot($D, $root) if _mine($D);
}

my $PAUSE_FILE = qr{(?:HANDOFF\.json|\.continue-here)};

# The end of an assistant turn (err: an API error ended it): with none of the driver's agents,
# workflows, teammates or wake-ups live, its context ends; never the end of a turn of this plugin's
# own, nor of the turn this plugin's checkpoint nudge asked to close.
sub _turn_end {
    my ($st, $ts, $mid, $err) = @_;
    # one assistant message is written as several rows (thinking, text): its turn ends once
    return if defined $mid && defined $st->{lastend} && $mid eq $st->{lastend};
    $st->{lastend} = $mid;
    my $D = $st->{drv} or return;
    return if $D->{mode} eq 'ended';
    delete $D->{oskill};
    if (!$err) {
        # a turn of this plugin's own (its handoff turn, a skill of its own the person typed): the
        # driver stays what it was
        if (delete $D->{own}) { delete @$D{qw(nudged nmid)}; return }
        # the turn the plugin's checkpoint nudge closed: the loop goes on after the plugin's
        # compaction (unless that checkpoint says the task is done: _row reads it)
        if (delete $D->{nudged}) { $D->{nmid} = $mid // ''; return }
    }
    delete @$D{qw(own nudged nmid mt)};
    return unless $D->{lv};
    my ($live, $loose) = _running($st, $D, $ts);
    return if $live;
    _kill($D, $err ? 'its turn stopped on an API error' : 'its turn ended', $ts,
          defined $loose ? " with only a $loose still running" : ' with nothing of its own running');
}

# Whether a Bash command writes or commits a pause's own files (HANDOFF.json, .continue-here*):
# a redirect or tee into one, or a commit or `git add` naming one; never a command that removes
# or moves one (`git rm`, `rm`, `mv`: a resume consuming the handoff).
sub _pause_write {
    my ($c) = @_;
    return 0 unless defined $c && !ref $c && $c =~ $PAUSE_FILE;
    return 0 if $c =~ m{(?:\A|[\s;&|(])(?:git[ \t]+)?(?:rm|mv)[ \t][^\n;&|]*$PAUSE_FILE};
    return 1 if $c =~ m{(?:>>?|\btee(?:[ \t]+-a)?)[ \t]*["']?[^\s;&|<>"']*$PAUSE_FILE};
    return 1 if $c =~ m{\b(?:add|commit)\b[^\n]*$PAUSE_FILE};
    return 0;
}

# Whether a Bash command creates one of a pause's own files, of the driver's workstream (dw) or of
# none: a `>` redirect or a tee (not `>>`, `tee -a`, a commit or `git add`, which a routine
# checkpoint or a resume consuming the file also makes), outside quoted text.
sub _self_pause {
    my ($c, $dw) = @_;
    return 0 unless _pause_write($c);
    my $F = qr{[^\s;&|<>"'`]*(?:HANDOFF\.json|\.continue-here[^\s;&|<>"'`]*)};
    (my $u = $c) =~ s/<<-?[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1([^\n]*)\n.*?\n[ \t]*\2[ \t]*(?=\n|\z)/<<$2$3/gs;
    $u = _unquote_paths($u);
    my $hit = $u =~ m{(?:(?<![>&0-9])>(?![>&])|\btee(?![ \t]+-a\b))[ \t]*["']?($F)} ? $1 : undef;
    return 0 unless defined $hit;
    return 0 if defined $dw && $hit =~ m{workstreams/($WS)/} && _wsn($1) ne $dw;
    return 1;
}

# Quoted text blanked except a span that is only a path (a redirect target in quotes stays).
sub _unquote_paths {
    my ($c) = @_;
    $c =~ s{("(?:[^"\\]|\\.)*"|'[^']*')}{ my $q = $1; $q =~ m{\A(["'])[^\s"'|;&<>`]*\1\z} ? $q : 'Q' }gse;
    return $c;
}

# The skill text Claude Code loads right after an invocation (a meta row that starts `Base
# directory for this skill: <dir>`, the folder named as the skill; the invocation's arguments
# follow as `ARGUMENTS: …` and do not count): a text whose code (a fenced block or a code span)
# runs gsd-tools makes that skill a loop that drives GSD (it is not a GSD command itself). A text
# that only names gsd-tools in prose does not.
sub _skill_text {
    my ($st, $l) = @_;
    my $e = $st->{last} // return;
    return unless index($l, 'gsd_run') >= 0 || index($l, 'gsd-tools') >= 0;
    return if length($l) > $ROW_MAX;
    my $j = eval { jsonc::decode($l) };
    return unless ref $j eq 'HASH' && $j->{isMeta} && !$j->{isSidechain} && ref $j->{message} eq 'HASH';
    my $c = $j->{message}{content};
    my $t = !ref $c ? ($c // '')
          : ref $c eq 'ARRAY' ? join("\n", map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @$c) : '';
    my ($dir) = $t =~ m{\A\s*Base directory for this skill: ([^\n]+)} or return;
    my $cut = rindex($t, "\nARGUMENTS: ");
    $t = substr($t, 0, $cut) if $cut >= 0;
    return unless _runs_gsd($t);
    $dir =~ s{[/\s]+\z}{};
    my $n = $e->{name};
    (my $base = $n) =~ s/\A[^:]*://;
    return unless lc(util::basename($dir)) eq $base;
    delete $st->{last};
    my $lp = $st->{loops} ||= {};
    $lp->{$n} = ++$st->{seq};
    if (keys %$lp > $LOOPS_KEEP) { my ($old) = sort { $lp->{$a} <=> $lp->{$b} } keys %$lp; delete $lp->{$old} }
    _start($st, $e);
}

# Whether a skill text's code runs gsd-tools: its fenced blocks, then its code spans, each read as
# a shell command (bash_calls).
sub _runs_gsd {
    my ($t) = @_;
    return 0 unless index($t, 'gsd_run') >= 0 || index($t, 'gsd-tools') >= 0;
    my @code;
    $t =~ s{^[ \t]*(```|~~~)[^\n]*\n(.*?)^[ \t]*\1[ \t]*$}{ push @code, $2; '' }gmse;
    push @code, $1 while $t =~ /`([^`\n]+)`/g;
    for (@code) { return 1 if @{ bash_calls($_) } }
    return 0;
}

# This plugin's own skills (handoff, resume, report, status) are one-shot.
sub _own {
    my ($name) = @_;
    my $b = lc(eval { ctx::brand() } // '');
    return $b ne '' && index($name, "$b:") == 0 ? 1 : 0;
}

# Arguments of a chained skill: up to the line end or the next `and`/`then` connector.
sub _chain_args {
    my ($rest) = @_;
    $rest =~ s/\n.*\z//s;
    $rest =~ s/(?:\A|[ \t,;])(?:and|then)[ \t]+.*\z//s;
    $rest =~ s/\A[\s.,;:!?]+|[\s.,;:!?]+\z//g;
    return $rest;
}

sub _is_loop {
    my ($st, $name) = @_;
    return ($DN && $DN->{$name}) || (ref $st->{loops} eq 'HASH' && $st->{loops}{$name}) ? 1 : 0;
}

# One typed command or Skill call. stacked: a command the user typed after another in the same
# message (`/loop /gsd-plan-phase 1`), which Claude Code writes as a row of its own
# (stackedExpansion): it goes with the command before it.
sub _invoked {
    my ($st, $via, $raw, $args, $cwd, $ts, $stacked) = @_;
    my $name = _norm($raw);
    return unless $name =~ /\A[a-z0-9][a-z0-9:._-]*\z/;
    if ($via eq 'typed' && $name eq 'clear') { %$st = (); return }
    delete $st->{last};
    my $typed = ($via eq 'typed' && !$stacked) ? 1 : 0;
    # A command a person typed is a prompt (owner 20:57: a later prompt of any kind), a status look,
    # a pause and this plugin's own skills too; of Claude Code's own commands only those that start
    # a turn (/loop, /goal, …), not a local one (/compact, /model, …).
    if ($BUILTIN{$name}) {
        _prompt($st, $ts) if $typed && $TURN_BUILTIN{$name};
        return;
    }
    _prompt($st, $ts) if $typed;
    my $own = _own($name);
    delete $st->{look} unless $own;
    my $shown = _args($args);
    my $ws = _ws_from_args($name, $args);
    my $named = _root_from_args($args);
    my $root = $named // $cwd;
    my %e = (via => $via, name => $name, args => $shown, hidden => (defined $shown ? 0 : 1), ts => $ts,
             seq => ++$st->{seq}, root => $root);
    $e{ws} = $ws if defined $ws;
    $e{keep} = _keep($args) unless defined $shown;
    $e{stacked} = 1 if $stacked;
    my $gsd = _is_gsd_cmd($name, $args);
    if ($gsd) {
        $st->{gsd} = { %e };
        _push_root($st, $root);
        if ($LOOK{$name}) { $st->{look} = 1 } else { $st->{wseq} = $e{seq} }
    } elsif (defined $named && defined $ws && !$own) {
        _push_root($st, $named);    # where a loop's --ws resolves
    }
    if ($FINISH{$name}) {
        $st->{drv}{mode} = 'ended' if $st->{drv};
    } elsif ($gsd) {
        _drv_cmd($st, \%e);
    }
    _push_ws($st, $ws, $root, $ts, $e{seq}, $LOOK{$name}) if $gsd;
    if ($own) {
        # One of this plugin's skills (its resume, its handoff). Typed by the person: the rest of the
        # turn is the plugin's, not the loop's (its STATE.md reconcile, its Step 1 agents). Run by
        # the model inside the loop's own turn (a handoff before going idle): its writes are not loop
        # work, but the turn's end is the loop's, and background work started after it is the loop's.
        my $D2 = $st->{drv};
        if ($D2 && $D2->{mode} ne 'ended') {
            if ($typed) { $D2->{own} = 1 } elsif (!$D2->{own}) { $D2->{oskill} = 1 }
        }
        return;
    }
    return if $NOT_WORK{$name};
    if (_is_loop($st, $name)) { _start($st, \%e) }
    elsif ($name !~ /\Agsd-/) { $st->{last} = { %e } }    # its skill text comes next (_skill_text)
    # The owner's form `/gsd-resume-work --ws X and /<loop> <args>`: the first skill chained with
    # `and` or `then` on the same line into a typed GSD command that names a workstream, with its
    # own arguments; it drives only when it is a loop already (listed, or its text was seen). A
    # skill on a line of its own, after the first, or after a GSD command without a workstream is
    # not chained.
    if ($gsd && $via eq 'typed' && defined $ws && defined $args && !ref $args) {
        while ($args =~ m{(?:\A|[ \t,;])(?:and|then)[ \t]+/([a-z][a-z0-9:._-]*?)(?=[\s,;!?)]|\.(?:\s|\z)|\z)}g) {
            my $n = _norm($1);
            next if $BUILTIN{$n} || $NOT_WORK{$n} || $n eq $name || _own($n) || ($n =~ /\Agsd-/ && !$DRIVERS{$n});
            last unless _is_loop($st, $n);
            my $ca = _chain_args(substr($args, pos($args)));
            my $cs = _args($ca);
            my %c = (via => 'typed', name => $n, args => $cs, hidden => (defined $cs ? 0 : 1), ts => $ts,
                     seq => ++$st->{seq}, root => _root_from_args($ca) // $root, chained => 1);
            $c{keep} = _keep($ca) unless defined $cs;
            $c{ws} = _ws_from_args($n, $ca) // $ws;
            _start($st, \%c);
            last;
        }
    }
}

# The text of a message's content (a string, or its text parts).
sub _text {
    my ($c) = @_;
    return !ref $c ? ($c // '')
         : ref $c eq 'ARRAY' ? join("\n", map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @$c) : '';
}

sub _row {
    my ($st, $j, $cwd0) = @_;
    return unless ref $j eq 'HASH' && !$j->{isSidechain};
    my $type = $j->{type} // '';
    my $ts = util::parse_iso($j->{timestamp} // '');
    my $cwd = (defined $j->{cwd} && !ref $j->{cwd} && $j->{cwd} ne '') ? $j->{cwd} : $cwd0;
    my $c = ref $j->{message} eq 'HASH' ? $j->{message}{content} : undef;
    if ($type eq 'user') {
        delete $st->{ntfhit};
        _bg_user($st, $j, $c, $ts) if ($st->{drv} && ($st->{drv}{mode} // '') ne 'ended') || (ref $st->{bg} eq 'HASH' && %{ $st->{bg} });
        my $t = _text($c);
        my $o = ref $j->{origin} eq 'HASH' ? $j->{origin} : undef;
        # (the notification of the loop's own background work: this row's, or a queued one it delivers)
        my $mine = ($st->{ntfhit} || $st->{ntfq}) ? 1 : 0;
        if ($j->{isMeta}) {
            # Rows Claude Code writes as meta that open a turn: a background agent's hand-back or
            # message (the loop's own when it names the loop's agent; a hand-back is a notification
            # either way), another session's message or a cross-session notice (never the loop's).
            if ((($o && ($o->{kind} // '') eq 'peer') || $t =~ /\A\s*\[Cross-session /) && !$j->{isCompactSummary}) {
                $mine ||= $o ? _own_sender($st, @$o{qw(senderTaskId from)}) : 0;
                if ($mine || ($o && $o->{handback})) { _opened($st, 'loop', $ts) }
                else { _opened($st, 'stop', $ts, "another session's message") }
                delete $st->{ntfq};
            }
            delete $st->{ntfhit};
            return;
        }
        return if $j->{isCompactSummary} || $j->{isVisibleInTranscriptOnly};
        my $tr = (ref $c eq 'ARRAY' && grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'tool_result' } @$c) ? 1 : 0;
        # Claude Code writes a typed command as the row's whole text, starting with its tags; tags
        # anywhere else are quoted in a prompt.
        if ($t =~ m{\A\s*<command-(?:message|name)>} && $t =~ m{<command-name>/?([^<\s]+)</command-name>(?:\s*<command-args>(.*?)</command-args>)?}s) {
            delete $st->{ntfq} unless $j->{stackedExpansion};
            _invoked($st, 'typed', $1, $2, $cwd, $ts, $j->{stackedExpansion} ? 1 : 0);
        } elsif ($tr || $t !~ /\S/ || $t =~ /\A\s*<(?:local-command-(?:stdout|stderr)|bash-(?:stdout|stderr))>/) {
            # a tool result; the output of a command the person ran (it opens no turn)
        } elsif (_human($j, $t)) {
            delete $st->{ntfq};
            _prompt($st, $ts);
            _prose_pause($st, $t, $ts);
        } elsif (my $nk = _note($t)) {
            delete $st->{ntfq};
            _own_note($st, $nk);
        } else {
            if ($t =~ /\A\s*\[Request interrupted by user/) {
                # the person stopped the turn (Esc), whatever ran in it
                _opened($st, 'stop', $ts, 'its turn was interrupted');
            } elsif ($t =~ /\A\s*<bash-input>/) {
                # a shell command the person typed with `!`
                _opened($st, 'stop', $ts, 'a prompt');
            } elsif ($mine || $t =~ /\A\s*<task-notification>/ || ($o && ($o->{kind} // '') eq 'task-notification')) {
                # the notification of background work (its own, or other work: no person, no other
                # session) opens a turn of the loop's while its context holds
                _opened($st, 'loop', $ts);
            } elsif ($t =~ /\A\s*Another Claude session sent a message/) {
                # a teammate's or an agent's message that names no background work of the loop's
                _opened($st, 'stop', $ts, "another session's message");
            } else {
                _opened($st, 'stop', $ts, 'a message');
            }
            delete $st->{ntfq};
        }
        delete $st->{ntfhit};
        return;
    }
    return unless $type eq 'assistant' && ref $c eq 'ARRAY';
    for my $it (@$c) {
        next unless ref $it eq 'HASH' && ($it->{type} // '') eq 'tool_use' && ref $it->{input} eq 'HASH';
        my ($n, $in) = ($it->{name} // '', $it->{input});
        if ($n eq 'Skill') {
            _invoked($st, 'Skill', $in->{skill}, $in->{args}, $cwd, $ts) if defined $in->{skill} && !ref $in->{skill};
        } elsif ($n eq 'Bash') {
            my $D = $st->{drv};
            if ($D && $D->{mode} eq 'paused') {
                if (!$D->{pause}{done} && _pause_write($in->{command})) { $D->{pause}{done} = 1; delete $D->{after} }
            } elsif ($D && $D->{mode} ne 'ended' && _self_pause($in->{command}, $D->{ws})) {
                _pause($D, { seq => $st->{seq}, ts => $ts }, 1, 1);
            }
            for my $b (@{ bash_calls($in->{command}) }) {
                my $root = $b->{cwd} // $cwd;
                my $read = _read_run($b);
                # A read in a session with no GSD work so far and no driver open (a plain ask: "what
                # phase is the payments workstream at?") is a look: no GSD use of the session's own,
                # no workstream of its own (owner 21:37: a plain ask gets no GSD line).
                my $Dp = $st->{drv};
                my $peek = ($read && !$st->{gsd} && !($Dp && ($Dp->{mode} // '') ne 'ended')) ? 1 : 0;
                # A read of another workstream than the one the session's own GSD work named only
                # looks at it (owner 21:37: workstream A gets only A's --ws): it names nothing and
                # moves no GSD root of the session's.
                my ($own) = grep { !$_->{look} } reverse @{ $st->{ws} || [] };
                if (!$peek && $read && defined $b->{ws} && $own && _wsn($b->{ws}) ne _wsn($own->{name})) {
                    _drv_tool($st, $b, $ts, $root);
                    next;
                }
                $st->{gsd} = { via => 'Bash', name => "gsd-tools $b->{verb}", args => '', hidden => 0, ts => $ts, root => $root } unless $peek;
                _push_root($st, $root);
                # a status look's own reads name no workstream of the session's
                my $look = (($st->{look} || $peek) && $read) ? 1 : 0;
                $st->{wseq} = ($st->{seq} // 0) + 1 unless $look;
                _drv_tool($st, $b, $ts, $root);
                _push_ws($st, $b->{ws}, $root, $ts, ++$st->{seq}, $look);
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
            $st->{wseq} = ($st->{seq} // 0) + 1;
            _drv_write($st, $ws, $rel, $ts, $n, $root);
            _push_ws($st, $ws, $root, $ts, ++$st->{seq});
        } elsif ($n eq 'SendMessage') {
            # A message to a background agent or teammate sets it working again once its result
            # says it was sent (_bg_user); Claude Code's notification when it stops may name this
            # call.
            my $to = $in->{to} // $in->{recipient};
            next unless defined $to && !ref $to && defined $it->{id} && !ref $it->{id};
            $to =~ s/\s*\[[0-9A-Za-z]+\]\z//;
            my $k = _bg_key($st, $to) // next;
            my $sm = $st->{bgsm} = ref $st->{bgsm} eq 'HASH' ? $st->{bgsm} : {};
            %$sm = () if keys %$sm > $BG_KEEP;
            $sm->{ $it->{id} } = $k;
        } elsif ($n eq 'TaskStop' || $n eq 'KillShell') {
            # a stopped task sends no notification (a teammate by its name, a task by its id)
            _bg_close($st, $_) for grep { defined && !ref } @$in{qw(task_id shell_id)};
        } elsif ($n eq 'CronDelete') {
            _bg_close($st, $in->{id}) if defined $in->{id} && !ref $in->{id};
        } elsif ($n eq 'ScheduleWakeup' && $in->{stop} && ref $st->{bg} eq 'HASH') {
            delete $st->{bg}{$_} for grep { ref $st->{bg}{$_} eq 'HASH' && ($st->{bg}{$_}{k} // '') eq 'w' } keys %{ $st->{bg} };
        } elsif ($n eq 'Agent' || $n eq 'Task' || $n eq 'Workflow') {
            # (the name it is given: its messages name it so)
            if (defined $in->{name} && !ref $in->{name} && defined $it->{id} && !ref $it->{id}) {
                my $nm = $st->{bgnm} = ref $st->{bgnm} eq 'HASH' ? $st->{bgnm} : {};
                %$nm = () if keys %$nm > $BG_KEEP;
                $nm->{ $it->{id} } = $in->{name};
            }
            # work after a pause: a spawn (a pause asked for: new work)
            my $D = $st->{drv};
            $D->{after} = 1 if $D && $D->{mode} eq 'paused' && !_plug($D);
        }
    }
    my $sr = ref $j->{message} eq 'HASH' ? ($j->{message}{stop_reason} // '') : '';
    my $mid = (ref $j->{message} eq 'HASH' && defined $j->{message}{id} && !ref $j->{message}{id}) ? $j->{message}{id} : undef;
    # A turn ends: end_turn, or an API error (stop_sequence, max_tokens, refusal: Claude Code writes
    # the error and the turn is over until the next prompt).
    if ($sr ne '' && $sr ne 'tool_use' && $sr ne 'pause_turn') {
        my $D = $st->{drv};
        # The checkpoint this plugin's nudge asked for, in the turn it closed (any row of its last
        # message): `Step 1: none: task done` says the loop finished.
        if ($sr eq 'end_turn' && $D && $D->{mode} ne 'ended' && ($D->{nudged} || (defined $mid && defined $D->{nmid} && $mid eq $D->{nmid}))) {
            my $t = _text($c);
            # (`Step 1:` on the Checkpoint line or the next one; any dash, colon or comma after `none`)
            _kill($D, 'its checkpoint', $ts, ' said the task is done')
                if $t =~ /(?:\A|\n)[ \t>*_-]*Checkpoint:[^\n]*?(?:\n[ \t>*_-]*)?\bStep 1:[ \t*_]*none\b[^\w\n]{0,8}task done/;
        }
        _turn_end($st, $ts, $mid, $sr eq 'end_turn' ? 0 : 1);
    }
}

# Background work that runs on after a turn ($st->{bg}: {its tool call id => {n, k => a (an agent,
# workflow or teammate) | b (a Bash command) | m (a Monitor; p: persistent) | w (a ScheduleWakeup)
# | c (a CronCreate task), d => the driver that launched it (its id), ts, u => the time it is over
# at the latest}}; $st->{bgid}: {agentId, task id, teammate name or id, cron id, the SendMessage call
# that woke it => {k => that tool call id, n}}). A tool result opens it, read while a driver is
# open: `async_launched` (an Agent or Workflow) or `teammate_spawned`, a backgroundTaskId (a Bash
# command), a Monitor's taskId with its timeout, a ScheduleWakeup's due time, a CronCreate id. A
# notification closes what it names (_bg_text), and so does a TaskStop (by the name or id it was
# given, or the task id in its result), a CronDelete, a ScheduleWakeup stop.
sub _bg_user {
    my ($st, $j, $c, $ts) = @_;
    my $r = $j->{toolUseResult};
    if (ref $r eq 'HASH' && ref $c eq 'ARRAY') {
        my ($tr) = grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'tool_result' && defined $_->{tool_use_id} && !ref $_->{tool_use_id} } @$c;
        if ($tr) {
            my $k = $tr->{tool_use_id};
            my $num = sub { my ($v) = @_; return (defined $v && !ref $v && $v =~ /\A[0-9]+(?:\.[0-9]+)?\z/) ? 0 + $v : undef };
            return _bg_add($st, $k, 'b', $ts, [ $r->{backgroundTaskId} ]) if defined $r->{backgroundTaskId};
            if (($r->{status} // '') =~ /\A(?:async_launched|teammate_spawned)\z/) {
                my $nm = ref $st->{bgnm} eq 'HASH' ? delete $st->{bgnm}{$k} : undef;    # the name it was given
                return _bg_add($st, $k, 'a', $ts, [ @$r{qw(agentId taskId name teammate_id agent_id)}, $nm ]);
            }
            if (defined $r->{taskId} && defined $num->($r->{timeoutMs})) {    # a Monitor
                my $u = (!$r->{persistent} && defined $ts) ? $ts + $num->($r->{timeoutMs}) / 1000 : undef;
                return _bg_add($st, $k, 'm', $ts, [ $r->{taskId} ], ($r->{persistent} ? (p => 1) : ()), (defined $u ? (u => $u) : ()));
            }
            if (!$r->{stopped} && ($num->($r->{scheduledFor}) // 0) > 0) {    # a ScheduleWakeup
                return _bg_add($st, $k, 'w', $ts, [], u => $num->($r->{scheduledFor}) / 1000);
            }
            if (defined $r->{humanSchedule} && defined $r->{id} && !ref $r->{id}) {    # a CronCreate task
                my $u = (!$r->{recurring} && defined $num->($r->{nextFireAt})) ? $num->($r->{nextFireAt}) / 1000 : undef;
                return _bg_add($st, $k, 'c', $ts, [ $r->{id} ], (defined $u ? (u => $u) : ()));
            }
            return _bg_close($st, $r->{task_id}) if defined $r->{task_type} && defined $r->{task_id} && !ref $r->{task_id};    # TaskStop
            # A SendMessage that was sent (not refused, not a shutdown request) woke its agent.
            my $sent = ref $st->{bgsm} eq 'HASH' ? delete $st->{bgsm}{$k} : undef;
            if ((defined $sent || defined $r->{resumedAgentId}) && $r->{success} && !defined $r->{request_id}) {
                my $key = $sent // _bg_key($st, $r->{resumedAgentId});
                return _bg_add($st, $key, 'a', $ts, [ $k ]) if defined $key;
            }
        }
    }
    my $t = !ref $c ? ($c // '')
          : ref $c eq 'ARRAY' ? join("\n", map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @$c) : '';
    _bg_text($st, $t, 1);
}

# A notification's text (a user row's, or one Claude Code queued while a turn ran: a queued_command
# attachment or a queue-operation row): it closes the background work it names. A task notification
# names its tool call (the launch, or the SendMessage that woke it) and its task id; a Monitor's
# event notifications (no status) leave it running. A background agent's message back and a
# teammate's idle notification close it too; a teammate's other messages are interim.
sub _bg_text {
    my ($st, $t, $turn) = @_;
    return unless defined $t && !ref $t && ((ref $st->{bg} eq 'HASH' && %{ $st->{bg} }) || (ref $st->{bgend} eq 'HASH' && %{ $st->{bgend} }));
    # (a user row's: whether it names an agent, workflow or teammate of the driver's, running or
    # finished: a later message of a finished one, a second report, is still the loop's own work's)
    # (turn 'q': a queued notification, delivered by the next row that opens a turn)
    my $fin = sub { $st->{ $turn eq 'q' ? 'ntfq' : 'ntfhit' } = 1 if $turn && _own_live($st, $_[0]) };
    if ($t =~ m{\A\s*<task-notification>}) {
        while ($t =~ m{<task-notification>(.*?)(?:</task-notification>|\z)}gs) {
            my $b = $1;
            next if $b =~ m{<summary>\s*Monitor event\b};
            # (a task stopped, killed or cancelled is no finished work of the loop's)
            my $ok = $b !~ m{<status>\s*(?:killed|stopped|cancell?ed)\b};
            if ($b =~ m{<tool-use-id>([^<\s]+)</tool-use-id>}) { my $x = _bg_close($st, $1); $fin->($x) if $ok }
            if ($b =~ m{<task-id>([^<\s]+)</task-id>}) {
                my $id = $1;    # the <status> match below would reset $1
                if ($b =~ m{<status>}) { my $x = _bg_close($st, $id); $fin->($x) if $ok }
            }
        }
        return;
    }
    $fin->(_bg_close($st, $1) // _ended($st, $1)) while $t =~ m{<agent-message from="([^"\s]+)"}g;
    # A teammate shut down while it worked sends no idle report: its shutdown approval or Claude
    # Code's termination notice closes it.
    # A message of one of its live teammates (a report, a question; not a shutdown) is a
    # notification of the loop's own work too.
    while ($t =~ m{<teammate-message teammate_id="([^"\s]+)"[^>]*>\s*([^\n]{0,80})}g) {
        my ($who, $head) = ($1, $2);
        next if $head =~ /"type"\s*:\s*"(?:shutdown_approved|teammate_terminated)"/;
        my $k = _bg_key($st, $who) // next;
        $fin->(ref $st->{bg}{$k} eq 'HASH' ? $st->{bg}{$k} : _ended($st, $who));
    }
    # (the loop shutting down its own teammates is its own work too)
    $fin->(_bg_close($st, $1) // _ended($st, $1)) while $t =~ m{<teammate-message teammate_id="([^"\s]+)"[^>]*>\s*\{\s*"type"\s*:\s*"shutdown_approved"}g;
    $fin->(_bg_close($st, $1) // _ended($st, $1)) while $t =~ m{\{\s*"type"\s*:\s*"teammate_terminated"\s*,\s*"message"\s*:\s*"([^"\s]+) has shut down}g;
    while ($t =~ m{<teammate-message teammate_id="([^"\s]+)"[^>]*>\s*(\{\s*"type"\s*:\s*"idle_notification"[^\n]*)}g) {
        my ($who, $js) = ($1, $2);
        # an idle report sent before a SendMessage woke the teammate again (they crossed) is old
        my $k = _bg_key($st, $who) // next;
        my $x = $st->{bg}{$k};
        my $at = $js =~ /"timestamp"\s*:\s*"([^"]+)"/ ? util::parse_iso($1) : undef;
        next if defined $at && ref $x eq 'HASH' && defined $x->{ts} && $at < $x->{ts};
        $fin->(_bg_close($st, $who) // _ended($st, $who));
    }
}

# The tool call id of the background work an id names (its own, or an alias), or undef.
sub _bg_key {
    my ($st, $id) = @_;
    return undef unless defined $id && !ref $id && $id ne '';
    my $x = ref $st->{bgid} eq 'HASH' ? $st->{bgid}{$id} : undef;
    return $x->{k} if ref $x eq 'HASH';
    return ((ref $st->{bg} eq 'HASH' && $st->{bg}{$id}) || (ref $st->{bgend} eq 'HASH' && $st->{bgend}{$id})) ? $id : undef;
}

# Background work ends: it is no longer live, but who it was is kept ($st->{bgend}: {its key =>
# {d, k, n}}, the newest 4 x $BG_KEEP), so a later message of it is still the loop's own work's.
sub _bg_close {
    my ($st, $id) = @_;
    my $k = _bg_key($st, $id) // return undef;
    my $x = ref $st->{bg} eq 'HASH' ? delete $st->{bg}{$k} : undef;
    if (ref $x eq 'HASH' && defined $x->{d}) {
        my $e = $st->{bgend} = ref $st->{bgend} eq 'HASH' ? $st->{bgend} : {};
        $e->{$k} = { d => $x->{d}, k => $x->{k} // 'a', n => ++$st->{bgn} };
        if (keys %$e > 4 * $BG_KEEP) { my ($o) = sort { $e->{$a}{n} <=> $e->{$b}{n} } keys %$e; delete $e->{$o} }
    }
    return $x;
}

# The ended background work an id names ({d, k}), or undef.
sub _ended {
    my ($st, $id) = @_;
    my $k = _bg_key($st, $id) // return undef;
    my $e = ref $st->{bgend} eq 'HASH' ? $st->{bgend}{$k} : undef;
    return ref $e eq 'HASH' ? $e : undef;
}

# Whether one of the ids (a message's sender: its name, its task id) names an agent, workflow or
# teammate of the open driver's, running or finished.
sub _own_sender {
    my ($st, @ids) = @_;
    for my $id (grep { defined && !ref && $_ ne '' } @ids) {
        my $k = _bg_key($st, $id) // next;
        return 1 if _own_live($st, ref $st->{bg}{$k} eq 'HASH' ? $st->{bg}{$k} : _ended($st, $id));
    }
    return 0;
}

# Whether closed background work (x) was an agent, workflow or teammate of the open driver's.
sub _own_live {
    my ($st, $x) = @_;
    my $D = $st->{drv};
    return (ref $x eq 'HASH' && $D && defined $x->{d} && defined $D->{id} && $x->{d} == $D->{id} && ($x->{k} // 'a') eq 'a') ? 1 : 0;
}

# Background work launched or woken (key: its tool call id; ids: its other names). It is the loop's
# when the loop launched it in its own context (not paused, never in a turn of this plugin's own);
# what starts once that context ended (the session's own research, a fix the person asked for) is
# not kept. A task woken again (a SendMessage) keeps its owner.
sub _bg_add {
    my ($st, $key, $kind, $ts, $ids, %x) = @_;
    my $D = $st->{drv};
    return unless defined $key && $D && $D->{mode} ne 'ended';
    my $bg = $st->{bg} = ref $st->{bg} eq 'HASH' ? $st->{bg} : {};
    my $old = ref $bg->{$key} eq 'HASH' ? $bg->{$key} : undef;
    return unless $old || ($D->{mode} eq 'active' && $D->{lv} && !$D->{own});
    $bg->{$key} = { %{ $old || {} }, k => $kind, n => ++$st->{bgn}, d => ($old ? $old->{d} : $D->{id} // 0),
                    (defined $ts ? (ts => $ts) : ()), %x };
    $bg->{$key}{k} = $old->{k} if $old && defined $old->{k} && $kind eq 'a';    # a woken task keeps its kind
    if (keys %$bg > $BG_KEEP) { my ($o) = sort { $bg->{$a}{n} <=> $bg->{$b}{n} } keys %$bg; delete $bg->{$o} }
    my $ix = $st->{bgid} = ref $st->{bgid} eq 'HASH' ? $st->{bgid} : {};
    for my $id (grep { defined && !ref && $_ ne '' && $_ ne $key } @{ $ids || [] }) { $ix->{$id} = { k => $key, n => $st->{bgn} } }
    if (keys %$ix > 4 * $BG_KEEP) {
        my @o = sort { $ix->{$a}{n} <=> $ix->{$b}{n} } keys %$ix;
        delete @$ix{ @o[0 .. $#o - 4 * $BG_KEEP] };
    }
}

# One of this plugin's own submitted notes (`Note from the user's <brand> plugin: …`; Claude Code
# writes it prefixed `The <brand> plugin sent a message:`): 'continue' for the auto-continue note
# after a compaction, 'turn' for a note that opens a turn of the plugin's own (its halt,
# planned-compaction and idle handoff turns), else undef.
sub _note {
    my ($t) = @_;
    my $b = eval { ctx::brand() } // '';
    return undef if $b eq '' || !defined $t || ref $t;
    return undef unless $t =~ /\A\s*(?:The \Q$b\E plugin sent a message:\s*)?Note from the user's \Q$b\E plugin: ([^\n]{0,60})/;
    return index($1, 'the session was compacted at the checkpoint') == 0 ? 'continue' : 'turn';
}

# Whether a user row (not meta, no command) is a prompt a person wrote: Claude Code marks it
# origin human; a row without an origin (older versions) counts unless it is a teammate message,
# an interruption mark or a tagged notice. Task notifications, tool results, stacked commands and
# this plugin's own submitted notes (the auto-continue note, a handoff turn's prompt: `Note from
# the user's <plugin> plugin: …`, whatever origin they carry) never count.
sub _human {
    my ($j, $t) = @_;
    return 0 if $j->{stackedExpansion} || $j->{isCompactSummary};
    return 0 unless defined $t && $t =~ /\S/;
    my $b = eval { ctx::brand() } // '';
    return 0 if $b ne '' && $t =~ /\A\s*(?:Note from the user's|The) \Q$b\E plugin(?: sent a message)?: /;
    return (($j->{origin}{kind} // '') eq 'human' ? 1 : 0) if ref $j->{origin} eq 'HASH';
    return 0 if defined $j->{origin};
    return 0 if $t =~ /\A\s*(?:<|\[Request interrupted|Another Claude session sent a message)/;
    return 1;
}

# A queued_command attachment on a main row (j): what Claude Code delivers inside the running turn,
# never as a user row. A notification closes the background work it names (and is no stop: a task
# notification, or the message of the loop's own agent or teammate). Anything else ends the loop's
# context (owner 20:57): a prompt a person typed meanwhile ("stop after this wave"; origin human, or
# none in older versions, read as a user row's text is; with the prose /gsd-pause-work a prompt may
# name), another session's message, an auto-continuation, a coordinator's correction. This plugin's
# own note never.
sub _queued {
    my ($st, $j) = @_;
    my $a = $j->{attachment};
    return unless ref $a eq 'HASH' && ($a->{type} // '') eq 'queued_command';
    my $t = _text($a->{prompt});
    my $ts = util::parse_iso($j->{timestamp} // $a->{timestamp} // '');
    # (a queued notification it delivers inside the turn opens no turn of its own)
    delete @$st{qw(ntfq ntfhit)};
    _bg_text($st, $t, 1);
    my $mine = delete $st->{ntfhit};
    $mine ||= _own_sender($st, @{ $a->{origin} }{qw(senderTaskId from)}) if ref $a->{origin} eq 'HASH';
    return if ($a->{commandMode} // '') eq 'task-notification' || $t =~ /\A\s*<task-notification>/;
    return if $mine || _note($t) || $t !~ /\S/;
    if (_human({ (exists $a->{origin} ? (origin => $a->{origin}) : ()) }, $t)) {
        _prompt($st, $ts, 'a prompt typed mid-turn', 1);
        _prose_pause($st, $t, $ts);
        return;
    }
    my $peer = ($t =~ /<(?:agent|teammate|cross-session)-message\b/ || (ref $a->{origin} eq 'HASH' && ($a->{origin}{kind} // '') eq 'peer')) ? 1 : 0;
    _kill($st->{drv}, $peer ? "another session's message" : 'a queued message', $ts);
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

# scan(path, %o{cache, budget_ms, dn}) -> (state, 'ok' | 'timeout' | 'unread'). Reads the
# transcript from the cached offset (the same file, not shorter than the offset, the same bytes
# before it, the same listed loop names), else from the start. dn: the listed loop names
# (driver_names() when not given).
sub scan {
    my ($path, %o) = @_;
    my $deadline = util::clock_ms() + ($o{budget_ms} // $SCAN_MS);
    local $DN = ref $o{dn} eq 'HASH' ? $o{dn} : driver_names();
    my $dnsig = join(';', sort keys %$DN);
    my @s = stat $path;
    return ({}, 'unread') unless @s;
    my ($st, $off, $cwd0) = ({}, 0, undef);
    open(my $fh, '<:raw', $path) or return ({}, 'unread');
    if (defined $o{cache} && -f $o{cache}) {
        my $c = eval { jsonc::decode(util::read_file($o{cache}, 256 * 1024) // '') };
        if (ref $c eq 'HASH' && ($c->{v} // 0) == $CACHE_V && ($c->{path} // '') eq $path && ($c->{dev} // -1) == $s[0]
            && ($c->{ino} // -1) == $s[1] && ($c->{offset} // -1) >= 0 && $c->{offset} <= $s[7] && ref $c->{state} eq 'HASH'
            && ($c->{mark} // '') eq _mark($fh, $c->{offset}) && ($c->{dn} // '') eq $dnsig) {
            ($st, $off, $cwd0) = ($c->{state}, $c->{offset}, $c->{cwd});
        }
    }
    seek($fh, $off, 0);
    my ($n, $status) = (0, 'ok');
    # Tests stop a scan after this many rows, as if its time ran out there.
    my $rows_max = (util::test_mode() && ($ENV{STORE_TEST_GSD_SCAN_ROWS} // '') =~ /\A[1-9][0-9]{0,8}\z/) ? 0 + $ENV{STORE_TEST_GSD_SCAN_ROWS} : 0;
    while (my $l = <$fh>) {
        last unless substr($l, -1) eq "\n";    # a row still being written: next time
        # Checked before the row counts as read, so a scan that stops here reads it next time.
        if ((++$n % 256 == 0 && util::clock_ms() > $deadline) || ($rows_max && $n > $rows_max)) { $status = 'timeout'; last }
        $off += length $l;
        # This plugin's checkpoint nudge (a tool call's added context: a hook_additional_context
        # attachment, or a tool result's text; not a request blob echoing it, a summary or a prompt
        # quoting it): the turn it asks to close is the plugin's checkpoint, not the loop stopping.
        if (index($l, ' plugin: context is at ') >= 0 && $st->{drv} && ($st->{drv}{mode} // '') ne 'ended'
            && index($l, '"isSidechain":true') < 0
            && (index($l, '"hook_additional_context"') >= 0 || (index($l, '"type":"user"') >= 0 && index($l, '"tool_result"') >= 0))) {
            my $b = eval { ctx::brand() } // '';
            $st->{drv}{nudged} = 1 if $b ne '' && index($l, "Note from the user's $b plugin: context is at ") >= 0;
        }
        # (background work running, or ended work whose later messages are still the loop's own work's)
        my $bgo = ((ref $st->{bg} eq 'HASH' && %{ $st->{bg} }) || (ref $st->{bgend} eq 'HASH' && %{ $st->{bgend} })) ? 1 : 0;
        my $open = $st->{drv} && ($st->{drv}{mode} // '') ne 'ended';
        # What Claude Code delivers inside the running turn (a queued_command attachment: a prompt a
        # person typed meanwhile, a notification, another session's message): _queued.
        if (index($l, '"queued_command"') >= 0 && ($open || $st->{look} || $bgo) && length($l) <= $ROW_MAX
            && index($l, '"isSidechain":true') < 0) {
            my $j = eval { jsonc::decode($l) };
            if (ref $j eq 'HASH' && !$j->{isSidechain} && ($j->{type} // '') eq 'attachment') { _queued($st, $j); next }
        }
        # A notification Claude Code queued while a turn ran (a queue-operation row) closes the
        # background work it names, as a user row does; it waits for a turn of its own.
        if ($bgo && (index($l, '<task-notification>') >= 0 || index($l, 'agent-message from=') >= 0 || index($l, 'idle_notification') >= 0
                     || index($l, 'shutdown_approved') >= 0 || index($l, 'teammate_terminated') >= 0)
            && index($l, '"type":"user"') < 0 && index($l, '"type":"assistant"') < 0 && length($l) <= $ROW_MAX) {
            my $j = eval { jsonc::decode($l) };
            _bg_text($st, $j->{content}, 'q') if ref $j eq 'HASH' && !$j->{isSidechain} && ref $j->{attachment} ne 'HASH';
        }
        # metadata rows (request blobs, titles, modes) lead with their type; message rows do not
        next if index($l, '{"type":"') == 0 && index($l, '{"type":"user"') != 0 && index($l, '{"type":"assistant"') != 0;
        next if index($l, '"isSidechain":true') >= 0;
        my $user = index($l, '"type":"user"') >= 0;
        if ($user) {
            # A skill text is a meta row, whatever it quotes (a `<command-name>` tag included).
            if (defined $st->{last} && index($l, 'Base directory for this skill:') >= 0 && index($l, '"isMeta":true') >= 0) {
                _skill_text($st, $l);
                next;
            }
            # a typed command, or a row that opens a turn while a driver or a status look is open
            # (also another session's message, which Claude Code writes as a meta row), or (while a
            # driver is open, or background work runs) background work launched or ending
            next if index($l, '<command-name>') < 0
                && !(($open || $st->{look}) && index($l, '"isMeta":true') < 0 && index($l, '"type":"tool_result"') < 0)
                && !($open && (index($l, '"kind":"peer"') >= 0 || index($l, '[Cross-session ') >= 0))
                && !(($open || $bgo) && $l =~ /_launched"|"teammate_spawned"|<agent-message from=|"backgroundTaskId"|idle_notification|shutdown_approved|teammate_terminated|"timeoutMs"|"scheduledFor"|"humanSchedule"|"task_type"|"resumedAgentId"|"success":true|<task-notification>/);
        } else {
            # spawns, a pause's files and turn ends matter only while a driver is open
            next unless index($l, '"type":"assistant"') >= 0;
            next unless ($open && $l =~ /"stop_reason":"(?:end_turn|stop_sequence|max_tokens|refusal)"/)
                || (index($l, '"tool_use"') >= 0
                    && (index($l, '"Skill"') >= 0 || index($l, 'gsd') >= 0 || index($l, '.planning/') >= 0
                        || (($open || $bgo) && $l =~ /"name":"(?:Agent|Task|Workflow|SendMessage|TaskStop|KillShell|CronDelete|ScheduleWakeup)"/)
                        || ($open && (index($l, 'HANDOFF.json') >= 0 || index($l, '.continue-here') >= 0))));
        }
        next if length($l) > $ROW_MAX;
        my $j = eval { jsonc::decode($l) } or next;
        $cwd0 //= $j->{cwd} if ref $j eq 'HASH' && defined $j->{cwd} && !ref $j->{cwd};
        _row($st, $j, $cwd0);
    }
    if (defined $o{cache}) {
        my $mark = _mark($fh, $off);
        eval { util::write_atomic($o{cache}, jsonc::encode_bytes({ v => $CACHE_V, path => $path, dev => $s[0], ino => $s[1],
                                                                   offset => $off, mark => $mark, dn => $dnsig, cwd => $cwd0, state => $st }) . "\n", 0600) };
    }
    close $fh;
    return ($st, $status);
}

# The folder holding .planning/ at or above dir, or undef.
sub _gsd_root {
    my ($dir) = @_;
    return undef unless defined $dir && $dir =~ m{\A/};
    my $home = util::home() // '';
    $home =~ s{/+\z}{};
    for (1 .. 24) {
        return $dir if -d "$dir/.planning";
        # GSD's own walk: never past a repository or worktree root (a .git folder or file), nor
        # into the home folder.
        last if -e "$dir/.git" || $dir eq '/' || $dir eq '';
        $dir =~ s{/[^/]*\z}{};
        $dir = '/' if $dir eq '';
        last if $home ne '' && $dir eq $home;
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

# The position in a STATE.md (stop: the stopped-at text's length, 60 unless given).
sub _state_text {
    my ($sp, $stop) = @_;
    return 'not found' unless -f $sp;
    my $s = state($sp) or return 'unreadable';
    my @p;
    push @p, 'status ' . _cut($s->{status}, 30) if defined $s->{status};
    push @p, 'phase ' . _cut($s->{phase}, 40) if defined $s->{phase};
    push @p, 'stopped at ' . _cut($s->{stopped_at}, $stop // 60) if defined $s->{stopped_at};
    push @p, 'last activity ' . _cut($s->{last_activity}, 30) if defined $s->{last_activity};
    return @p ? join(' · ', @p) : 'no position recorded';
}

# The listed driver names: %DRIVERS plus the owner's `driver_skills` setting (`;`-separated).
sub driver_names {
    my %d = %DRIVERS;
    my $v = eval { rc::val('driver_skills') };
    $d{ _norm($_) } = 1 for eval { settings::list($v) };
    return \%d;
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
# (of such arguments only the kept parts: `--ws`, `resume`, `--repo`/`--cwd` with a plain path).
sub _cmd {
    my ($e, $shown) = @_;
    my $c = '/' . $e->{name};
    return $c . " $e->{args}" if defined $e->{args} && $e->{args} ne '';
    return $c . ' (arguments not shown)' if $e->{hidden} && $shown;
    return $c . " $e->{keep}" if $e->{hidden} && defined $e->{keep} && $e->{keep} ne '';
    return $c . (defined $e->{ws} ? " --ws $e->{ws}" : '');
}

sub _when { my ($e) = @_; return defined $e->{ts} ? "$e->{via}, " . util::stamp($e->{ts}) : $e->{via} }

# The workstream the shared .planning/active-workstream pointer names under root (its folder
# exists), or undef. GSD uses it for a session with no --ws and no pointer of its own.
sub _shared {
    my ($root) = @_;
    return undef unless defined $root;
    my $raw = util::read_file("$root/.planning/active-workstream", 256) // return undef;
    my ($n) = $raw =~ /\A\s*($WS)\s*\z/ or return undef;
    return ($n ne 'none' && -d "$root/.planning/workstreams/$n") ? $n : undef;
}

# session(sid, transcript, cwd, worktree, cache_dir, budget_ms) -> {status: gsd | driver | none |
# timeout | unread, lines => [GSD line?, GSD re-entry line?, driver line?], line, reentry (the
# GSD re-entry line), driver (the Active, Paused or Was-driving line), mode (the driver's: active,
# paused or hint), paused (1 for a paused driver), state (the STATE.md path, GSD only), workstream,
# root, reenter => [the re-enter command]}. No line for a session that worked with neither GSD nor
# a driver skill (an ended driver counts as none), nor for one whose transcript is not found.
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
    my $D = ref $st->{drv} eq 'HASH' && ($st->{drv}{mode} // '') ne 'ended' ? $st->{drv} : undef;
    my $d = $D ? $D->{e} : undef;
    my $g = $st->{gsd};
    # A driver invoked with an existing workstream drives GSD work.
    if (!$g && $d && defined $d->{ws} && _ws_any($d->{ws}, $d->{root}, @roots)) {
        $g = $d;
    }
    return { status => 'none', lines => [] } unless $g || $d;
    my %out = (status => ($g ? 'gsd' : 'driver'), lines => []);
    my ($ws, $root, $cwdflag, $caution, $nocwd) = (undef, undef, '', '', undef);
    if ($g) {
        # The newest workstream named by GSD work, or by the driver's own --ws.
        # (a status look's workstream only while no other GSD work followed it)
        my @named = grep { !$_->{look} || ($_->{seq} // 0) > ($st->{wseq} // -1) } @{ $st->{ws} || [] };
        push @named, { name => $d->{ws}, root => $d->{root}, seq => $d->{seq} } if $d && defined $d->{ws};
        for my $w (sort { ($b->{seq} // 0) <=> ($a->{seq} // 0) } @named) {
            ($root, $ws) = _ws_any($w->{name}, $w->{root}, @roots);
            last if defined $ws;
        }
        $root //= _gsd_root($g->{root} // $here) // _gsd_root($here);
        my $sp = defined $root ? (defined $ws ? "$root/.planning/workstreams/$ws/STATE.md" : "$root/.planning/STATE.md") : undef;
        my $mk = sub {
            return 'GSD (this session): ' . (defined $ws ? "workstream $ws" : 'no workstream named') . ' · '
                 . (defined $sp ? util::abbrev($sp) . ': ' . _state_text($sp, $_[0]) : 'no .planning folder found');
        };
        my $line = $mk->(60);
        # A long path shortens the stopped-at text first, so the last-activity stamp stays whole
        # (as skills::core::gsd_state does).
        if (length($line) > $LINE_MAX) { my $n = 60 - (length($line) - $LINE_MAX); $line = $mk->($n < 10 ? 10 : $n) }
        $out{line} = _cut($line, $LINE_MAX);
        @out{qw(workstream root)} = ($ws, $root);
        $out{state} = $sp if defined $sp && -f $sp;
        # GSD work in another checkout than this session's: its commands need --cwd.
        my $hr = _gsd_root($here);
        # A root whose path cannot be written as a plain --cwd (a space, a non-ASCII letter): never an
        # imperative command that would run in this checkout instead (R2, R3).
        if (defined $root && (!defined $hr || $hr ne $root)) {
            if ($root =~ $PLAIN_PATH) { $cwdflag = " --cwd $root" } else { $nocwd = 1 }
        }
        # Flat work beside a shared pointer: GSD sends a command without --ws to that workstream.
        my $sh = defined $ws ? undef : _shared($root);
        $caution = " (caution: .planning/active-workstream names $sh, and GSD uses it)" if defined $sh;
        $caution .= " (caution: its GSD root is another checkout whose path cannot be passed as --cwd: run it there)" if defined $nocwd;
    }
    my $gsd_cmd = '/gsd-resume-work' . (defined $ws ? " --ws $ws" : '') . $cwdflag;
    my ($re, $mode);
    if ($d) {
        my %e = %$d;
        $e{args} = _fix_ws($e{args}, $e{root}, @roots) if defined $e{args};
        $e{keep} = _fix_ws($e{keep}, $e{root}, @roots) if defined $e{keep};
        if (defined $e{ws}) { my (undef, $v) = _ws_any($e{ws}, $e{root}, @roots); $e{ws} = $v // $e{ws} }
        $re = _cmd(\%e);
        # Its GSD root: the one its invocation named or its own loop work used (R3: never one only
        # the session's other GSD work named, a read of another checkout), else this checkout's.
        my $hr = _gsd_root($here);
        my $droot = $D->{root} // $hr;
        my ($dflag, $dnocwd) = ('', undef);
        if (defined $droot && (!defined $hr || $hr ne $droot)) {
            if ($droot =~ $PLAIN_PATH) { $dflag = " --cwd $droot" } else { $dnocwd = 1 }
        }
        my $dsh = _shared($droot);
        my $dcaution = (defined $dsh ? " (caution: .planning/active-workstream names $dsh, and GSD uses it)" : '')
            . (defined $dnocwd ? " (caution: its GSD root is another checkout whose path cannot be passed as --cwd: run it there)" : '');
        # A GSD loop re-enters with its own workstream (else the session's; a listed superpowers
        # driver takes no GSD flags) and, a GSD command, with its GSD root; another loop keeps its
        # own root flag.
        # (a driver with no workstream of its own gets none: never one the session's other work named)
        my $dws = defined $D->{ws} ? $ws : undef;
        if (defined $D->{ws}) { my (undef, $v) = _ws_any($D->{ws}, $e{root}, @roots); $dws = $v if defined $v }
        if ($g && ($e{name} =~ /\Agsd-/ || !$DRIVERS{ $e{name} })) {
            $re .= " --ws $dws" if defined $dws && $re !~ /(?:\A|\s)--ws(?:\s|=)/;
            $re .= $dflag if $dflag ne '' && $e{name} =~ /\Agsd-/ && $re !~ /(?:\A|\s)--(?:cwd|repo|project-dir)(?:\s|=)/;
        }
        $mode = $D->{mode};
        my $why = $D->{why};
        my $at = defined $D->{pause}{ts} ? ' ' . util::stamp($D->{pause}{ts}) : '';
        if ($mode eq 'paused' && !$D->{pause}{done}) {
            # A pause asked for ("/gsd-pause-work when finished") whose files are not written yet
            # (and new loop work after it: the request may be ignored, or still to come).
            ($mode, $why) = ('hint', "pause asked$at, " . ($D->{after} ? 'then loop work, its files not written yet' : 'its files not written yet'));
        } elsif ($mode eq 'paused' && $D->{after}) {
            ($mode, $why) = ('hint', "paused$at, then other work");
        }
        # Arguments that cannot be shown (prose: "read it only", "do not start yet"), none of the
        # parts a re-enter command keeps (--ws, resume, --repo/--cwd), and no GSD work of its
        # workstream after it: it may never have started (a listed non-GSD loop excepted).
        if ($mode eq 'active' && $e{hidden} && ($e{keep} // '') eq '' && !$D->{work} && ($e{name} =~ /\Agsd-/ || !$DRIVERS{ $e{name} })) {
            ($mode, $why) = ('hint', 'arguments not shown, no GSD work after it');
        }
        # Owner 2026-10-27 20:57: Active only while the loop is clearly live at the cut: its own
        # context holds and a turn of its own runs (one of its steps mid-turn), or an agent,
        # workflow, teammate or wake-up it launched still runs. Anything else is the hint (a turn
        # ended, an interruption, a pause, a prompt of any kind, another session's turn, ambiguity).
        if ($mode eq 'active' && !$D->{lv}) {
            ($mode, $why) = ('hint', $why // 'unclear');
        } elsif ($mode eq 'active' && !$D->{mt} && !(_running($st, $D, undef))[0]) {
            ($mode, $why) = ('hint', 'its own background work ended, and no turn of its own followed');
        }
        # R2, R3: a GSD loop whose GSD root is another checkout that --cwd cannot name would run here.
        if ($mode eq 'active' && defined $dnocwd && $e{name} =~ /\Agsd-/ && $re !~ /(?:\A|\s)--(?:cwd|repo|project-dir)(?:\s|=)/) {
            ($mode, $why) = ('hint', "its GSD root is another checkout whose path cannot be passed as --cwd");
        }
        # R1: a GSD loop it ran as its step once its context had ended: named, never run.
        if ($mode eq 'hint' && ref $D->{step} eq 'HASH') {
            my %s = %{ $D->{step} };
            $s{args} = _fix_ws($s{args}, $s{root}, @roots) if defined $s{args};
            $s{keep} = _fix_ws($s{keep}, $s{root}, @roots) if defined $s{keep};
            if (defined $s{ws}) { my (undef, $v) = _ws_any($s{ws}, $s{root}, @roots); $s{ws} = $v // $s{ws} }
            $why = ($why // 'unclear') . '; later step: ' . _cmd(\%s, 1);
        }
        # A flat GSD re-enter command goes where GSD's shared pointer points (no --ws of its own):
        # every form names it, the hint too (its command may be run once Step 1 belongs to it).
        my $dc =($dcaution ne '' && $re !~ /(?:\A|\s)--ws(?:\s|=)/ && ($e{name} =~ /\Agsd-/ || !$DRIVERS{ $e{name} }))
            ? '; ' . substr($dcaution, 2, -1) : '';
        $out{driver} = $mode eq 'paused'
            ? 'Paused driver: ' . _cmd(\%e, 1) . ' (' . _when(\%e) . (defined $D->{pause}{ts} ? '; paused ' . util::stamp($D->{pause}{ts}) : '; paused')
              . "$dc) · re-enter (new session only): $re"
            : $mode eq 'hint'
            ? 'Was driving: ' . _cmd(\%e, 1) . ' (' . _when(\%e) . '; ' . ($why // 'unclear') . "$dc) · re-enter only if Step 1 belongs to it: $re"
            : 'Active driver: ' . _cmd(\%e, 1) . ' (' . _when(\%e) . "$dc) · re-enter: $re";
        $out{mode} = $mode;
        $out{paused} = 1 if $mode eq 'paused';
    }
    # The passive GSD re-entry: beside no driver, one that is not active, or one that is no GSD
    # command.
    my $active = $d && $mode eq 'active';
    $out{reentry} = "GSD re-entry (new session only): $gsd_cmd$caution" if $g && (!$active || $d->{name} !~ /\Agsd-/);
    $out{reenter} = [ $active ? $re : $gsd_cmd ];
    $out{lines} = [ grep { defined } @out{qw(line reentry driver)} ];
    return \%out;
}

1;
