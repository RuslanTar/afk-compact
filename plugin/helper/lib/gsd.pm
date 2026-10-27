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
# state-file write. Its workstream is the newest one named by those (`--ws <name>`,
# `--ws=<name>`, `gsd-workstreams switch|resume <name>`, a state-file write under
# workstreams/<name>/) or by its driver's own `--ws`, whose folder exists under a GSD root the
# session touched (the row's cwd, `--cwd`, `--repo`, a state-file write's root; GSD's own walk:
# up to the first folder holding .git, never $HOME). `--ws` on any other skill names nothing (a
# handoff or catch-up skill only looked at it); the shared .planning/active-workstream pointer
# never names one. With none named the session works flat.
# A loop skill is one of %DRIVERS, one the owner lists in the `driver_skills` setting, or a skill
# that is no GSD command but whose own text, as Claude Code loaded it into this session right after
# the invocation, runs gsd-tools in its code (a fenced block or a code span: a loop that drives GSD
# work). This plugin's own skills, other GSD commands and /loop, /goal are never one. A listed loop
# chained into a typed GSD command with `and`/`then` (`/gsd-resume-work --ws X and /<loop> <args>`)
# counts as invoked there, with its own arguments; an unlisted chained skill only through its own
# invocation.
# The driver (root rulings R1, R2 of 2026-10-27) is the OUTERMOST loop this session invoked: a loop
# the model invokes through the Skill tool (or the user stacks after it in the same message) while
# the driver is active, with no human prompt since the driver's last loop work, is that driver's
# own step (gsd-autonomous or gsd-manager running gsd-execute-phase), never a new driver, unless the
# driver is a listed loop that runs no other loop (%LEAF). After a human prompt, or while the driver
# is only a hint, a GSD loop the model invokes for the driver's workstream (or naming none) is still
# that driver's step, and the driver stays what it was (a prompt between makes it at most a hint,
# never its step Active; the step's work after later prompts, a checkpoint's answer, never makes the
# driver Active again: only its own re-invocation does). The same loop invoked again, a loop the
# user types, or another loop invoked after a human prompt (a superpowers loop, a GSD loop for
# another workstream) takes over.
# A human prompt is a user row a person wrote (not a tool result, a task or teammate notification,
# another session's message, an interruption mark, a stacked command, a typed Claude Code command,
# a typed status look (%LOOK), /gsd-pause-work, one of this plugin's skills or this plugin's own
# submitted note; nor a prompt this plugin's skill answers right after it). A prompt that comes
# while the active driver's own agents or workflows run and its turn has not stopped since its last
# loop work is a steering prompt ("continue", "use more agents"): no stop (R2; its turn end with
# none of that work live is), but after it only a GSD loop for its workstream is its step. Loop
# work is the driver's own (re)invocation, a step it runs, a GSD work command or a gsd-tools run that
# changes planning state or a state-file write for its workstream (a state-file write, a phase's own
# files included, only in its loop context: after a human prompt or once its turn ended with nothing
# running it may be a note, a fix or a squash message the person asked for; while a human prompt
# waits or after its turn ended, only a gsd-tools run that records a phase's progress, %PROGRESS: a
# commit, a todo, a decision, a phase added or a STATE.md note (state.update, state.patch) the
# person asked for is not; an Agent, Task or Workflow spawn only while no human prompt waits); never
# what a skill or command started after a human prompt does, nor what a turn another session's
# message opened or a turn or a skill of this plugin's own does (its resume reconciling STATE.md,
# its handoff). A driver with no workstream of its own takes the first one its loop work names
# before any prompt; a GSD work command or a state run that names one after a prompt is another
# workstream's work (a hint), and its re-enter command never gets a --ws its loop work did not name.
# A GSD loop absorbed as the driver's step after a prompt or
# while the driver is a hint is named in the hint (`later step: …`), never as the driver. Its
# lifecycle, read in transcript order:
#   - `/gsd-pause-work` (of the driver's workstream, or naming none) pauses it once the pause's
#     own HANDOFF.json or .continue-here file is written (an Edit or Write, a Bash redirect or tee
#     into one, a commit naming one; never a `git rm`, `rm` or `mv` of one); before that it is
#     ambiguous (a pause asked "when finished"). A loop that pauses itself without the command
#     creates one of those files (a Write, a `>` redirect or a tee into one; not an Edit or an
#     append, nor a commit, which a routine checkpoint or a resume consuming the file also makes)
#     as the last act of its turn: until a turn ends with none of its background work live it is
#     ambiguous, and loop work in between cancels it (a GSD work command or a loop skill invoked, a
#     gsd-tools run that changes state other than a commit, a test or build run, an Agent, Task or
#     Workflow spawn, a write of a phase file, ROADMAP, REQUIREMENTS, PROJECT or of the checkout's
#     code; not the pause's own acts: a commit, a run-state append or another file under .planning/,
#     STATE.md, a note outside the checkout, stopping its work, a message, a read, this plugin's
#     skills). Loop work for a paused loop (a GSD work command, or a gsd-tools run for that
#     workstream that changes state other than a commit; not a state-file write after
#     /gsd-pause-work, as the pause writes STATE.md too) makes it again what it was before the pause
#     (active, or ambiguous); before the files are written a read or a status command does too, and
#     after a loop paused itself, that loop work before the next human prompt, or a write of a phase
#     file, ROADMAP, REQUIREMENTS or PROJECT (not STATE.md) before it; after that prompt a write
#     never resumes it (a phase file makes it ambiguous, the rest leaves it paused): only its
#     re-invocation, a GSD work command or a %PROGRESS run does. A pause file it writes after one of
#     this plugin's skills in its own turn, or in a turn of this plugin's own, starts a self-pause
#     too (ambiguous until a turn of the loop's ends). Nothing a turn or a skill of this plugin's own
#     does ends a pause (R4: its handoff and its resume only show the re-entry). After
#     the files, only reads, status commands or an Agent, Task or Workflow spawn leave it ambiguous;
#   - it has ended after a finishing skill (%FINISH), a GSD work command for another workstream, or,
#     for a single-phase loop (%STEP), a GSD work command the user typed;
#   - it is ambiguous after a GSD status command or a gsd-tools run for another workstream, a GSD
#     work command typed during a multi-phase loop, a GSD command the model invoked after a
#     single-phase loop (its own step hook or the session moving on), a `phase.complete` run after a
#     single-phase loop (its own completion), a human prompt with no loop work after it (the loop
#     finished, stopped or was set aside; $IDLE_PROMPTS), a turn end (an assistant row with stop
#     reason end_turn) with none of its background work live and no loop work after it (the loop's
#     final report, a stop, or a wait for the user), the checkpoint this plugin's nudge asked for
#     saying `Step 1: none: task done` (`Step 1:` on its line or the next, any dash after `none`),
#     and while it was invoked with arguments that cannot be
#     shown, none of them kept for its re-enter command, and no GSD work of its workstream followed.
#     Its background work is what Claude Code ran in the background while it drove (launched by the
#     same loop, re-invoked, counts too): live are an Agent or Workflow until a task notification
#     names its tool call or its task id, the agent hands back or a TaskStop names it; a teammate
#     until its idle notification (not one sent before a SendMessage woke it), its shutdown approval,
#     Claude Code's notice that it was terminated, or a TaskStop (a SendMessage to an agent or
#     teammate that was sent sets it running again, and its notification may name that call); a
#     ScheduleWakeup until it is due. A background Bash command, a Monitor (persistent, or one that
#     times out, until it ends, is stopped or its time is up) and a CronCreate task may be a server
#     or a watch that outlives the loop or only watches while it waits for the user: at a turn end
#     they make the hint name them, never an Active line. Never a stop: the turn this plugin's
#     checkpoint nudge asked to close, and a turn of this plugin's own (opened by its handoff note,
#     or by a person typing or asking for one of its skills: the driver stays what it was). One of
#     its skills the model runs inside the loop's own turn (a handoff before going idle) does no
#     loop work, but that turn's end is the loop's and the background work it starts after the
#     skill is the loop's. An API error or a turn cut off ends neither; the next turn (a prompt, a
#     task or teammate notification, an interruption mark) carries no exemption over.
# Only an active driver gets an `Active driver:` line (the resume protocol's [driver] re-entry keys
# on it, and only that line is ever run); a paused one gets `Paused driver:` (re-enter in a new
# session only), an ambiguous one the weaker `Was driving: … · re-enter only if Step 1 belongs to
# it: …` hint, an ended one no line; a GSD loop whose GSD root is another checkout whose path
# cannot be passed as a plain --cwd (a space, a non-ASCII letter) is at most that hint (R3: its
# command would run in this checkout). A session that used GSD with no active GSD-command driver
# also gets a passive `GSD re-entry` line (with a caution for such a root).
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
our $CACHE_V = 10;
our $BG_KEEP = 32;                    # newest background tasks kept while no notification names them
our $IDLE_PROMPTS = 1;                # human prompts with no loop work after them: an active driver is
                                      # only a `Was driving` hint (R2: it may have finished)
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
# gsd-tools runs that record a phase's own progress (`<verb>.<sub>`; verify* too): after a human
# prompt or a stopped turn, only these are loop work (R2: a person's bookkeeping is not).
# Not state.update or state.patch: GSD sends every STATE.md note a person asks for through them.
our %PROGRESS = map { $_ => 1 } qw(state.begin-phase state.advance-plan state.update-progress state.record-metric
                                   state.sync state.record-session state.complete-phase
                                   roadmap.update-plan-progress phase.complete phases.complete);
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

# bash_calls(command) -> [{verb, sub, ws, cwd}…]: the gsd-tools runs of one Bash command that read
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

# The driver's lifecycle (R1, R2; see the header). $st->{drv} = {e => the invocation it re-enters,
# mode => active | paused | hint | ended, ws => its workstream (its own --ws, else the one the
# session had named, else the first its loop work names), flat => it has none, and a workstream
# named after a prompt is another's, work => GSD work of that workstream
# followed it, pause => {seq, ts, done => its files were written, was => [mode, why] before it},
# after => other work followed the pause, why => why it is a hint, idle => human prompts since its
# last loop work, wts => that work's time, other => a skill or command started after the newest
# human prompt does what follows, plast => the seq of that prompt, tend => the time its turn ended
# with none of its background work live after its last loop work, tw => what still ran then (a
# background command, a monitor, a scheduled task), done => the time its nudged checkpoint said the
# task is done, sp => {seq, ts}: it created a pause file and its turn has not ended yet, id => its
# own number (its background work's owner), step => the GSD loop it ran as its step after a prompt
# or while it was a hint, own => a turn of this plugin's own runs, oskill => one of this plugin's
# skills ran inside the loop's own turn (until that turn ends), nudged / nmid => the turn this
# plugin's checkpoint nudge asked to close, and the message that closed it, steer => a steering
# prompt came since its last loop work, peer => a turn another session's message opened}. pause{self}: it paused
# itself (no /gsd-pause-work); pause{prompted}: a human prompt came after that pause.
sub _start {
    my ($st, $e) = @_;
    my $D = $st->{drv};
    if ($D && $D->{e}{name} ne $e->{name} && ($e->{via} ne 'typed' || $e->{stacked}) && !$LEAF{ $D->{e}{name} }
        && ($D->{mode} eq 'active' || $D->{mode} eq 'hint')) {
        # R1: a loop the model invokes (or the user stacked after it in the same message) while the
        # outer driver is active, with no human prompt since that driver's last loop work, is that
        # driver's own step (loop work), unless the driver runs no other loop.
        # After a steering prompt (one that came while its background work ran) only a GSD loop for
        # its workstream (or naming none) is its step; another loop takes over.
        my $sw = _wsn($e->{ws});
        if ($D->{mode} eq 'active' && !$D->{idle} && !$D->{other}
            && (!$D->{steer} || ($e->{name} =~ /\Agsd-/ && (!defined $sw || !defined $D->{ws} || $sw eq $D->{ws})))) {
            _touch($D, $e->{ts});
            return;
        }
        # R1 after a prompt, or while the driver is a hint: a GSD loop for the driver's workstream
        # (or naming none) is still its step (gsd-manager's typed choice, then its gsd-execute-phase),
        # and the driver stays what it was, at most a hint; never the step as the driver.
        my $ws = _wsn($e->{ws});
        if ($e->{name} =~ /\Agsd-/ && (!defined $ws || !defined $D->{ws} || $ws eq $D->{ws})) {
            # named in the hint, so the session sees which step it was in (never the driver)
            $D->{step} = { map { defined $e->{$_} ? ($_ => $e->{$_}) : () } qw(via name args hidden keep ws root) };
            return;
        }
    }
    my $ws = _wsn($e->{ws});
    my $same = $D && $D->{e}{name} eq $e->{name};
    $ws //= $D->{ws} if $same;
    if (!defined $ws) { my ($w) = grep { !$_->{look} } reverse @{ $st->{ws} || [] }; $ws = _wsn($w->{name}) if $w }
    $st->{drv} = { e => { %$e }, mode => 'active', ws => $ws, work => 0, idle => 0, wts => $e->{ts}, id => $e->{seq} // 0 };
    $st->{wseq} = $e->{seq};
    # The same loop invoked again (its re-entry after a compaction) still waits on the background
    # work it launched before; another loop does not.
    if ($same && $D->{mode} ne 'ended' && ref $st->{bg} eq 'HASH') {
        for my $x (values %{ $st->{bg} }) { $x->{d} = $e->{seq} // 0 if ref $x eq 'HASH' && ($x->{d} // -1) == ($D->{id} // -2) }
    }
}

# The driver's own loop work: no human prompt waits since.
sub _touch {
    my ($D, $ts) = @_;
    $D->{idle} = 0;
    $D->{wts} = $ts if defined $ts;
    delete @$D{qw(plast tend tw done steer)};
}

# The driver's loop context: no human prompt since its last loop work, no skill or command a prompt
# started, no turn of this plugin's own, no turn another session's message opened.
sub _mine {
    my ($D) = @_;
    return ($D && !$D->{idle} && !$D->{other} && !$D->{own} && !$D->{peer}) ? 1 : 0;
}

# What this plugin does (a turn of its own, or one of its skills the model ran inside the loop's
# turn): never the loop's work.
sub _plug {
    my ($D) = @_;
    return ($D->{own} || $D->{oskill}) ? 1 : 0;
}

# Whether a gsd-tools run records a phase's own progress (what a loop runs as it goes; not the
# bookkeeping a person asks for after the loop stopped: a commit, a todo, a decision or blocker, a
# phase added, inserted or removed, a milestone, requirements).
sub _progress {
    my ($b) = @_;
    my ($base) = $b->{verb} =~ /\A([^.]+)/;
    return 1 if $base eq 'verify' || $base eq 'verification';
    return $PROGRESS{ defined $b->{sub} ? "$base.$b->{sub}" : $base } ? 1 : 0;
}

# A pause is over: the driver is again what it was before it.
sub _unpause {
    my ($D) = @_;
    my ($m, $w) = @{ $D->{pause}{was} || ['active'] };
    $D->{mode} = $m // 'active';
    if (defined $w) { $D->{why} = $w } else { delete $D->{why} }
    delete @$D{qw(pause after)};
}

# Loop work of the driver (read: it only read planning state; mine: no skill or command started
# after a human prompt runs it). It is not paused (any longer), and it is again what it was before
# the pause; only a read after a pause whose files were written is other work.
sub _work {
    my ($D, $read, $ts, $mine) = @_;
    # A turn or a skill of this plugin's own (its resume reconciling STATE.md, its handoff) never
    # ends a pause (R2, R4).
    return if $D->{mode} eq 'paused' && _plug($D);
    if ($D->{mode} eq 'paused') {
        if ($read && $D->{pause}{done}) { $D->{after} = 1; return }
        _unpause($D);
    }
    $D->{work} = 1;
    _touch($D, $ts) if $mine && !$read && !$D->{other};
}

# Tools that do no work of their own (reads, the task list, a question to the user).
my %QUIET = map { $_ => 1 } qw(Read Grep Glob LS NotebookRead ToolSearch TodoWrite TaskCreate TaskUpdate TaskList
                               TaskGet TaskOutput AskUserQuestion);
my $PAUSE_FILE = qr{(?:HANDOFF\.json|\.continue-here)};

# A test or build run at a command position (what a loop that goes on runs; a pause does not).
my $TEST_RUN = qr{$CMD_AT(?:(?:npm|pnpm|yarn|bun)[ \t]+(?:run[ \t]+)?(?:test|build|ci|check|lint|typecheck)\b
                          |npx[ \t]+(?:jest|vitest|tsc|playwright|mocha|eslint)\b
                          |(?:bundle[ \t]+exec[ \t]+)?(?:rspec|rake|rubocop)\b|(?:bin/)?rails[ \t]+test\b|bin/rspec\b
                          |(?:python3?[ \t]+-m[ \t]+)?pytest\b|go[ \t]+(?:test|build|vet)\b|cargo[ \t]+(?:test|build|check)\b
                          |make\b|mvn\b|gradlew?\b|(?:\./)?tools/(?:check|build|test|typecheck)\b)}x;

# Whether a tool call after a pause file the loop created is loop work that goes on past the pause
# (R2): a GSD work command or a loop skill invoked, a gsd-tools run that changes planning state
# other than a commit (of the driver's workstream or none), a test or build run, an Agent, Task or
# Workflow spawn, a write of a phase file, ROADMAP, REQUIREMENTS or PROJECT, or of a file of the
# checkout outside .planning/ (code). The pause's own acts are not: a read, the task list, a
# question, STATE.md, a pause file, another file under .planning/ (a run-state table), a note
# outside the checkout, a commit or any other command, stopping its work (TaskStop, KillShell,
# CronDelete, a message to a worker), a monitor or a wake-up, another tool, this plugin's skills.
sub _activity {
    my ($st, $n, $in, $cwd) = @_;
    return 0 if $QUIET{$n};
    return 1 if $n eq 'Agent' || $n eq 'Task' || $n eq 'Workflow';
    if ($n eq 'Skill') {
        my $s = $in->{skill};
        return 0 unless defined $s && !ref $s;
        my $name = _norm($s);
        return 0 if _own($name) || $BUILTIN{$name} || $STATUS{$name} || $name eq 'gsd-pause-work';
        return (_is_gsd_cmd($name, $in->{args}) || _is_loop($st, $name)) ? 1 : 0;
    }
    if ($EDIT{$n}) {
        my $p = $in->{file_path} // $in->{notebook_path};
        return 0 unless defined $p && !ref $p && $p ne '';
        return 0 if $p =~ m{(?:\A|/)(?:STATE\.md|HANDOFF\.json|\.continue-here[^/]*)\z};
        $p = "$cwd/$p" if $p !~ m{\A/} && defined $cwd;
        return ($2 =~ m{\A(?:workstreams/[^/]+/)?(?:phases/|(?:ROADMAP|REQUIREMENTS|PROJECT)\.md\z)} ? 1 : 0)
            if $p =~ m{\A(/.*?)/\.planning/(.+)\z};
        my %seen;
        for my $r (grep { defined && $_ ne '' && $_ ne '/' && !$seen{$_}++ } _checkout($cwd), _gsd_root($cwd), @{ $st->{roots} || [] }) {
            return 1 if index($p, "$r/") == 0;
        }
        return 0;
    }
    if ($n eq 'Bash') {
        my $c = $in->{command};
        return 0 unless defined $c && !ref $c;
        my $dw = ref $st->{drv} eq 'HASH' ? $st->{drv}{ws} : undef;
        for my $b (@{ bash_calls($c) }) {
            next if _read_run($b) || $b->{verb} =~ /\Acommit(?:\.|-|\z)/;
            return 1 if !defined $b->{ws} || !defined $dw || _wsn($b->{ws}) eq $dw;
        }
        (my $u = $c) =~ s/<<-?[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n.*?\n[ \t]*\2[ \t]*(?=\n|\z)//gs;
        return _unquote($u) =~ $TEST_RUN ? 1 : 0;
    }
    return 0;
}

# The checkout at or above dir (the first folder holding .git), or dir itself.
sub _checkout {
    my ($dir) = @_;
    return undef unless defined $dir && $dir =~ m{\A/};
    my $d = $dir;
    for (1 .. 24) {
        return $d if -e "$d/.git";
        last if $d eq '/' || $d eq '';
        $d =~ s{/[^/]*\z}{};
        $d = '/' if $d eq '';
    }
    return $dir;
}

# Work after the driver created a pause file in this turn cancels that self-pause; work after a
# loop paused itself and before the next human prompt ends that pause (the loop went on).
sub _act {
    my ($D) = @_;
    return unless $D && $D->{mode} ne 'ended';
    delete $D->{sp};
    _unpause($D) if $D->{mode} eq 'paused' && $D->{pause}{self} && !$D->{pause}{prompted};
}

# The end of an assistant turn: with none of the driver's background work live, a pause file the
# driver created in it pauses it, and else a driver with no loop work since is at most a hint;
# never a turn of this plugin's own, nor the turn this plugin's checkpoint nudge asked to close.
sub _turn_end {
    my ($st, $ts, $mid) = @_;
    # one assistant message is written as several rows (thinking, text): its turn ends once
    return if defined $mid && defined $st->{lastend} && $mid eq $st->{lastend};
    $st->{lastend} = $mid;
    my $D = $st->{drv} or return;
    return if $D->{mode} eq 'ended';
    # one of this plugin's skills the model ran inside the loop's own turn: its writes were not loop
    # work, but the turn's end is the loop's; a turn another session's message opened is over
    delete @$D{qw(oskill peer)};
    # a turn of this plugin's own (its handoff turn, its command, its skill asked for by a prompt):
    # the driver stays what it was
    if (delete $D->{own}) { delete @$D{qw(nudged nmid)}; return }
    # the turn the plugin's checkpoint nudge closed: the loop goes on after the plugin's compaction
    # (unless that checkpoint says the task is done: _row reads it)
    if (delete $D->{nudged}) { $D->{nmid} = $mid // ''; return }
    delete $D->{nmid};
    my ($live, $loose) = _running($st, $D, $ts);
    # a pause file it created in a turn that ends while its background work still runs: unclear
    # until a turn ends with none of it live (no loop work between cancels it)
    if ($live) { $D->{sp}{tl} = $ts // 0 if ref $D->{sp} eq 'HASH'; return }
    if (my $sp = delete $D->{sp}) {
        _pause($D, $sp, 1);
        $D->{pause}{self} = 1;
        return;
    }
    # the first such turn end counts, unless what still ran then has ended since
    return if defined $D->{tend} && !(defined $D->{tw} && !defined $loose);
    $D->{tend} = $ts // 0;
    if (defined $loose) { $D->{tw} = $loose } else { delete $D->{tw} }
}

# The driver's background work at time ts: (live, loose). live: an agent, workflow or teammate or a
# ScheduleWakeup (before it is due) still runs. loose: what else still runs (a background command, a
# Monitor, persistent or one that times out before its time is up, a scheduled task): it may
# outlive the loop or only watch (a server, a stall watch while the loop waits for the user), so it
# never keeps the driver Active.
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

sub _hint {
    my ($D, $why) = @_;
    return unless $D->{mode} eq 'active';
    @$D{qw(mode why)} = ('hint', $why);
}

# A pause of the driver (e: {seq, ts}; done: its files are written). It keeps what the driver was
# before it, so loop work after it restores that (a hint stays a hint).
sub _pause {
    my ($D, $e, $done) = @_;
    my $was = $D->{mode} eq 'paused' ? $D->{pause}{was} : [ $D->{mode}, $D->{why} ];
    $D->{mode} = 'paused';
    delete @$D{qw(why after)};
    $D->{pause} = { seq => $e->{seq}, ts => $e->{ts}, was => $was, ($done ? (done => 1) : ()) };
}

# A human prompt: the driver's loop work stops until it shows again; but a prompt that comes while
# the active loop's own agents or workflows still run and its turn has not stopped since its last
# loop work (a steering note: "continue", "use more agents") is no stop (R2): its turn end with none
# of that work live is.
sub _prompt {
    my ($st, $ts) = @_;
    delete $st->{look};
    my $D = $st->{drv} or return;
    return if $D->{mode} eq 'ended';
    $D->{plast} = $st->{seq} // 0;
    if ($D->{mode} eq 'active' && !$D->{idle} && !$D->{other} && !defined $D->{tend} && !$D->{sp} && (_running($st, $D, $ts))[0]) {
        $D->{steer} = 1;
        _turn_open($D);
        return;
    }
    $D->{idle} = ($D->{idle} // 0) + 1;
    $D->{pause}{prompted} = 1 if $D->{mode} eq 'paused';
    # the person's prompt opens a turn of its own: no nudge or plugin turn carries over
    _turn_open($D);
    # After a step absorbed after a prompt (or while the driver was a hint), the step's work stays
    # the step's across later prompts (a checkpoint's answer): only the outer loop's own
    # re-invocation makes it the driver again (R1, R2: at most a hint).
    delete $D->{other} unless ref $D->{step} eq 'HASH';
}

# A user row that opens a turn (a prompt, a task or teammate notification, an interruption mark): no
# turn of this plugin's own, no plugin skill and no nudged checkpoint carries over from an earlier
# turn (one cut off has no end row).
sub _turn_open {
    my ($D) = @_;
    delete @$D{qw(own oskill nudged nmid peer)};
}

# One of this plugin's own submitted notes (_note): the auto-continue note opens the loop's next
# turn; a handoff note opens a turn of the plugin's own, whose end is no stop.
sub _own_note {
    my ($st, $kind) = @_;
    my $D = $st->{drv} or return;
    return if $D->{mode} eq 'ended';
    _turn_open($D);
    $D->{own} = 1 if $kind eq 'turn';
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
    # After a human prompt the command is the session's, not a step of the loop (nor in a turn of
    # this plugin's own, nor in a turn another session's message opened).
    my $mine = _mine($D) && !$D->{oskill} ? 1 : 0;
    # A driver with no workstream takes the first one its own loop work names (a GSD work command
    # in its loop context, before any steering prompt); one a command names after a prompt is
    # another workstream's work, and so is any named after that (R2). A status look names none.
    if (defined $cw && !defined $dw && !$STATUS{$n}) {
        if ($mine && !$D->{steer} && !$D->{flat}) { $D->{ws} = $dw = $cw }
        else {
            $D->{flat} = 1;
            return _hint($D, 'a GSD command for a workstream it never named followed');
        }
    }
    if (defined $cw && defined $dw && $cw ne $dw) {
        return _hint($D, 'a GSD command for another workstream followed') if $STATUS{$n};
        $D->{mode} = 'ended';
        return;
    }
    $D->{other} = 1 if !$mine && !_plug($D) && !$D->{peer};
    _work($D, $STATUS{$n} ? 1 : 0, $e->{ts}, $mine);
    return if $STATUS{$n} || $D->{mode} eq 'paused';
    if ($e->{via} eq 'typed' && !$e->{stacked}) {
        if ($STEP{ $D->{e}{name} }) { $D->{mode} = 'ended' } else { _hint($D, 'a GSD command was typed after it') }
    } elsif ($STEP{ $D->{e}{name} }) {
        _hint($D, 'another GSD command followed');
    }
}

# A gsd-tools state run.
sub _drv_tool {
    my ($st, $b, $ts) = @_;
    my $D = $st->{drv} or return;
    return if $D->{mode} eq 'ended';
    my ($cw, $dw) = (_wsn($b->{ws}), $D->{ws});
    # A driver with no workstream takes the first one its own loop work names (not a status look's
    # reads); one a run that changes state names after a prompt is another workstream's (R2).
    if (defined $cw && !defined $dw) {
        if (_mine($D) && !_plug($D) && !$D->{steer} && !$D->{flat} && !defined $D->{tend} && !($st->{look} && _read_run($b))) { $D->{ws} = $dw = $cw }
        elsif (!_read_run($b)) { $D->{flat} = 1 }
    }
    return _hint($D, 'gsd-tools ran for another workstream')
        if defined $cw && (defined $dw ? $cw ne $dw : $D->{flat} && !_read_run($b));
    return if $D->{mode} eq 'paused' && $b->{verb} =~ /\Acommit(?:\.|\z)/;    # the pause's own commit
    # After a human prompt, or once its turn ended with nothing running, only a phase's own progress
    # (%PROGRESS) is loop work: bookkeeping a person asks for (a commit, a todo, a decision, a phase
    # added) is not. Nor is anything a turn or a skill of this plugin's own runs.
    my $mine = _plug($D) ? 0 : (($D->{idle} || defined $D->{tend}) && !_progress($b)) ? 0 : 1;
    _work($D, _read_run($b), $ts, $mine);
    # A single-phase loop's own completion (GSD's execute-phase runs it last).
    _hint($D, 'its phase was marked complete')
        if $STEP{ $D->{e}{name} } && !$D->{other} && $b->{verb} =~ /\Aphase\z|\Aphase\.complete\z/ && ($b->{sub} // '') eq 'complete';
}

# A state-file write (rel: the path under .planning/; tool: Edit, Write, …).
sub _drv_write {
    my ($st, $ws, $rel, $ts, $tool) = @_;
    my $D = $st->{drv} or return;
    return if $D->{mode} eq 'ended';
    my ($cw, $dw) = (_wsn($ws), $D->{ws});
    return if defined $cw && defined $dw && $cw ne $dw;
    # A pause's own files: the asked-for pause took place, or the loop created one to pause itself
    # (an Edit of an existing one is a checkpoint note, no pause).
    if ($rel =~ m{(?:\A|/)(?:HANDOFF\.json|\.continue-here[^/]*)\z}) {
        if ($D->{mode} eq 'paused') {
            # a loop that paused itself and then did other work (a hint) creates a pause file again:
            # it paused itself again, from here on
            if ($D->{pause}{self} && $D->{after} && ($tool // '') eq 'Write' && !_plug($D)) {
                $D->{pause} = { seq => $st->{seq}, ts => $ts, was => $D->{pause}{was}, done => 1, self => 1 };
                delete $D->{after};
            } else { $D->{pause}{done} = 1 }
        }
        # (also in a turn or a skill of this plugin's own: that turn's end is no stop, so the pause
        # stays unclear until a turn of the loop's ends)
        elsif (($tool // '') eq 'Write') { $D->{sp} //= { seq => $st->{seq}, ts => $ts } }
        return;
    }
    if ($D->{mode} eq 'paused') {
        # After a loop paused itself (its turn ended), a write of a phase file, ROADMAP,
        # REQUIREMENTS or PROJECT before the next human prompt is its work again (not STATE.md,
        # which the pause's own bookkeeping writes; nor anything a turn or a skill of this plugin's
        # own writes). After a prompt, a write the person asked for never resumes it (R2, R4): a
        # phase file makes it unclear, the rest leaves it paused; only its own re-invocation, a GSD
        # work command or a phase's progress run does. A /gsd-pause-work also writes STATE.md, so
        # after one a write is no loop work.
        if ($D->{pause}{self} && !_plug($D) && $rel !~ m{(?:\A|/)STATE\.md\z}) {
            if (!$D->{pause}{prompted}) { _work($D, 0, $ts, 1) }
            elsif ($rel =~ m{(?:\A|/)phases/}) { $D->{after} = 1 }
        }
        return;
    }
    return if $D->{sp} && $rel =~ m{(?:\A|/)STATE\.md\z};    # a loop pausing itself records it
    # A state-file write (a phase's own files included) is the loop's work only in its loop context:
    # after a human prompt, or once its turn ended with nothing running, it may be a note, a fix or
    # a squash message the person asked for, or the loop resumed, which the transcript does not tell
    # apart (R2: at most a hint; its progress runs, a spawn in its own turn or its re-invocation
    # make it Active again). Neither is a write in a skill a prompt started or in a turn or a skill
    # of this plugin's own (its resume reconciling STATE.md).
    _work($D, 0, $ts, (!_plug($D) && _mine($D) && !defined $D->{tend}) ? 1 : 0);
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
    return if $BUILTIN{$name};
    my $own = _own($name);
    my $D = $st->{drv};
    # A skill of this plugin's the person asked for (typed, or the model's first call right after
    # the prompt) makes the turn the plugin's own.
    my $asked = $own && $via eq 'typed' ? 1 : 0;
    if ($via eq 'typed' && !$stacked && !$own && $name ne 'gsd-pause-work' && !$LOOK{$name}) {
        _prompt($st, $ts);    # a person typed it (a pause is read by the pause rules)
    } elsif ($via eq 'typed' && !$stacked && $LOOK{$name}) {
        # A status look typed while the loop runs (/gsd-progress) only looks: it opens a turn, but
        # it is no prompt that stops the loop (R2).
        _turn_open($D) if $D && $D->{mode} ne 'ended';
    } elsif ($own && $D && $D->{mode} ne 'ended' && ($D->{idle} || $D->{steer}) && ($D->{plast} // -1) == ($st->{seq} // 0)) {
        # This plugin's skill right after a prompt (a handoff asked for in prose): the prompt was
        # for it, not a turn away from the loop.
        $D->{idle}-- if $D->{idle};
        delete $D->{plast};
        $asked = 1;
    }
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
        # One of this plugin's skills (its resume, its handoff). Asked for by the person (or run in
        # a turn its note opened): the rest of the turn is the plugin's, not the loop's (its
        # STATE.md reconcile, its Step 1 agents), and its end no stop. Run by the model inside the
        # loop's own turn (a handoff before going idle, at the end of a long run): its writes are
        # not loop work, but the turn's end is the loop's, and background work started after it
        # is the loop's.
        my $D2 = $st->{drv};
        if ($D2 && $D2->{mode} ne 'ended') {
            _turn_open($D2) if $via eq 'typed';
            if ($asked) { $D2->{own} = 1 } elsif (!$D2->{own}) { $D2->{oskill} = 1 }
        }
        return;
    }
    return if $NOT_WORK{$name};
    if (_is_loop($st, $name)) { _start($st, \%e) }
    elsif ($name !~ /\Agsd-/) {
        $st->{last} = { %e };    # its skill text comes next (_skill_text)
        # A skill started after a human prompt: what follows is its work, not the loop's.
        $D = $st->{drv};
        $D->{other} = 1 if $D && $D->{mode} ne 'ended' && $D->{idle} && $D->{e}{name} ne $name;
    }
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

sub _row {
    my ($st, $j, $cwd0) = @_;
    return unless ref $j eq 'HASH' && !$j->{isSidechain};
    my $type = $j->{type} // '';
    my $ts = util::parse_iso($j->{timestamp} // '');
    my $cwd = (defined $j->{cwd} && !ref $j->{cwd} && $j->{cwd} ne '') ? $j->{cwd} : $cwd0;
    my $c = ref $j->{message} eq 'HASH' ? $j->{message}{content} : undef;
    if ($type eq 'user') {
        _bg_user($st, $j, $c, $ts) if ($st->{drv} && ($st->{drv}{mode} // '') ne 'ended') || (ref $st->{bg} eq 'HASH' && %{ $st->{bg} });
        return if $j->{isMeta} || $j->{isCompactSummary} || $j->{isVisibleInTranscriptOnly};
        my $t = !ref $c ? ($c // '')
              : ref $c eq 'ARRAY' ? join("\n", map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @$c) : '';
        # Claude Code writes a typed command as the row's whole text, starting with its tags; tags
        # anywhere else are quoted in a prompt.
        if ($t =~ m{\A\s*<command-(?:message|name)>} && $t =~ m{<command-name>/?([^<\s]+)</command-name>(?:\s*<command-args>(.*?)</command-args>)?}s) {
            _invoked($st, 'typed', $1, $2, $cwd, $ts, $j->{stackedExpansion} ? 1 : 0);
        } elsif (_human($j, $t)) {
            _prompt($st, $ts);
        } elsif (my $nk = _note($t)) {
            _own_note($st, $nk);
        } elsif ($t =~ /\S/ && !(ref $c eq 'ARRAY' && grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'tool_result' } @$c)) {
            # a task or teammate notification or an interruption mark opens a turn (no tool result);
            # another session's message (no hand-back or teammate report of background work) opens a
            # turn that answers it: what runs there is not the loop's (no spawn, write or command)
            my $D = $st->{drv};
            if ($D && $D->{mode} ne 'ended') {
                _turn_open($D);
                $D->{peer} = 1 if $t =~ /\A\s*Another Claude session sent a message/ && $t !~ /<(?:agent|teammate)-message\b/;
            }
        }
        return;
    }
    return unless $type eq 'assistant' && ref $c eq 'ARRAY';
    for my $it (@$c) {
        next unless ref $it eq 'HASH' && ($it->{type} // '') eq 'tool_use' && ref $it->{input} eq 'HASH';
        my ($n, $in) = ($it->{name} // '', $it->{input});
        my $D0 = $st->{drv};
        # (never in a turn or a skill of this plugin's own: its handoff and its resume are no loop work)
        _act($D0) if $D0 && ($D0->{sp} || ($D0->{mode} eq 'paused' && $D0->{pause}{self})) && !_plug($D0)
            && _activity($st, $n, $in, $cwd);
        if ($n eq 'Skill') {
            _invoked($st, 'Skill', $in->{skill}, $in->{args}, $cwd, $ts) if defined $in->{skill} && !ref $in->{skill};
        } elsif ($n eq 'Bash') {
            my $D = $st->{drv};
            if ($D && $D->{mode} eq 'paused') {
                $D->{pause}{done} = 1 if !$D->{pause}{self} && _pause_write($in->{command});
            } elsif ($D && $D->{mode} ne 'ended' && _self_pause($in->{command}, $D->{ws})) {
                $D->{sp} //= { seq => $st->{seq}, ts => $ts };
            }
            for my $b (@{ bash_calls($in->{command}) }) {
                my $root = $b->{cwd} // $cwd;
                $st->{gsd} = { via => 'Bash', name => "gsd-tools $b->{verb}", args => '', hidden => 0, ts => $ts, root => $root };
                _push_root($st, $root);
                # a status look's own reads name no workstream of the session's
                my $look = $st->{look} && _read_run($b) ? 1 : 0;
                $st->{wseq} = ($st->{seq} // 0) + 1 unless $look;
                _drv_tool($st, $b, $ts);
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
            _drv_write($st, $ws, $rel, $ts, $n);
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
            my $D = $st->{drv} or next;
            # Work after a pause that the transcript does not tie to the loop: ambiguous.
            if ($D->{mode} eq 'paused') { $D->{after} = 1 }
            # A spawn keeps a working loop's time, but after a human prompt it is as likely the
            # session's own (research, a review) as the loop's: it never outweighs the prompt.
            elsif ($D->{mode} ne 'ended' && _mine($D)) { $D->{wts} = $ts if defined $ts }
        }
    }
    my $sr = ref $j->{message} eq 'HASH' ? ($j->{message}{stop_reason} // '') : '';
    my $mid = ref $j->{message} eq 'HASH' && defined $j->{message}{id} && !ref $j->{message}{id} ? $j->{message}{id} : undef;
    if ($sr eq 'end_turn') {
        # The checkpoint this plugin's nudge asked for, in the turn it closed (any row of its last
        # message): `Step 1: none: task done` says the loop finished.
        my $D = $st->{drv};
        if ($D && $D->{mode} ne 'ended' && ($D->{nudged} || (defined $mid && defined $D->{nmid} && $mid eq $D->{nmid}))) {
            my $t = join("\n", map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @$c);
            # (`Step 1:` on the Checkpoint line or the next one; any dash, colon or comma after `none`)
            $D->{done} //= $ts // 0
                if $t =~ /(?:\A|\n)[ \t>*_-]*Checkpoint:[^\n]*?(?:\n[ \t>*_-]*)?\bStep 1:[ \t*_]*none\b[^\w\n]{0,8}task done/;
        }
        _turn_end($st, $ts, $mid);
    } elsif ($sr ne '' && $sr ne 'tool_use' && $sr ne 'pause_turn' && $st->{drv}) {
        # an API error (stop_sequence) or a cut-off turn: no stop, but no nudge or plugin turn
        # carries over into what comes next
        delete @{ $st->{drv} }{qw(nudged own)};
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
                return _bg_add($st, $k, 'a', $ts, [ @$r{qw(agentId taskId name teammate_id agent_id)} ]);
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
    _bg_text($st, $t);
}

# A notification's text (a user row's, or one Claude Code queued while a turn ran: a queued_command
# attachment or a queue-operation row): it closes the background work it names. A task notification
# names its tool call (the launch, or the SendMessage that woke it) and its task id; a Monitor's
# event notifications (no status) leave it running. A background agent's message back and a
# teammate's idle notification close it too; a teammate's other messages are interim.
sub _bg_text {
    my ($st, $t) = @_;
    return unless defined $t && !ref $t && ref $st->{bg} eq 'HASH' && %{ $st->{bg} };
    if ($t =~ m{\A\s*<task-notification>}) {
        while ($t =~ m{<task-notification>(.*?)(?:</task-notification>|\z)}gs) {
            my $b = $1;
            next if $b =~ m{<summary>\s*Monitor event\b};
            _bg_close($st, $1) if $b =~ m{<tool-use-id>([^<\s]+)</tool-use-id>};
            if ($b =~ m{<task-id>([^<\s]+)</task-id>}) {
                my $id = $1;    # the <status> match below would reset $1
                _bg_close($st, $id) if $b =~ m{<status>};
            }
        }
        return;
    }
    _bg_close($st, $1) while $t =~ m{<agent-message from="([^"\s]+)"}g;
    # A teammate shut down while it worked sends no idle report: its shutdown approval or Claude
    # Code's termination notice closes it.
    _bg_close($st, $1) while $t =~ m{<teammate-message teammate_id="([^"\s]+)"[^>]*>\s*\{\s*"type"\s*:\s*"shutdown_approved"}g;
    _bg_close($st, $1) while $t =~ m{\{\s*"type"\s*:\s*"teammate_terminated"\s*,\s*"message"\s*:\s*"([^"\s]+) has shut down}g;
    while ($t =~ m{<teammate-message teammate_id="([^"\s]+)"[^>]*>\s*(\{\s*"type"\s*:\s*"idle_notification"[^\n]*)}g) {
        my ($who, $js) = ($1, $2);
        # an idle report sent before a SendMessage woke the teammate again (they crossed) is old
        my $k = _bg_key($st, $who) // next;
        my $x = $st->{bg}{$k};
        my $at = $js =~ /"timestamp"\s*:\s*"([^"]+)"/ ? util::parse_iso($1) : undef;
        next if defined $at && ref $x eq 'HASH' && defined $x->{ts} && $at < $x->{ts};
        delete $st->{bg}{$k};
    }
}

# The tool call id of the background work an id names (its own, or an alias), or undef.
sub _bg_key {
    my ($st, $id) = @_;
    return undef unless defined $id && !ref $id && $id ne '';
    my $x = ref $st->{bgid} eq 'HASH' ? $st->{bgid}{$id} : undef;
    return $x->{k} if ref $x eq 'HASH';
    return (ref $st->{bg} eq 'HASH' && $st->{bg}{$id}) ? $id : undef;
}

sub _bg_close {
    my ($st, $id) = @_;
    my $k = _bg_key($st, $id) // return;
    delete $st->{bg}{$k} if ref $st->{bg} eq 'HASH';
}

# Background work launched or woken (key: its tool call id; ids: its other names). It belongs to
# the open driver (not a paused one, not in a turn of this plugin's own); launched in the loop's own
# work, an earlier turn end is no stop any longer.
sub _bg_add {
    my ($st, $key, $kind, $ts, $ids, %x) = @_;
    my $D = $st->{drv};
    return unless defined $key && $D && $D->{mode} ne 'ended' && $D->{mode} ne 'paused' && !$D->{own};
    my $bg = $st->{bg} = ref $st->{bg} eq 'HASH' ? $st->{bg} : {};
    my $old = ref $bg->{$key} eq 'HASH' ? $bg->{$key} : {};
    $bg->{$key} = { %$old, k => $kind, n => ++$st->{bgn}, d => $D->{id} // 0, (defined $ts ? (ts => $ts) : ()), %x };
    $bg->{$key}{k} = $old->{k} if defined $old->{k} && $kind eq 'a';    # a woken task keeps its kind
    if (keys %$bg > $BG_KEEP) { my ($o) = sort { $bg->{$a}{n} <=> $bg->{$b}{n} } keys %$bg; delete $bg->{$o} }
    my $ix = $st->{bgid} = ref $st->{bgid} eq 'HASH' ? $st->{bgid} : {};
    for my $id (grep { defined && !ref && $_ ne '' && $_ ne $key } @{ $ids || [] }) { $ix->{$id} = { k => $key, n => $st->{bgn} } }
    if (keys %$ix > 4 * $BG_KEEP) {
        my @o = sort { $ix->{$a}{n} <=> $ix->{$b}{n} } keys %$ix;
        delete @$ix{ @o[0 .. $#o - 4 * $BG_KEEP] };
    }
    delete @$D{qw(tend tw done)} if _mine($D);
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
        my $bgo = ref $st->{bg} eq 'HASH' && %{ $st->{bg} } ? 1 : 0;
        # A notification Claude Code queued while a turn ran (a queued_command attachment, a
        # queue-operation row) closes the background work it names, as a user row does.
        if ($bgo && (index($l, '<task-notification>') >= 0 || index($l, 'agent-message from=') >= 0 || index($l, 'idle_notification') >= 0
                     || index($l, 'shutdown_approved') >= 0 || index($l, 'teammate_terminated') >= 0)
            && index($l, '"type":"user"') < 0 && index($l, '"type":"assistant"') < 0 && length($l) <= $ROW_MAX) {
            my $j = eval { jsonc::decode($l) };
            if (ref $j eq 'HASH' && !$j->{isSidechain}) {
                _bg_text($st, ref $j->{attachment} eq 'HASH' ? $j->{attachment}{prompt} : $j->{content});
            }
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
            # a typed command, or a prompt a person wrote while a driver or a status look is open,
            # or (while a driver is open, or background work runs) background work launched or ending
            my $open = $st->{drv} && ($st->{drv}{mode} // '') ne 'ended';
            next if index($l, '<command-name>') < 0
                && !(($open || $st->{look}) && index($l, '"isMeta":true') < 0 && index($l, '"type":"tool_result"') < 0)
                && !(($open || $bgo) && $l =~ /_launched"|"teammate_spawned"|<agent-message from=|"backgroundTaskId"|idle_notification|shutdown_approved|teammate_terminated|"timeoutMs"|"scheduledFor"|"humanSchedule"|"task_type"|"resumedAgentId"|"success":true|<task-notification>/);
        } else {
            # spawns, a pause's files, turn ends and (while a loop pauses itself) any tool call
            # matter only while a driver is open
            next unless index($l, '"type":"assistant"') >= 0;
            my $D = $st->{drv} && ($st->{drv}{mode} // '') ne 'ended' ? $st->{drv} : undef;
            next unless ($D && $l =~ /"stop_reason":"(?:end_turn|stop_sequence|max_tokens|refusal)"/)
                || (index($l, '"tool_use"') >= 0
                    && (index($l, '"Skill"') >= 0 || index($l, 'gsd') >= 0 || index($l, '.planning/') >= 0
                        || (($D || $bgo) && $l =~ /"name":"(?:Agent|Task|Workflow|SendMessage|TaskStop|KillShell|CronDelete|ScheduleWakeup)"/)
                        || ($D && ($D->{sp} || ($D->{mode} eq 'paused' && $D->{pause}{self} && !$D->{pause}{prompted})
                                   || index($l, 'HANDOFF.json') >= 0 || index($l, '.continue-here') >= 0))));
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
        # A GSD loop re-enters with its own workstream (else the session's; a listed superpowers
        # driver takes no GSD flags) and, a GSD command, with its GSD root; another loop keeps its
        # own root flag.
        # (a driver with no workstream of its own gets none: never one the session's other work named)
        my $dws = defined $D->{ws} ? $ws : undef;
        if (defined $D->{ws}) { my (undef, $v) = _ws_any($D->{ws}, $e{root}, @roots); $dws = $v if defined $v }
        if ($g && ($e{name} =~ /\Agsd-/ || !$DRIVERS{ $e{name} })) {
            $re .= " --ws $dws" if defined $dws && $re !~ /(?:\A|\s)--ws(?:\s|=)/;
            $re .= $cwdflag if $cwdflag ne '' && $e{name} =~ /\Agsd-/ && $re !~ /(?:\A|\s)--(?:cwd|repo|project-dir)(?:\s|=)/;
        }
        $mode = $D->{mode};
        my $why = $D->{why};
        my $at = defined $D->{pause}{ts} ? ' ' . util::stamp($D->{pause}{ts}) : '';
        if ($mode eq 'paused' && $D->{after}) {
            ($mode, $why) = ('hint', "paused$at, then other work");
        } elsif ($mode eq 'paused' && !$D->{pause}{done}) {
            # A pause asked for ("/gsd-pause-work when finished") whose files are not written yet.
            ($mode, $why) = ('hint', "pause asked$at, its files not written yet");
        }
        # Arguments that cannot be shown (prose: "read it only", "do not start yet"), none of the
        # parts a re-enter command keeps (--ws, resume, --repo/--cwd), and no GSD work of its
        # workstream after it: it may never have started (a listed non-GSD loop excepted).
        if ($mode eq 'active' && $e{hidden} && ($e{keep} // '') eq '' && !$D->{work} && ($e{name} =~ /\Agsd-/ || !$DRIVERS{ $e{name} })) {
            ($mode, $why) = ('hint', 'arguments not shown, no GSD work after it');
        }
        # R2: a human prompt and no loop work after it: the loop may have finished, stopped on its
        # own outcome or been set aside, which the transcript does not tell apart.
        if ($mode eq 'active' && ($D->{idle} // 0) >= $IDLE_PROMPTS) {
            ($mode, $why) = ('hint', 'no loop work since ' . (defined $D->{wts} ? util::stamp($D->{wts}) : 'it was invoked') . ' and a prompt after it');
        }
        # R2: the checkpoint this plugin's nudge asked for says the task is done.
        if ($mode eq 'active' && defined $D->{done}) {
            ($mode, $why) = ('hint', 'its checkpoint' . ($D->{done} ? ' ' . util::stamp($D->{done}) : '') . ' said the task is done');
        }
        # R2: its turn ended with none of its background work live and no loop work after it (its
        # final report, a stop, a wait for the user; a background command or a persistent monitor
        # that still ran may be a server or a watch), or it created a pause file in a turn that has
        # not ended.
        if ($mode eq 'active' && defined $D->{tend}) {
            ($mode, $why) = ('hint', 'its turn ended' . ($D->{tend} ? ' ' . util::stamp($D->{tend}) : '')
                             . (defined $D->{tw} ? " with only a $D->{tw} still running" : ' with nothing running') . ' and no loop work since');
        }
        if (($mode eq 'active' || $mode eq 'hint') && ref $D->{sp} eq 'HASH') {
            ($mode, $why) = ('hint', 'it wrote a pause file' . (defined $D->{sp}{ts} ? ' ' . util::stamp($D->{sp}{ts}) : '')
                             . (defined $D->{sp}{tl} ? ', and its background work still ran when its turn ended' : ', its turn not ended yet'));
        }
        # R2, R3: a GSD loop whose GSD root is another checkout that --cwd cannot name would run here.
        if ($mode eq 'active' && defined $nocwd && $e{name} =~ /\Agsd-/ && $re !~ /(?:\A|\s)--(?:cwd|repo|project-dir)(?:\s|=)/) {
            ($mode, $why) = ('hint', "its GSD root is another checkout whose path cannot be passed as --cwd");
        }
        # R1: a GSD loop it ran as its step after a prompt or while it was a hint: named, never run.
        if ($mode eq 'hint' && ref $D->{step} eq 'HASH') {
            my %s = %{ $D->{step} };
            $s{args} = _fix_ws($s{args}, $s{root}, @roots) if defined $s{args};
            $s{keep} = _fix_ws($s{keep}, $s{root}, @roots) if defined $s{keep};
            if (defined $s{ws}) { my (undef, $v) = _ws_any($s{ws}, $s{root}, @roots); $s{ws} = $v // $s{ws} }
            $why = ($why // 'unclear') . '; later step: ' . _cmd(\%s, 1);
        }
        # A flat GSD re-enter command goes where GSD's shared pointer points (no --ws of its own).
        my $dc = ($caution ne '' && $re !~ /(?:\A|\s)--ws(?:\s|=)/ && ($e{name} =~ /\Agsd-/ || !$DRIVERS{ $e{name} }))
            ? '; ' . substr($caution, 2, -1) : '';
        $out{driver} = $mode eq 'paused'
            ? 'Paused driver: ' . _cmd(\%e, 1) . ' (' . _when(\%e) . (defined $D->{pause}{ts} ? '; paused ' . util::stamp($D->{pause}{ts}) : '; paused')
              . "$dc) · re-enter (new session only): $re"
            : $mode eq 'hint'
            ? 'Was driving: ' . _cmd(\%e, 1) . ' (' . _when(\%e) . '; ' . ($why // 'unclear') . ") · re-enter only if Step 1 belongs to it: $re"
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
