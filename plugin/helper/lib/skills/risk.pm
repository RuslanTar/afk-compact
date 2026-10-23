package skills::risk;
# lib/skills/risk.pm: `risk --cmd-file FILE [--source own|foreign] [--cwd DIR]` (SR-7; spec §4
# Real risk, §12, §19 risk_classes; resume Rule 2). Owner: WP-skills.
#
# Classifies one command a handoff holds, never runs it. The command is read from a file the
# session wrote with its Write tool, so foreign text never reaches a shell line (REVIEW-NIGHT
# NR-03). Prints
#   risk: none (<read-only|recorded|test-build|own>)
# or
#   risk: ask (<class>[, <class>…])
#   classes: <outward, gate or production id>[, …]      (only when one matched)
#   note: <why a test or build run asks>                (only then)
# and exits 0; usage errors exit 64. One content-free `risk {source, result, classes}` row.
#
# The reference reading is tools/gates `risk_reference` over tests/fixtures/risk/corpus.tsv:
# a foreign command carries no real risk only when every pipeline segment (split on |, ||,
# &&, ;, & and newlines) matches readonly_cmd_re or test_build_re and no risk_classes,
# outward_classes, prod_classes or HARD secret_rules pattern matches the whole command. The
# code adds what the literals cannot see:
#   - read-outside: a path argument of a read-only segment whose real path is outside the work
#     tree (component by component), or a command run outside any work tree;
#   - write-outside: a write target (cp/mv/ln/tee/install/touch/mkdir/dd of=, a redirect) at
#     home, the root, a parent folder or a real path outside the work tree;
#   - recorded: a segment byte-identical to a command the plugin recorded in any session's
#     jobs.jsonl under the watch root lifts only `not-read-only`;
#   - test-build: a test_build_re segment counts only when the repository defines the target
#     (Makefile rule, package.json script, Rakefile, build.gradle*, gradlew) and no test or build
#     definition differs from HEAD (NR-23: the exemption ends once such a file changed);
#   - gate: the explicit gate classes name the first family that matches (env-write, then
#     infra-write, then deploy); a production class on a command that is not read-only is the
#     prod-write gate; a push whose destination is the remote's default branch, matches
#     protected_branch_re or an entry of the user's add-only protected_branches setting (owner
#     xxxxxxxx-29), or cannot be told (--all, --mirror, a detached HEAD) is protected-push;
#     without a refspec the current branch and its upstream's branch both count.
# Provisional readings (owner decisions open, recommended reading built): O-6 (this check in
# code at all); $PROD_WRITE_RE (which production commands are the prod-write gate); the
# test/build exemption refused while a $BUILD_DEF_RE file differs from HEAD (NR-23); an unknown
# push destination counts as protected.
# Source own (an own handoff or this session's summary, resume Rule 2): runs under the normal
# permission rules, so only gate, outward, production and credential-value ask.
use strict;
use warnings;
use utf8;
use File::Basename ();
use skills::util;
use skills::cli;
use skills::ctx;
use skills::core;
use skills::spec;
use skills::gitfacts;

our $CMD_MAX = 8192;
our $JOBS_MAX_BYTES = 16 * 1024 * 1024;

# Fixed print order of the risk class ids (spec §19 risk_classes).
our @ORDER = qw(gate outward production credential-value credential-read network opaque write-outside read-outside not-read-only);
my %RANK = map { $ORDER[$_] => $_ } 0 .. $#ORDER;
our %OWN_ASKS = map { $_ => 1 } qw(gate outward production credential-value);
# The gate families, first match names the gate (AT-AP-07: kubectl create secret is env-write).
our @GATE_FAMILY = qw(env-write infra-write deploy);
# Test and build definitions (spec §4 NR-23): a change to one ends the test/build exemption.
# REVIEW-NIGHT-3 R3-11: also the files that decide what such a run executes besides its target
# (Gemfile for `bundle exec`, .npmrc script-shell, .yarnrc.yml yarnPath, a JS test or build
# config, .cargo/config runner and rustc-wrapper, build.rs, the Gradle wrapper and *.gradle).
our $BUILD_DEF_RE = qr{(?:\A|/)(?:GNUmakefile|[Mm]akefile(?:\.[^/]*)?|[^/]*\.mk|package\.json|\.npmrc|\.yarnrc(?:\.yml)?|\.pnpmfile\.c?js|[^/]*\.config\.[cm]?[jt]s|\.babelrc(?:\.[^/]*)?|[Rr]akefile(?:\.rb)?|[^/]*\.rake|Gemfile|gems\.rb|\.bundle/config|[^/]*\.gradle(?:\.kts)?|gradle\.properties|gradle-wrapper\.properties|gradlew|buildSrc/.*|conftest\.py|pytest\.ini|tox\.ini|setup\.cfg|pyproject\.toml|Cargo\.toml|build\.rs|\.cargo/config(?:\.toml)?|rust-toolchain(?:\.toml)?|go\.mod|go\.work|\.envrc|\.gitlab-ci\.yml|\.husky/.*|\.github/workflows/.*|\.circleci/.*)\z};
our %WRITE_CMD = map { $_ => 1 } qw(cp mv ln tee install touch mkdir rsync dd truncate);
# Write verbs that make a production command the prod-write gate (SQL, HTTP, migrations, files).
our $PROD_WRITE_RE = qr/\b(?:insert|update|delete|drop|alter|truncate|create|grant|revoke|merge|upsert|replace|put|post|patch|apply|scale|restart|rollout|migrate|seed|reset|destroy|rm|mv|cp|write|exec)\b/i;

my $SEG_SPLIT = qr/\|\||&&|[|;&\n]/;

sub run {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'cmd-file=s', 'source=s', 'cwd=s');
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    die skills::cli::usage('--cmd-file FILE (Write the command to a file first; never pass it on the shell line)')
        unless defined $o->{'cmd-file'} && $o->{'cmd-file'} ne '';
    my $source = $o->{source} // 'foreign';
    die skills::cli::usage('--source own|foreign') unless $source =~ /\A(?:own|foreign)\z/;
    my $file = skills::util::abs_path($o->{'cmd-file'});
    die skills::cli::usage('--cmd-file: not a readable file') unless defined $file && -f skills::util::bytes($file) && -r _;
    my $raw = skills::util::read_file(skills::util::bytes($file), $CMD_MAX + 1);
    die skills::cli::usage('--cmd-file: not a readable file') unless defined $raw;
    my $cwd = defined $o->{cwd} && $o->{cwd} ne '' ? skills::util::abs_path($o->{cwd}) : skills::util::cwd();
    die skills::cli::usage('--cwd: not a folder') unless defined $cwd && -d skills::util::bytes($cwd);
    my $ctx = skills::ctx::new({});
    skills::ctx::resolve_sid($ctx, undef);
    my $r;
    if (length($raw) > $CMD_MAX || $raw =~ /\x00/) {
        $r = { result => 'ask', classes => ['opaque'], ids => [], why => undef, notes => [] };
    } else {
        my $cmd = skills::util::text($raw);
        $cmd =~ s/\r?\n\z//;
        die skills::cli::usage('--cmd-file: empty command') unless $cmd =~ /\S/;
        $r = classify($cmd, source => $source, cwd => $cwd, watch => $ctx->{watch});
    }
    if ($r->{result} eq 'none') {
        skills::cli::say("risk: none ($r->{why})");
    } else {
        skills::cli::say('risk: ask (' . join(', ', @{ $r->{classes} }) . ')');
        skills::cli::say('classes: ' . join(', ', @{ $r->{ids} })) if @{ $r->{ids} };
        skills::cli::say("note: $_") for @{ $r->{notes} };
    }
    $ctx->log('risk', { source => $source, result => $r->{result}, classes => $r->{classes} });
    return 0;
}

# classify(cmd, source => own|foreign, cwd => DIR, watch => DIR)
#   -> {result => none|ask, classes => [risk ids in @ORDER], ids => [outward/gate/prod ids],
#       why => read-only|recorded|test-build|own (none only), notes => [..]}
# Also used by heal-check for an own handoff's recipe (HC-1).
sub classify {
    my ($cmd, %a) = @_;
    my $source = $a{source} // 'foreign';
    my $cwd = $a{cwd} // skills::util::cwd();
    skills::spec::need(qw(readonly_cmd_re test_build_re risk_classes outward_classes explicit_gate_classes protected_branch_re));
    my (%hit, @ids, %id_seen, @notes);
    my $id = sub { my ($i) = @_; push @ids, $i unless $id_seen{$i}++ };

    # Whole-command classes from the literals: outward (gates named), production, HARD secrets,
    # and the risk_classes that carry their own pattern. Each is matched against the command as
    # written and as the shell reads it (_forms: quotes and backslashes removed, command words in
    # lower case; REVIEW-NIGHT-3 R3-06: `git pu"sh"`, `Git push` on a case-insensitive disk).
    my @forms = _forms($cmd);
    my $any = sub { my ($re) = @_; return scalar grep { $_ =~ $re } @forms };
    my %gates = map { $_ => 1 } @{ skills::spec::get('explicit_gate_classes') || [] };
    my (@gate_hits, @out_hits);
    for my $c (@{ skills::spec::get('outward_classes') || [] }) {
        next unless ref $c eq 'HASH' && defined $c->{re} && defined $c->{id};
        my $re = eval { qr/$c->{re}/ } or next;
        next unless $any->($re);
        if ($gates{ $c->{id} }) { push @gate_hits, $c->{id} } else { push @out_hits, $c->{id} }
    }
    my $prod = skills::core::prod();
    my $prod_id;
    for my $c (@{ $prod->{classes} || [] }) {
        next unless ref $c eq 'HASH' && defined $c->{re};
        if ($any->($c->{re})) { $prod_id = $c->{id} // 'prod'; last }
    }
    $hit{production} = 1 if defined $prod_id;
    my (@hard, %hard_seen);
    for my $f (@forms) {
        push @hard, grep { $_->{class} eq 'HARD' && !$hard_seen{ $_->{rule} }++ } @{ skills::core::secrets_scan($f) };
    }
    $hit{'credential-value'} = 1 if @hard;
    for my $c (@{ skills::spec::get('risk_classes') || [] }) {
        next unless ref $c eq 'HASH' && defined $c->{re} && !ref $c->{re};
        my $re = eval { qr/$c->{re}/ } or next;
        $hit{ $c->{id} } = 1 if $any->($re);
    }

    # Per segment: read-only, a defined test/build target, or recorded; else not-read-only.
    my $ro = skills::spec::regex_at('readonly_cmd_re') or die "spec-missing readonly_cmd_re\n";
    my $tb = skills::spec::regex_at('test_build_re') or die "spec-missing test_build_re\n";
    my $w = skills::gitfacts::where($cwd);
    my $top = $w->{in_git} ? (skills::util::abs_path($w->{worktree}) // $w->{worktree}) : undef;
    my ($recorded, $jobs_read) = (undef, 0);
    my %why;
    my $build_dirty;
    for my $seg (split $SEG_SPLIT, $cmd) {
        $seg =~ s/\A\s+|\s+\z//g;
        next if $seg eq '';
        if ($seg =~ $ro) {
            $why{'read-only'} = 1;
            my $out = _read_outside($seg, $cwd, $top);
            $hit{'read-outside'} = 1 if $out;
            next;
        }
        if ($seg =~ $tb) {
            $build_dirty //= _build_dirty($top);
            my $def = _defined_target($seg, $cwd, $top);
            if (!$def) { push @notes, 'the repository defines no such test or build target here' }
            elsif (@$build_dirty) { push @notes, 'a test or build definition differs from HEAD (' . join(', ', @$build_dirty[0 .. ($#$build_dirty < 2 ? $#$build_dirty : 2)]) . '); a test or build run asks' }
            else { $why{'test-build'} = 1; next }
        }
        if (!$jobs_read) { $recorded = _recorded_commands($a{watch}); $jobs_read = 1 }
        if ($recorded->{$seg} || $recorded->{$cmd}) {
            # A recorded command lifts only not-read-only: a write outside the tree still asks
            # (REVIEW-NIGHT-3 R3-09).
            $why{recorded} = 1;
            $hit{'write-outside'} = 1 if _write_outside($seg, $cwd, $top);
            next;
        }
        $hit{'not-read-only'} = 1;
        $hit{'write-outside'} = 1 if _write_outside($seg, $cwd, $top);
    }
    $hit{'read-outside'} = 1 if !defined $top && $why{'read-only'};
    @notes = () if !$hit{'not-read-only'};

    # Gates: the first family that matched, prod-write, protected-push.
    my ($family) = grep { my $g = $_; grep { $_ eq $g } @gate_hits } @GATE_FAMILY;
    $family //= $gate_hits[0];
    if (defined $family) { $hit{gate} = 1; $id->($family) }
    # A production command is a write (the prod-write gate) when an outward or destructive class
    # also matched or it holds a write verb; otherwise it stays `production` (a read the user's
    # setting or a scoped approval may cover, O-2). Without the job record's read-only mark the
    # code cannot know more; either way it asks.
    if (defined $prod_id && (@out_hits || @gate_hits || $any->($PROD_WRITE_RE))) { $hit{gate} = 1; $id->('prod-write') }
    if (grep { $_ eq 'push' || $_ eq 'force-push' } @out_hits) {
        if (_protected_push($cmd, $cwd, $top)) { $hit{gate} = 1; $id->('protected-push') }
    }
    if (@out_hits) { $hit{outward} = 1; $id->($_) for @out_hits }
    $id->($prod_id) if defined $prod_id;
    $id->($_) for map { $_->{rule} } @hard;

    my @classes = sort { $RANK{$a} <=> $RANK{$b} } grep { exists $RANK{$_} } keys %hit;
    @classes = grep { $OWN_ASKS{$_} } @classes if $source eq 'own';
    if (!@classes) {
        my $why = $source eq 'own' ? 'own' : $why{recorded} ? 'recorded' : $why{'test-build'} ? 'test-build' : 'read-only';
        return { result => 'none', classes => [], ids => [], why => $why, notes => [] };
    }
    my %keep = map { $_ => 1 } @classes;
    @notes = () unless $keep{'not-read-only'};
    return { result => 'ask', classes => \@classes, ids => \@ids, why => undef, notes => \@notes };
}

# Word split of one segment with the shell's quote removal: double-quoted and single-quoted
# parts and backslash escapes anywhere in a word (REVIEW-NIGHT-3 R3-01: `ma"in"` is `main`,
# `src/../"x"` a path), so the path and destination checks see the words the shell passes on.
sub _words {
    my ($seg) = @_;
    my (@w, $cur);
    my $n = length $seg;
    for (my $i = 0; $i < $n; $i++) {
        my $c = substr($seg, $i, 1);
        if ($c =~ /\s/) { push @w, $cur if defined $cur; undef $cur; next }
        $cur //= '';
        if ($c eq '\\') { $cur .= substr($seg, ++$i, 1) if $i + 1 < $n; next }
        if ($c eq "'") {
            my $j = index($seg, "'", $i + 1);
            $j = $n if $j < 0;
            $cur .= substr($seg, $i + 1, $j - $i - 1);
            $i = $j;
            next;
        }
        if ($c eq '"') {
            for ($i++; $i < $n && substr($seg, $i, 1) ne '"'; $i++) {
                $i++ if substr($seg, $i, 1) eq '\\' && $i + 1 < $n && substr($seg, $i + 1, 1) =~ /["\\\$`]/;
                $cur .= substr($seg, $i, 1);
            }
            next;
        }
        $cur .= $c;
    }
    push @w, $cur if defined $cur;
    return @w;
}

# The forms of a command the class patterns are matched against (REVIEW-NIGHT-3 R3-06): as
# written; with quotes and backslash escapes removed (what the shell runs: `git pu"sh"` is a
# push); and that with the first two words of each segment in lower case (`Git push`, `RM -rf`:
# a case-insensitive disk finds the program anyway).
sub _forms {
    my ($cmd) = @_;
    (my $dq = $cmd) =~ s/\\(.)/$1/gs;
    $dq =~ tr/"'//d;
    my @p = split /(\|\||&&|[|;&\n])/, $dq;
    for my $x (@p) {
        next if $x =~ /\A(?:\|\||&&|[|;&\n])\z/;
        $x =~ s/\A(\s*)(\S+)((?:\s+\S+)?)/$1 . lc($2) . lc($3)/e;
    }
    my $lc = join '', @p;
    my %seen;
    return grep { !$seen{$_}++ } ($cmd, $dq, $lc);
}

# 1 when the real path of $p (relative to $cwd) is outside $top, component by component.
sub _outside {
    my ($p, $cwd, $top) = @_;
    return 1 unless defined $top;
    my $abs = $p =~ m{\A/} ? $p : "$cwd/$p";
    my $real = skills::util::abs_path($abs);
    return 1 unless defined $real;
    return 0 if $real eq $top;
    return index("$real/", "$top/") == 0 ? 0 : 1;
}

# read-outside: an argument of a read-only segment that names an existing path outside the
# work tree (a symlink out of it included), or that steps out of it with `..` (REVIEW-NIGHT-2
# R2-04: `cat src/../../x`). An option's attached value counts as an argument (`git blame
# --contents=<path>`, `grep -f<path>`). Arguments that name nothing (a search pattern) do not
# count; home, root and parent-folder arguments never pass readonly_cmd_re.
sub _read_outside {
    my ($seg, $cwd, $top) = @_;
    return 1 unless defined $top;
    return 1 if _outside($cwd, $cwd, $top);
    my @w = _words($seg);
    shift @w;
    for my $t (@w) {
        next if $t eq '';
        for my $p (_path_parts($t)) {
            return 1 if _steps_out($p, $cwd, $top);
            my $abs = $p =~ m{\A/} ? $p : "$cwd/$p";
            next unless -e skills::util::bytes($abs) || -l skills::util::bytes($abs);
            return 1 if _outside($p, $cwd, $top);
        }
    }
    return 0;
}

# The path-like parts of one word: a plain word itself; an option's value after `=`
# (`--contents=<path>`); for a short option that holds a `/`, each tail after its option letters
# (`-f<path>`, `-nf<path>`), since the code cannot tell which letter takes the value.
sub _path_parts {
    my ($t) = @_;
    return ($t) unless $t =~ /\A-/;
    return ($1) if $t =~ /\A--?[A-Za-z0-9][A-Za-z0-9_-]*=(.+)\z/s;
    return () if $t =~ /\A--/ || index($t, '/') < 0;
    my $slash = index($t, '/');
    my @p;
    for my $i (2 .. $slash) {
        last unless substr($t, $i - 1, 1) =~ /[A-Za-z0-9]/;
        push @p, substr($t, $i);
    }
    return @p;
}

# 1 when a path with a `..` step leaves the work tree once its steps are applied to $cwd as
# written (a path that does not exist cannot be resolved; one that does is checked by _outside).
sub _steps_out {
    my ($p, $cwd, $top) = @_;
    return 0 unless $p =~ m{(?:\A|/)\.\.(?:/|\z)};
    my @c = $p =~ m{\A/} ? () : grep { $_ ne '' } split m{/}, $cwd;
    for my $x (split m{/}, $p) {
        next if $x eq '' || $x eq '.';
        if ($x eq '..') { return 1 unless @c; pop @c; next }
        push @c, $x;
    }
    my $n = '/' . join('/', @c);
    return 0 if $n eq $top;
    return index("$n/", "$top/") == 0 ? 0 : 1;
}

# write-outside: a write command or a redirect whose target is at home, the root, a parent
# folder, or a real path outside the work tree.
sub _write_outside {
    my ($seg, $cwd, $top) = @_;
    my @targets;
    while ($seg =~ /(?:\d?>>?|&>)\s*("[^"]*"|\S+)/g) { push @targets, $1 }
    my @w = _words($seg);
    my $verb = @w ? File::Basename::basename($w[0]) : '';
    $verb = File::Basename::basename($w[1] // '') if $verb eq 'sudo';
    if ($WRITE_CMD{$verb}) {
        for my $t (@w[1 .. $#w]) {
            next if !defined $t || $t =~ /\A-/ && $t !~ /\A--?[a-z-]+=/;
            $t =~ s/\A--?[a-z-]+=//;
            $t =~ s/\Aof=//;
            push @targets, $t;
        }
    }
    for my $t (@targets) {
        $t =~ s/\A"|"\z//g;
        next if $t eq '';
        return 1 if $t =~ m{\A(?:~|\$HOME|\$\{HOME\}|/|\.\.(?:/|\z))};
        return 1 if !defined $top;
        my $dir = $t =~ m{/} ? File::Basename::dirname($t) : '.';
        return 1 if _outside($dir, $cwd, $top);
        my $abs = $t =~ m{\A/} ? $t : "$cwd/$t";
        return 1 if -l skills::util::bytes($abs) && _outside($t, $cwd, $top);
    }
    return 0;
}

# The repository defines the target of a test_build_re segment (spec §4: make, npm, pnpm,
# yarn, rake, gradle); cargo, go and pytest need only to run inside the work tree.
sub _defined_target {
    my ($seg, $cwd, $top) = @_;
    return 0 unless defined $top;
    return 0 if _outside($cwd, $cwd, $top);
    my @w = _words($seg);
    my $b = skills::util::bytes($cwd);
    my $read = sub { my ($f) = @_; return -f "$b/$f" ? skills::util::read_text("$b/$f", 1048576) : undef };
    if ($w[0] eq 'make') {
        my $t = $w[1] // return 0;
        for my $mf (qw(GNUmakefile makefile Makefile)) {
            my $text = $read->($mf) // next;
            return ($text =~ /^\Q$t\E[ \t]*(?:[ \t][^:=\n]*)?::?(?![=])/m) ? 1 : 0;
        }
        return 0;
    }
    if ($w[0] eq 'rake' || ($w[0] eq 'bundle' && ($w[2] // '') eq 'rake')) {
        return (grep { -f "$b/$_" } qw(Rakefile rakefile Rakefile.rb rakefile.rb)) ? 1 : 0;
    }
    if ($w[0] eq 'gradle' || $w[0] eq './gradlew') {
        return 0 if $w[0] eq './gradlew' && !-f "$b/gradlew";
        return (grep { -f "$b/$_" } qw(build.gradle build.gradle.kts settings.gradle settings.gradle.kts)) ? 1 : 0;
    }
    if ($w[0] =~ /\A(?:npm|pnpm|yarn)\z/) {
        my $script = ($w[1] // '') eq 'run' ? $w[2] : $w[1];
        return 0 unless defined $script;
        my $pj = $read->('package.json') // return 0;
        my $j = eval { skills::util::json_decode($pj) };
        return 0 unless ref $j eq 'HASH' && ref $j->{scripts} eq 'HASH';
        return defined $j->{scripts}{$script} ? 1 : 0;
    }
    return 1 if $w[0] =~ /\A(?:cargo|go|pytest|python3?)\z/;
    return 0;
}

# Test and build definitions that differ from HEAD in the work tree (tracked changes and
# untracked files), as paths relative to the top; [] outside git or when git fails.
sub _build_dirty {
    my ($top) = @_;
    return [] unless defined $top;
    my $r = skills::gitfacts::git($top, 'status', '--porcelain', '--untracked-files=all');
    return [] unless $r->{rc} == 0;
    my @f;
    for my $l (split /\n/, $r->{out}) {
        next unless length($l) > 3;
        my $p = substr($l, 3);
        $p =~ s/\A.* -> //;
        $p =~ s/\A"|"\z//g;
        push @f, $p if $p =~ $BUILD_DEF_RE;
    }
    return \@f;
}

# {command => 1} of every command the plugin recorded (jobs.jsonl in each session folder under
# the watch root), byte for byte; withheld commands are absent.
sub _recorded_commands {
    my ($watch) = @_;
    my %c;
    return \%c unless defined $watch && -d skills::util::bytes($watch);
    my $budget = $JOBS_MAX_BYTES;
    for my $d (skills::util::list_dir($watch)) {
        my $f = "$watch/$d/jobs.jsonl";
        next unless -f skills::util::bytes($f);
        my $t = skills::util::read_text($f, $budget) // next;
        $budget -= length $t;
        for my $l (split /\n/, $t) {
            my $j = eval { skills::util::json_decode($l) };
            next unless ref $j eq 'HASH' && defined $j->{command} && !ref $j->{command} && $j->{command} ne '';
            $c{ $j->{command} } = 1;
        }
        last if $budget <= 0;
    }
    return \%c;
}

# protected-push: the destination branch of a git push is the remote's default branch, matches
# protected_branch_re (lower-cased) or names an entry of the user's protected_branches setting
# (owner xxxxxxxx-29: added to the shipped list, never removing from it). Unknown destinations
# count as protected.
sub _protected_push {
    my ($cmd, $cwd, $top) = @_;
    my $pbr = skills::spec::get('protected_branch_re');
    my $pre = defined $pbr ? eval { qr/$pbr/ } : undef;
    my $pb = skills::core::protected();

    for my $seg (split $SEG_SPLIT, $cmd) {
        my @w = _words($seg);
        my ($gi) = grep { lc($w[$_]) eq 'git' } 0 .. $#w;
        next unless defined $gi;
        my $pi;
        for my $i ($gi + 1 .. $#w) {
            if ($w[$i] eq '-C' || $w[$i] eq '-c') { next }
            if ($w[$i] eq 'push') { $pi = $i; last }
        }
        next unless defined $pi;

        my @pos;
        for my $t (@w[$pi + 1 .. $#w]) {
            return 1 if $t =~ /\A--(?:all|mirror|branches)\z/;
            next if $t =~ /\A-/;
            push @pos, $t;
        }
        my $remote = shift(@pos) // 'origin';
        my @dst;
        if (@pos) {
            for my $rs (@pos) {
                my $d = $rs =~ /:/ ? (split /:/, $rs, 2)[1] : $rs;
                $d =~ s/\A\+//;
                $d =~ s{\Arefs/heads/}{};
                return 1 if $d eq '' && $rs !~ /\A:/;
                next if $d eq '' || $d =~ m{\Arefs/tags/};
                push @dst, $d;
            }
            next unless @dst;
        } else {
            push @dst, 'HEAD';
            # No refspec: push.default may send the branch to its upstream under another name
            # (`upstream`, `tracking`), so the upstream's branch counts too (REVIEW-NIGHT-2 R2-05).
            if (defined $top) {
                my $u = skills::gitfacts::line(skills::gitfacts::git($cwd, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}'));
                push @dst, $1 if defined $u && $u =~ m{\A[^/]+/(.+)\z};
            }
        }
        my $def;
        if (defined $top && $remote =~ /\A[A-Za-z0-9._-]+\z/) {
            $def = skills::gitfacts::line(skills::gitfacts::git($cwd, 'symbolic-ref', '--short', '-q', "refs/remotes/$remote/HEAD"));
            $def =~ s{\A\Q$remote\E/}{} if defined $def;
        }
        for my $d (@dst) {
            if ($d eq 'HEAD' || $d eq '@') {
                # No refspec, or HEAD: the current branch; a detached HEAD or no repository
                # cannot be told, so it counts as protected.
                return 1 unless defined $top;
                $d = skills::gitfacts::line(skills::gitfacts::git($cwd, 'symbolic-ref', '--short', '-q', 'HEAD'));
                return 1 unless defined $d;
            }
            return 1 if defined $def && $d eq $def;
            return 1 if !defined $pre || lc($d) =~ $pre;
            return 1 if defined skills::core::protected_user($d, $pb);
        }
    }
    return 0;
}

1;
