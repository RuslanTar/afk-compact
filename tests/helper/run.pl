#!/usr/bin/perl
# tests/helper/run.pl: the H-test case runner (BUILD-PLAN §3.5). Owner: WP-core.
# Runs `scripts/<name>-store` (a staged copy of plugin/) for every tests/helper/cases/**/case.json
# given on the command line (files or folders), each case in a fresh temporary HOME
# with STORE_TEST_MODE=1, and asserts exit codes, stdout, files, log rows and traces.
#
# Usage: tests/helper/run.pl [--filter RE] [--keep] [-v] [--fixtures DIR] <case dir|case.json|cases root>...
#
# Case file (JSON): {"id", "sid"?, "tz"?, "env"?, "path_prepend"?, "needs"?: ["baseline","spec"],
#   "steps": [step...]}  or the one-step form of §3.5 (argv, stdin, setup, expect, then).
# Step: {"argv", "stdin" (file in the case dir or tests/fixtures/), "stdin_json", "stdin_text",
#   "env", "now", "setup": [...], "parallel": N, "kill_after_ms": N (+ "kill_signal", default KILL),
#   "expect": {...}}
# Setup actions: write (text|json|parts|bytes|lines; mode; mtime_ago_s), copy, mkdir, symlink (+ to),
#   repo (git recipe), dispatch (record fields + age_s), transcript (rows; boundary/prompt
#   shortcuts), stub (executable script), run (a helper call without assertions).
# Placeholders in every string: $TMP $HOME $ROOT $WATCH $SID $SID8 $PLUGIN $FIX $CASE
#   $BRAND $HOST $CLAUDE_BIN $DISP $TODAY $LSTART1 (pid 1's start time), $PLUGIN_VERSION, $STORE (the
#   real path of the staged launcher, $PLUGIN/scripts/$BRAND-store), plus every
#   variable a step captured.
# Additions used by the WP-skills cases (one runner for every layer, BUILD-PLAN §3.5):
#   case "tmp_base": "repo"  the case's temp dir sits under the repo's git-ignored tmp/,
#                            not the system temp folder (the publish lint treats paths
#                            under /tmp, /private/tmp and /var/folders as ephemeral)
#   step "cwd"               the helper's working directory (default: the case's $TMP)
#   step "capture"           {VAR: "json:<dotted path>" | "re:<regex, one group>"} from stdout
#   case / step "options"  {key: value}: plugin options in $HOME/.claude/settings.json
#                            (pluginConfigs["<brand>@m"].options, merged), for file-only keys
#   case "stage_overlay"   {"<path under plugin/>": "<file>"}: a staged copy with those files replaced
#   a step without argv, lib or setup that holds a setup action runs as a setup step
#   setup: write with content | content_parts (mode 0600 unless given); repo {recipe} + at;
#     git [argv] (+ cwd, env, var = stdout); bigfile + bytes (+ fill); age + minutes;
#     run (+ capture, exit)
#   expect: stdout_has / stdout_lacks (regexes, /m); json_keys; json {dotted path: value |
#     {re} | {null} | {len} | {present} | {max_bytes}}; files has / lacks (regexes, /m)
# Fixture recipes (tests/fixtures/README.md), used by the AT-E cases:
#   setup: normalized_sha <path> + var (the normalized body's sha256 into $<var>);
#   setup: tempfiles <recipe> (+ tmp, record, sid); secret_files <dir> (+ record, sid);
#     write + jsonl_repeat {row, count} (then any jsonl rows); write + jsonl + jsonl_pad
#     {key (dotted), text, bytes} (the first row's key holds text repeated to bytes);
#     repo_fixture <recipe> + at; paths [..] (+ sid) appends paths.jsonl rows; copy + mode
#     (+ subst: true fills the placeholders in the copied text)
#   builtin detect_tsv {tsv, sha: "template"}: expected shas over the body with {{plugin}}
#   placeholders: $SECRET{<id>} (joined corpus fragments), {{plugin}}, {{marketplace}}, $FIXTURES,
#     $TYPES (claude-code.d.ts; case "needs": ["types"] skips without it; "fixture:<path>" skips
#     while tests/fixtures/<path> is missing (a WP-fix fixture not merged yet); "nocase-fs" skips
#     where the temp folder is case-sensitive; "docker-image:<ref>" skips unless a Docker daemon
#     answers and holds that image locally; "docker-image-any:<ref>|<ref>" unless it holds one)
# The secret corpus rule: text that looks like a secret is given as "parts" and joined
# here, so no file in the repo holds a whole token-shaped string.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
use POSIX ();
use Fcntl qw(O_WRONLY O_CREAT O_TRUNC);

my $HERE;
BEGIN { $HERE = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
my $REPO = Cwd::abs_path("$HERE/../..");
use lib Cwd::abs_path(File::Basename::dirname(Cwd::abs_path(__FILE__)) . '/../../plugin/helper/lib');
require "util.pm";
require "jsonc.pm";
require "sha.pm";

# DP-12: messages hold characters (decoded case text and helper output); raw bytes are
# decoded before they are printed (see say_raw), so nothing prints "Wide character".
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

# BH-6 (small-rulings §5.3 R1-R5): the work dirs go as soon as they are not needed. A
# passing case's c<N> is removed when it passes; at the end a failing run keeps only the
# failed cases' c<N> and stage/ (`# kept:`); a run that dies or is killed (INT, TERM,
# HUP) cleans up the same way in END. Only this process cleans: forked children never do.
my $OWNER_PID = $$;
my ($RUN_TMP, $REPO_TMP, $CLEANED, @FAILED_DIRS, %KIDS);
my ($FILTER, $KEEP, $VERBOSE, $PLUGIN_SRC, $REPO_TMP_BASE, $FIXTURES_DIR, @ARGS);
$SIG{$_} = sub { exit 130 } for qw(INT TERM HUP);
END {
    my $code = $?;
    cleanup() if defined $OWNER_PID && $$ == $OWNER_PID;
    $? = $code;
}

while (@ARGV) {
    my $a = shift @ARGV;
    if ($a eq '--filter') { $FILTER = shift @ARGV; next }
    if ($a eq '--keep') { $KEEP = 1; next }
    if ($a eq '-v') { $VERBOSE = 1; next }
    # Self-test hooks (AT-RN-04, AT-RN-05): stage another plugin tree; use another folder
    # in place of <repo>/tmp for tmp_base "repo" cases.
    if ($a eq '--plugin') { $PLUGIN_SRC = shift @ARGV; next }
    if ($a eq '--repo-tmp') { $REPO_TMP_BASE = shift @ARGV; next }
    # Check a WP-fix fixture set before it merges: read tests/fixtures/ from DIR (an export of
    # that branch's tests/fixtures), for "fixture:" needs, $FIX, $FIXTURES, stdin and copy sources.
    if ($a eq '--fixtures') { $FIXTURES_DIR = Cwd::abs_path(shift @ARGV); next }
    push @ARGS, $a;
}
@ARGS = ("$HERE/cases") unless @ARGS;
$REPO_TMP_BASE //= "$REPO/tmp";
$FIXTURES_DIR //= "$REPO/tests/fixtures";
$REPO_TMP_BASE =~ s{/+$}{};

my ($BRAND, $MARKETPLACE) = do { my $b = jsonc::decode(util::read_file("$REPO/brand.json")); ($b->{name}, $b->{marketplace} // $b->{name}) };
# The launcher folder (PKG-RUNTIME A.1): one constant, as in tools/build, deps.ts and ctx.pm.
my $LAUNCHER_DIR = 'scripts';
my $HOSTNAME = (POSIX::uname())[1];
my $CLAUDE_BIN = find_claude_bin();
my $DEFAULT_SID = '11111111-2222-4333-8444-555555555555';
my $DEFAULT_PID = '424242:Tue Oct 21 09:00:00 2026';

# The Claude Code type declarations (tools/typecheck: CC_TYPES_DIR, else the repo's .types/ copy).
sub types_file {
    return $ENV{CC_TYPES_DIR} ? "$ENV{CC_TYPES_DIR}/claude-code.d.ts" : "$REPO/.types/claude-code.d.ts";
}

sub find_claude_bin {
    my $vdir = util::home() . '/.local/share/claude/versions';
    my @v = sort { my @x = split /\./, $a; my @y = split /\./, $b; $x[0] <=> $y[0] || $x[1] <=> $y[1] || $x[2] <=> $y[2] }
            grep { /^\d+\.\d+\.\d+$/ } util::list_dir($vdir);
    return @v ? "$vdir/$v[-1]" : '';
}

# ---------------------------------------------------------------- staging
$RUN_TMP = do {
    my $base = $ENV{TMPDIR} && -d $ENV{TMPDIR} ? $ENV{TMPDIR} : '/tmp';
    $base =~ s{/+$}{};
    my $d = "$base/store-h-" . $$ . '-' . util::rand_hex(6);
    util::mkdir_p($d);
    $d;
};
my %STAGE_INFO;
my $STAGE = stage_plugin("$RUN_TMP/stage/plugin");
sub repo_tmp {
    return $REPO_TMP if $REPO_TMP;
    $REPO_TMP = "$REPO_TMP_BASE/store-h-" . $$ . '-' . util::rand_hex(6);
    util::mkdir_p($REPO_TMP);
    return $REPO_TMP;
}
my $RUNNER_LSTART;
sub runner_lstart {
    return $RUNNER_LSTART if defined $RUNNER_LSTART;
    my $r = util::run(['ps', '-o', 'lstart=', '-p', $$], timeout_ms => 5000, env => { LC_ALL => 'C' });
    ($RUNNER_LSTART = $r->{out} // '') =~ s/\s+/ /g;
    $RUNNER_LSTART =~ s/\A | \z//g;
    return $RUNNER_LSTART;
}
my $LSTART1 = do {
    my $r = util::run(['ps', '-o', 'lstart=', '-p', '1'], timeout_ms => 5000);
    (my $v = $r->{out} // '') =~ s/\s+/ /g;
    $v =~ s/\A | \z//g;
    $v;
};

sub copy_tree {
    my ($src, $dst) = @_;
    util::mkdir_p($dst);
    for my $e (util::list_dir($src)) {
        next if $e eq 'node_modules';
        my ($s, $d) = ("$src/$e", "$dst/$e");
        if (-l $s) { symlink(readlink($s), $d); next }
        if (-d $s) { copy_tree($s, $d); next }
        util::copy_file($s, $d, mode => ((stat $s)[2] & 07777));
    }
    chmod((stat $src)[2] & 07777, $dst);
}

sub stage_plugin {
    my ($dst) = @_;
    copy_tree($PLUGIN_SRC // "$REPO/plugin", $dst);
    my $launcher = "$dst/$LAUNCHER_DIR/$BRAND-store";
    die "run.pl: no launcher at plugin/$LAUNCHER_DIR/$BRAND-store (run tools/build)\n" unless -x $launcher;
    # CR-F34: in this staged copy (and with STORE_TEST_MODE=1) the consent keys come from the
    # case's $HOME/.claude/settings.json; without the file, from the account's home.
    util::write_atomic("$dst/.test-consent-home", "helper test stage\n", 0644);
    if (!-f "$dst/assets/handoff-spec.json") {
        my $tmpl = util::read_file("$HERE/cases/core/_support/handoff-spec.json");
        die "run.pl: no assets/handoff-spec.json and no interim spec\n" unless defined $tmpl;
        $tmpl =~ s/\{\{plugin\}\}/$BRAND/g;
        util::write_atomic("$dst/assets/handoff-spec.json", $tmpl, 0644);
        $STAGE_INFO{spec} = 'interim (tests/helper/cases/core/_support)';
    } else {
        $STAGE_INFO{spec} = 'plugin/assets';
    }
    if (!-f "$dst/assets/canary-baseline.json") {
        my $types = $ENV{CC_TYPES_DIR} ? "$ENV{CC_TYPES_DIR}/claude-code.d.ts" : "$REPO/.types/claude-code.d.ts";
        if (-f $types && -x "$REPO/tools/canary-baseline") {
            my $r = util::run(["$REPO/tools/canary-baseline", '--types', $types, '--out', "$dst/assets/canary-baseline.json"],
                              timeout_ms => 120000);
            $STAGE_INFO{baseline} = $r->{exit} == 0 ? 'generated' : 'unavailable';
        } else {
            $STAGE_INFO{baseline} = 'unavailable';
        }
    } else {
        $STAGE_INFO{baseline} = 'plugin/assets';
    }
    return $dst;
}

# stage_variant({dotted path => value}, dst) -> a copy of the staged plugin at dst whose
# .claude-plugin/plugin.json has those values set (paths below the top level object).
sub stage_variant {
    my ($patch, $dst) = @_;
    copy_tree($STAGE, $dst);
    my $mf = "$dst/.claude-plugin/plugin.json";
    my $m = jsonc::decode(util::read_file($mf));
    for my $path (sort keys %$patch) {
        my @k = split /\./, $path;
        my $last = pop @k;
        my $h = $m;
        for my $k (@k) { $h->{$k} = {} unless ref $h->{$k} eq 'HASH'; $h = $h->{$k} }
        $h->{$last} = $patch->{$path};
    }
    util::write_atomic($mf, jsonc::encode_bytes($m) . "\n", 0644);
    return $dst;
}

# ---------------------------------------------------------------- case discovery
sub find_cases {
    my ($p) = @_;
    return ($p) if -f $p && $p =~ /case\.json$/;
    return ("$p/case.json") if -f "$p/case.json";
    my @out;
    return @out unless -d $p;
    for my $e (util::list_dir($p)) {
        next if $e =~ /^[_.]/;
        push @out, find_cases("$p/$e") if -d "$p/$e";
    }
    return @out;
}

my @CASES = map { find_cases(Cwd::abs_path($_) // $_) } @ARGS;
my ($N, $FAILED, $SKIPPED) = (0, 0, 0);
my @FAIL_IDS;
print "# stage: spec $STAGE_INFO{spec}; baseline $STAGE_INFO{baseline}\n";

for my $cf (@CASES) {
    my $raw = util::read_file($cf);
    my $case = eval { jsonc::decode($raw) };
    if (!$case) { $N++; $FAILED++; print "not ok $N - $cf: case.json does not parse: $@"; next }
    my $id = $case->{id} // File::Basename::basename(File::Basename::dirname($cf));
    next if defined $FILTER && $id !~ /$FILTER/;
    $N++;
    my $miss = grep { ($_ eq 'baseline' && $STAGE_INFO{baseline} eq 'unavailable') || ($_ eq 'claude' && !$CLAUDE_BIN)
                      || ($_ eq 'docker' && !util::which('docker')) || ($_ eq 'darwin' && $^O ne 'darwin') || ($_ eq 'corpus' && !-f "$FIXTURES_DIR/summaries/expected.tsv")
                      || ($_ eq 'types' && !-f types_file()) || ($_ eq 'nocase-fs' && !nocase_fs())
                      || (/^docker-image:(.+)$/ && !docker_image($1))
                      || (/^docker-image-any:(.+)$/ && !grep { docker_image($_) } split /\|/, $1)
                      || (/^fixture:(.+)$/ && !-e "$FIXTURES_DIR/$1") } @{ $case->{needs} || [] };
    if ($miss) { $SKIPPED++; print "ok $N - $id # SKIP needs " . join(',', @{ $case->{needs} }) . "\n"; next }
    my @errs = eval { run_case($case, File::Basename::dirname($cf)) };
    push @errs, "runner error: $@" if $@;
    # The case's work dirs: c<N> under the system temp folder and, for tmp_base "repo"
    # cases, under the repo's tmp/.
    my @cdirs = grep { -d } map { "$_/c$N" } grep { defined } ($RUN_TMP, $REPO_TMP);
    if (@errs) {
        $FAILED++;
        push @FAIL_IDS, $id;
        push @FAILED_DIRS, @cdirs;
        print "not ok $N - $id\n";
        print map { "#   $_\n" } @errs;
    } else {
        print "ok $N - $id\n";
        # R1: a passing case's dirs go now, so a kill later leaves at most the case in flight.
        remove_in(util::dirname($_), util::basename($_)) for $KEEP ? () : @cdirs;
    }
}
print "1..$N\n";
print "# passed " . ($N - $FAILED - $SKIPPED) . ", failed $FAILED, skipped $SKIPPED\n";
print "# failed: @FAIL_IDS\n" if @FAIL_IDS;
cleanup();
exit($FAILED ? 1 : 0);

# cleanup(): R2-R4, once per run (the normal end, or END after a die or a signal). --keep
# keeps everything; a failed case keeps its c<N> dirs and stage/ (the staged plugin it ran
# against) and everything else goes; otherwise both work dirs go. Helper processes still
# running (a killed run) are stopped first, so none of them writes into a removed dir.
sub cleanup {
    return if $CLEANED++;
    for my $pid (keys %KIDS) { kill 'TERM', $pid }
    for my $pid (keys %KIDS) {
        my $t0 = util::clock_ms();
        while (waitpid($pid, POSIX::WNOHANG()) == 0) {
            if (util::clock_ms() - $t0 > 2000) { kill 'KILL', $pid; waitpid($pid, 0); last }
            util::sleep_ms(10);
        }
    }
    %KIDS = ();
    my @work = grep { defined && -d } ($RUN_TMP, $REPO_TMP);
    if ($KEEP) {
        print "# work dirs kept: @work\n" if @work;
    } elsif (@FAILED_DIRS) {
        my %keep = map { ($_ => 1) } @FAILED_DIRS, (defined $RUN_TMP ? "$RUN_TMP/stage" : ());
        for my $w (@work) {
            remove_in($w, grep { !$keep{"$w/$_"} } util::list_dir($w));
            rmdir $w;
        }
        print '# kept: ' . join(' ', sort grep { -d } keys %keep) . "\n";
    } else {
        remove_tree($_) for @work;
        print "# work dirs removed\n" if $VERBOSE;
    }
    # R4: the repo's tmp/ goes too when nothing else is in it (rmdir fails otherwise).
    rmdir $REPO_TMP_BASE if defined $REPO_TMP && -d $REPO_TMP_BASE;
}

# R5: a work dir this runner made (store-h-<pid>-<6 hex>) directly under the system temp
# folder, /tmp or the repo's tmp/ (or a folder the caller names, for the self-tests).
sub _work_dir_ok {
    my ($d, @parents) = @_;
    return 0 unless defined $d && util::basename($d) =~ /\Astore-h-\d+-[0-9a-f]{6}\z/ && -d $d && !-l $d;
    @parents = (($ENV{TMPDIR} // ()), '/tmp', $REPO_TMP_BASE) unless @parents;
    my $parent = Cwd::abs_path(util::dirname($d)) // return 0;
    for my $p (@parents) {
        next unless defined $p && $p ne '';
        my $rp = Cwd::abs_path($p) // next;
        return 1 if $rp eq $parent;
    }
    return 0;
}

# remove_tree(dir [, parents...]): only a work dir (R5); links are removed, never
# followed; folders a case made read-only are opened up first.
sub remove_tree {
    my ($d, @parents) = @_;
    return unless _work_dir_ok($d, @parents);
    _rm_tree($d);
}

# remove_in(work dir, names...): entries of a work dir (R5 applies to the work dir).
sub remove_in {
    my ($w, @names) = @_;
    return unless _work_dir_ok($w);
    for my $n (@names) {
        next if !defined $n || $n eq '' || $n =~ m{/} || $n eq '.' || $n eq '..';
        _rm_tree("$w/$n");
    }
}

sub _rm_tree {
    my ($p) = @_;
    if (-l $p || !-d _) { unlink $p; return }
    chmod 0700, $p;
    opendir(my $dh, $p) or return;
    my @e = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    _rm_tree("$p/$_") for @e;
    rmdir $p;
}

# ---------------------------------------------------------------- one case
# sequence_case(case) -> the case with its steps from tests/fixtures/sequences/<id>/ (the WP-fix
# sequence format, tests/fixtures/README.md "Sequences"): input.json's sid, now, env,
# store_test_claude_pid, repo and seed, then each step with its transcript_append appended to
# the payload's transcript_path before it runs; expected.json's step_asserts join the expect of
# the step they follow (absent_rows -> rows_absent; an assert's fields_ge goes on its last
# rows entry that names fields). The case's own keys (tz, note, needs) stay.
sub sequence_case {
    my ($case) = @_;
    my $dir = "sequences/$case->{sequence}";
    my $in = jsonc::decode(util::read_file("$FIXTURES_DIR/$dir/input.json") // die "no $dir/input.json\n");
    my $ex = -f "$FIXTURES_DIR/$dir/expected.json" ? jsonc::decode(util::read_file("$FIXTURES_DIR/$dir/expected.json")) : {};
    my %c = %$case;
    $c{sid} //= $in->{sid};
    $c{now} //= $in->{now};
    $c{env} = { %{ $in->{env} || {} }, (defined $in->{store_test_claude_pid} ? (STORE_TEST_CLAUDE_PID => $in->{store_test_claude_pid}) : ()), %{ $case->{env} || {} } };
    my @setup;
    if (defined $in->{repo}) {
        my $rc = jsonc::decode(util::read_file("$FIXTURES_DIR/$in->{repo}"));
        (my $name = $in->{repo}) =~ s{^repos/}{};
        push @setup, { repo_fixture => $name, at => '$TMP/' . ($rc->{dir} // 'repo') };
    }
    push @setup, map { my %s = %$_; delete $s{note}; $s{subst} = jsonc::true() if exists $s{copy}; \%s } @{ $in->{seed} || [] };
    my %asserts;
    for my $a (@{ $ex->{step_asserts} || [] }) { push @{ $asserts{ $a->{after_step} } }, $a }
    my @steps = ({ name => "$case->{sequence}: setup", setup => \@setup });
    my $i = 0;
    for my $s (@{ $in->{steps} || [] }) {
        $i++;
        my %st = (name => "$case->{sequence} step $i" . (defined $s->{note} ? ": $s->{note}" : ''), now => $s->{now}, argv => $s->{argv},
                  stdin => $s->{stdin}, (exists $s->{env} ? (env => $s->{env}) : ()), (exists $s->{capture} ? (capture => $s->{capture}) : ()));
        my %x = %{ $s->{expect} || {} };
        delete $x{stdout} if exists $x{stdout} && !defined $x{stdout};
        if (defined $s->{transcript_append}) {
            my $p = jsonc::decode(util::read_file("$FIXTURES_DIR/$s->{stdin}") // die "no $s->{stdin}\n");
            $st{setup} = [{ append => $s->{transcript_append}, to => $p->{transcript_path} }];
        }
        for my $a (@{ $asserts{$i} || [] }) {
            push @{ $x{files} }, @{ $a->{files} || [] };
            my @rows = @{ $a->{rows} || [] };
            if ($a->{fields_ge}) { my ($last) = grep { $_->{fields} } reverse @rows; $last->{fields_ge} = $a->{fields_ge} if $last }
            push @{ $x{rows} }, @rows;
            push @{ $x{rows_absent} }, @{ $a->{absent_rows} || [] };
            push @{ $x{joined} }, @{ $a->{joined} || [] };
        }
        $st{expect} = \%x;
        push @steps, \%st;
    }
    # metrics {join_conflict: n}: the status count (CORE-11) after the last step
    if (ref $ex->{metrics} eq 'HASH' && defined $ex->{metrics}{join_conflict}) {
        push @steps, { name => "$case->{sequence}: status counts join_conflict", argv => ['status', '--sid', '$SID'],
                       expect => { exit => 0, stdout_has => ["^compactions: .* . join_conflict $ex->{metrics}{join_conflict}:\$"] } };
    }
    $c{steps} = \@steps;
    return \%c;
}

sub run_case {
    my ($case, $cdir) = @_;
    $case = sequence_case($case) if defined $case->{sequence};
    my $tmp = (($case->{tmp_base} // '') eq 'repo' ? repo_tmp() : $RUN_TMP) . "/c$N";
    util::mkdir_p("$tmp/home");
    util::mkdir_p("$tmp/tmpdir");
    my %V;
    $V{TMP} = Cwd::abs_path($tmp);
    $V{HOME} = "$V{TMP}/home";
    $V{SID} = $case->{sid} // $DEFAULT_SID;
    $V{SID8} = substr($V{SID}, 0, 8);
    $V{PLUGIN} = $STAGE;
    $V{FIX} = $FIXTURES_DIR;
    $V{CASE} = $cdir;
    $V{BRAND} = $BRAND;
    $V{HOST} = $HOSTNAME;
    $V{CLAUDE_BIN} = $CLAUDE_BIN;
    $V{LSTART1} = $LSTART1;
    $V{TYPES} = types_file();
    # The runner's own pid and start time: the parent every helper call it starts sees
    # (the launcher execs perl), for cases that stand the runner in for Claude Code.
    $V{RUNNER_PID} = $$;
    $V{RUNNER_LSTART} = runner_lstart();
    # "manifest": {dotted path in plugin.json: value}: this case runs against its own
    # staged copy whose plugin.json holds these values (e.g. a non-ASCII description).
    $V{PLUGIN} = stage_variant($case->{manifest}, "$V{TMP}/plugin") if ref $case->{manifest} eq 'HASH';
    # "consent_home": "account": this case runs against a staged copy without the test
    # consent seam, so the consent folder is the account's ~/.claude (CR-F34); the case's
    # HOME is then foreign and the consent keys take their safe values.
    if (($case->{consent_home} // '') eq 'account') {
        copy_tree($V{PLUGIN}, "$V{TMP}/plugin-account");
        unlink "$V{TMP}/plugin-account/.test-consent-home";
        $V{PLUGIN} = "$V{TMP}/plugin-account";
    }
    # "stage_overlay": {"<path under plugin/>": "<file, placeholders filled>"}: this case runs
    # against a staged copy with those files replaced (AT-WF-01: a ctx-recording watcher seam).
    if (ref $case->{stage_overlay} eq 'HASH') {
        my $dst = "$V{TMP}/plugin-overlay";
        copy_tree($V{PLUGIN}, $dst);
        for my $rel (sort keys %{ $case->{stage_overlay} }) {
            my $src = subst($case->{stage_overlay}{$rel}, \%V);
            my $data = util::read_file($src);
            die "stage_overlay: $src missing\n" unless defined $data;
            util::write_atomic("$dst/$rel", $data, 0644);
        }
        $V{PLUGIN} = $dst;
    }
    # The launcher by its real path: the one the helper itself prints in the commands it
    # writes (ctx::store_cmd, from the real path of main.pl; the temp folder may be a link).
    $V{STORE} = "$V{PLUGIN}/$LAUNCHER_DIR/$BRAND-store";
    $V{STORE} = Cwd::abs_path($V{STORE}) // $V{STORE};
    # the staged manifest's version (the backstop cursor of the cross-session finish keys on it)
    $V{PLUGIN_VERSION} = do { my $m = eval { jsonc::decode(util::read_file("$V{PLUGIN}/.claude-plugin/plugin.json")) }; ref $m eq 'HASH' ? $m->{version} // '0.0.0' : '0.0.0' };
    my %cenv = %{ $case->{env} || {} };
    my $sub = sub { subst($_[0], \%V) };
    $V{ROOT} = defined $cenv{CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT} ? $sub->($cenv{CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT}) : "$V{HOME}/.claude/handoffs";
    $V{WATCH} = defined $cenv{CLAUDE_PLUGIN_OPTION_LOG_DIR} ? $sub->($cenv{CLAUDE_PLUGIN_OPTION_LOG_DIR}) : "$V{ROOT}/.watch";
    $V{DISP} = defined $cenv{CLAUDE_PLUGIN_OPTION_DISPOSABLE_ROOT} ? $sub->($cenv{CLAUDE_PLUGIN_OPTION_DISPOSABLE_ROOT}) : "$V{HOME}/.claude/trash-staging";
    %V = (%V, %{ subst_deep($case->{vars} || {}, \%V) });
    my @steps = $case->{steps} ? @{ $case->{steps} } : ({ %$case, then => undef });
    push @steps, @{ $case->{then} } if !$case->{steps} && ref $case->{then} eq 'ARRAY';
    my @errs;
    my $i = 0;
    for my $st (@steps) {
        $i++;
        my $label = $st->{name} // "step $i";
        my $now = $st->{now} // $case->{now};
        $V{TODAY} = defined $now ? substr($now, 0, 10) : POSIX::strftime('%Y-%m-%d', localtime);
        # "options": {key: value} (case level before step 1, and per step): plugin options in
        # the case's settings file, pluginConfigs["<brand>@m"].options, merged into the file.
        # The way to give a file-only key (DP-3: consent keys, queue_cmd, prod_patterns).
        for my $o (($i == 1 ? $case->{options} : undef), $st->{options}) {
            next unless ref $o eq 'HASH';
            my $e = eval { write_options(subst_deep($o, \%V), \%V); 1 };
            if (!$e) { push @errs, "$label options: $@"; return @errs }
        }
        for my $s (@{ $st->{setup} || [] }) {
            my $e = eval { setup($s, \%V, $case, $st, $cdir); 1 };
            if (!$e) { push @errs, "$label setup: $@"; return @errs }
        }
        if ($st->{risk_corpus}) {
            my @le = eval { risk_corpus($st, $case, \%V, $cdir, $i) };
            push @le, "risk_corpus error: $@" if $@;
            push @errs, map { "$label: $_" } @le;
            next;
        }
        if ($st->{lib}) {
            my @le = eval { builtin($st->{lib}, subst_deep($st->{args} || {}, \%V), $cdir) };
            push @le, "builtin error: $@" if $@;
            push @errs, map { "$label: $_" } @le;
            next;
        }
        if (!$st->{argv} && !$st->{exec} && !$st->{setup} && is_setup_action($st)) {
            my $e = eval { setup($st, \%V, $case, $st, $cdir); 1 };
            if (!$e) { push @errs, "$label setup: $@"; return @errs }
            next;
        }
        next unless $st->{argv} || $st->{exec};
        my $res = invoke($st, $case, \%V, $cdir, $i);
        push @errs, map { "$label: $_" } check($st->{expect} || {}, $res, \%V, $st);
        capture($st->{capture}, $res->[0]{out}, \%V) if $st->{capture} && @$res;
        if ($VERBOSE) {
            for my $r (@$res) { print "#   [$label] exit $r->{exit}\n"; print map { "#   | $_\n" } split /\n/, chars(substr($r->{out}, 0, 4000)) }
        }
    }
    return @errs;
}

sub write_options {
    my ($o, $V) = @_;
    my $f = "$V->{HOME}/.claude/settings.json";
    my $raw = -f $f ? util::read_file($f) : undef;
    my $s = defined $raw ? eval { jsonc::decode($raw) } : undef;
    $s = {} unless ref $s eq 'HASH';
    $s->{pluginConfigs} = {} unless ref $s->{pluginConfigs} eq 'HASH';
    my $k = "$BRAND\@m";
    $s->{pluginConfigs}{$k} = {} unless ref $s->{pluginConfigs}{$k} eq 'HASH';
    $s->{pluginConfigs}{$k}{options} = {} unless ref $s->{pluginConfigs}{$k}{options} eq 'HASH';
    $s->{pluginConfigs}{$k}{options}{$_} = $o->{$_} for keys %$o;
    util::write_atomic($f, jsonc::encode_bytes($s) . "\n", 0600);
}

# chars(bytes) -> the text as characters (UTF-8 decoded when it is valid UTF-8), for
# printing helper output through the UTF-8 STDOUT layer.
sub chars {
    my ($s) = @_;
    $s //= '';
    return $s if utf8::is_utf8($s);
    my $c = $s;
    return utf8::decode($c) ? $c : $s;
}

my %SECRET;
# The joined fragments of tests/fixtures/secrets/corpus.json entry <id> (fixtures README).
sub secret_value {
    my ($id) = @_;
    if (!%SECRET) {
        my $c = eval { jsonc::decode(util::read_file("$FIXTURES_DIR/secrets/corpus.json")) } || {};
        $SECRET{ $_->{id} } = join('', @{ $_->{fragments} || [] }) for @{ $c->{entries} || [] };
    }
    die "no secret corpus entry $id\n" unless exists $SECRET{$id};
    return $SECRET{$id};
}

sub subst {
    my ($s, $V) = @_;
    return $s unless defined $s && !ref $s;
    # Fixture placeholders (tests/fixtures/README.md): $SECRET{<id>}, {{plugin}}, {{marketplace}}, $FIXTURES.
    $s =~ s/\$SECRET\{([a-z0-9-]+)\}/secret_value($1)/ge;
    $s =~ s/\{\{plugin\}\}/$BRAND/g;
    $s =~ s/\{\{marketplace\}\}/$MARKETPLACE/g;
    $s =~ s/\$FIXTURES\b/$FIXTURES_DIR/g;
    $s =~ s{\$\{(TMP|HOME|ROOT|WATCH|SID8|SID|PLUGIN|STORE|FIX|CASE|BRAND|HOST|CLAUDE_BIN|DISP|TODAY)\}}{$V->{$1} // ''}ge;
    $s =~ s/\$(TMP|HOME|ROOT|WATCH|SID8|SID|PLUGIN|STORE|FIX|CASE|BRAND|HOST|CLAUDE_BIN|DISP|TODAY)\b/$V->{$1} \/\/ ''/ge;
    # Any other $NAME the case defined (vars) or a step captured; unknown names stay as written.
    $s =~ s/\$([A-Z][A-Z0-9_]*)/exists $V->{$1} && defined $V->{$1} ? $V->{$1} : "\$$1"/ge;
    return $s;
}

sub subst_deep {
    my ($x, $V) = @_;
    return subst($x, $V) unless ref $x;
    return [map { subst_deep($_, $V) } @$x] if ref $x eq 'ARRAY';
    return { map { subst($_, $V) => subst_deep($x->{$_}, $V) } keys %$x } if ref $x eq 'HASH';
    return $x;
}

sub src_file {
    my ($name, $cdir) = @_;
    return $name if $name =~ m{^/} && -e $name;
    return "$cdir/$name" if -e "$cdir/$name";
    return "$FIXTURES_DIR/$name" if -e "$FIXTURES_DIR/$name";
    die "no file $name in the case dir or tests/fixtures\n";
}

sub iso_ago {
    my ($now, $ago) = @_;
    my $base = defined $now ? util::parse_iso($now) : time;
    my $e = $base - ($ago // 0);
    return util::iso($e);
}

sub write_text {
    my ($path, $text, $mode) = @_;
    util::mkdir_p(util::dirname($path));
    open(my $fh, '>:raw', $path) or die "write $path: $!\n";
    my $t = $text;
    utf8::encode($t) if utf8::is_utf8($t);
    print $fh $t;
    close $fh;
    chmod(oct($mode), $path) if defined $mode;
}

sub git_env {
    my ($V) = @_;
    return { HOME => $V->{HOME}, GIT_CONFIG_NOSYSTEM => '1', GIT_AUTHOR_NAME => 'Test', GIT_AUTHOR_EMAIL => 'test@example.invalid',
             GIT_COMMITTER_NAME => 'Test', GIT_COMMITTER_EMAIL => 'test@example.invalid' };
}

sub git_run {
    my ($dir, $V, @a) = @_;
    my $git = util::which('git') // '/usr/bin/git';
    my $r = util::run([$git, '-C', $dir, @a], timeout_ms => 20000, env => git_env($V));
    die "git @a failed in $dir\n" unless $r->{exit} == 0;
    return $r->{out};
}

# Step "risk_corpus": {"tsv": "<file in the case dir or tests/fixtures>", "cwd": "<dir>",
# "source": "own|foreign"?, "want": {"<row command>": "none|ask"}?} (AT-SR-09, the H half of
# tools/gates risk-corpus; SR-7): every row of the corpus (expect<TAB>command<TAB>classes) is
# written to a file and classified by `risk --cmd-file <file> --cwd <cwd>`; exit 0, `risk: none (…)`
# for a none row, `risk: ask (…)` holding every listed class for an ask row. "want" overrides a
# row's expected answer for this run (a code-only check the literals cannot see).
sub risk_corpus {
    my ($st, $case, $V, $cdir, $i) = @_;
    my $a = subst_deep($st->{risk_corpus}, $V);
    my $tsv = src_file($a->{tsv}, $cdir);
    open(my $fh, '<:raw', $tsv) or return ("cannot read $tsv");
    my (@e, $n);
    while (my $l = <$fh>) {
        chomp $l;
        next if $l =~ /^\s*(#|$)/;
        my ($want, $cmd, $need) = split /\t/, $l;
        next unless defined $cmd;
        $want = $a->{want}{$cmd} if ref $a->{want} eq 'HASH' && defined $a->{want}{$cmd};
        $n++;
        my $f = "$V->{TMP}/risk-cmd-$n.txt";
        write_text($f, $cmd);
        my @argv = ('risk', '--cmd-file', $f, '--cwd', $a->{cwd});
        push @argv, '--source', $a->{source} if defined $a->{source};
        my $res = invoke({ argv => \@argv, env => $st->{env} }, $case, $V, $cdir, "$i-risk$n");
        my $out = $res->[0]{out} // '';
        if ($res->[0]{exit} != 0) { push @e, "row $n '$cmd': exit $res->[0]{exit}"; next }
        my ($line) = $out =~ /^(risk: [^\n]*)$/m;
        $line //= '(no risk line)';
        if ($want eq 'none') {
            push @e, "row $n '$cmd': $line, want none" unless $line =~ /^risk: none \(/;
            next;
        }
        my ($got) = $line =~ /^risk: ask \(([^)]*)\)$/;
        if (!defined $got) { push @e, "row $n '$cmd': $line, want ask"; next }
        my %g = map { $_ => 1 } split /, /, $got;
        my @miss = grep { $_ ne '-' && $_ ne '' && !$g{$_} } split /,/, ($need // '-');
        push @e, "row $n '$cmd': ask ($got), missing " . join(',', @miss) if @miss && ($a->{source} // 'foreign') eq 'foreign';
    }
    push @e, "no corpus rows in $tsv" unless $n;
    return @e;
}

# Inline repo recipe (WP-skills cases): {base, branch, commits: [{files, msg}], ignored, dirty, untracked} at <dir>
sub make_repo {
    my ($rc, $at, $V) = @_;
    die "repo recipe needs at\n" unless defined $at && $at ne '';
    util::mkdir_p($at);
    git_run($at, $V, 'init', '-q', '-b', $rc->{base} // 'main');
    for my $cm (@{ $rc->{commits} || [{ files => { 'README.md' => "seed\n" }, msg => 'seed' }] }) {
        write_text("$at/$_", $cm->{files}{$_}) for sort keys %{ $cm->{files} || {} };
        git_run($at, $V, 'add', '-A');
        git_run($at, $V, 'commit', '-q', '--allow-empty', '-m', $cm->{msg} // 'commit');
    }
    git_run($at, $V, 'checkout', '-q', '-b', $rc->{branch}) if $rc->{branch} && $rc->{branch} ne ($rc->{base} // 'main');
    if (@{ $rc->{ignored} || [] }) {
        write_text("$at/.gitignore", join("\n", @{ $rc->{ignored} }) . "\n");
        git_run($at, $V, 'add', '.gitignore');
        git_run($at, $V, 'commit', '-q', '-m', 'ignore');
    }
    write_text("$at/$_", $rc->{dirty}{$_}) for sort keys %{ $rc->{dirty} || {} };
    write_text("$at/$_", $rc->{untracked}{$_}) for sort keys %{ $rc->{untracked} || {} };
}

sub is_setup_action {
    my ($s) = @_;
    return scalar grep { exists $s->{$_} } qw(write copy mkdir symlink stub repo dispatch transcript run git bigfile age
                                               tempfiles secret_files repo_fixture paths fixture_setup touch normalized_sha append);
}

# ---------------------------------------------------------------- fixture recipes (tests/fixtures/README.md)
# The rows the mod's tool.call handler would have sent through `log --stream paths`.
sub record_paths {
    my ($V, $sid, @paths) = @_;
    $sid //= $V->{SID};
    my $f = "$V->{WATCH}/$sid/paths.jsonl";
    util::mkdir_p(util::dirname($f));
    open(my $fh, '>>:raw', $f) or die "paths: $!\n";
    for my $p (@paths) {
        my $row = jsonc::encode_bytes(jsonc::obj(v => 1, ts => util::iso(time), ev => 'path', sid => $sid, actor => 'main',
                                                  writer => 'mod', path => $p, tool => 'Bash'));
        print $fh "$row\n";
    }
    close $fh;
}

# {"tempfiles": "<recipe>.json", "tmp": "<dir>"?, "record": true?}: tests/fixtures/tempfiles/<recipe>
# materialised; "tmp" stands in for $TMP inside the recipe (a temp dir the sweep scope
# covers on every OS); "record" appends the recipe's paths_log as paths.jsonl rows.
sub fixture_tempfiles {
    my ($s, $V, $cdir) = @_;
    my $rc = jsonc::decode(util::read_file(src_file("tempfiles/$s->{tempfiles}", $cdir)));
    my %W = (%$V, (defined $s->{tmp} ? (TMP => $s->{tmp}) : ()));
    for my $f (@{ $rc->{files} || [] }) {
        my $p = subst($f->{path}, \%W);
        util::mkdir_p(util::dirname($p));
        open(my $fh, '>:raw', $p) or die "tempfiles $p: $!\n";
        if (defined $f->{lines}) {
            my $line = $f->{line} // 'line {n}';
            for my $n (1 .. $f->{lines}) { (my $l = $line) =~ s/\{n\}/$n/g; print $fh "$l\n" }
        } else {
            my $fill = $f->{fill} // 'x';
            my $chunk = $fill x (int(65536 / length($fill)) + 1);
            my $left = $f->{bytes} // 0;
            while ($left > 0) { my $n = $left < length($chunk) ? $left : length($chunk); print $fh substr($chunk, 0, $n); $left -= $n }
        }
        close $fh;
        chmod 0600, $p;
    }
    record_paths($V, $s->{sid}, map { subst($_, \%W) } @{ $rc->{paths_log} || [] }) if $s->{record};
}

# {"secret_files": "<dir>", "record": true?}: the sweep files of tests/fixtures/secrets/corpus.json,
# their $SECRET{} tokens joined from fragments at run time, written under <dir> (the
# recipe's $TMP/sweep); "record" appends their paths as paths.jsonl rows.
sub fixture_secret_files {
    my ($s, $V, $cdir) = @_;
    my $c = jsonc::decode(util::read_file("$FIXTURES_DIR/secrets/corpus.json"));
    my @rec;
    for my $f (@{ $c->{files} || [] }) {
        (my $rel = $f->{path}) =~ s{^\$TMP/sweep/}{} or die "secret file $f->{path} is not under \$TMP/sweep\n";
        my $p = "$s->{secret_files}/$rel";
        write_text($p, join("\n", map { subst($_, $V) } @{ $f->{content} || [] }) . "\n", '0600');
        push @rec, $p;
    }
    record_paths($V, $s->{sid}, @rec) if $s->{record};
}

# {"repo_fixture": "<recipe>.json", "at": "<dir>"}: tests/fixtures/repos/<recipe> as a git repo
# (fixed author and date; the first commit's .gitignore holds the ignore patterns), then
# its dirty, untracked and ignored files.
sub fixture_repo {
    my ($s, $V, $cdir) = @_;
    my $rc = jsonc::decode(util::read_file(src_file("repos/$s->{repo_fixture}", $cdir)));
    my $at = $s->{at} // die "repo_fixture needs at\n";
    util::mkdir_p($at);
    my %env = %{ git_env($V) };
    if (my $au = $rc->{author}) {
        @env{qw(GIT_AUTHOR_NAME GIT_COMMITTER_NAME)} = ($au->{name}) x 2 if $au->{name};
        @env{qw(GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL)} = ($au->{email}) x 2 if $au->{email};
        @env{qw(GIT_AUTHOR_DATE GIT_COMMITTER_DATE)} = ($au->{date}) x 2 if $au->{date};
    }
    my $git = util::which('git') // '/usr/bin/git';
    my $g = sub { my $r = util::run([$git, '-C', $at, @_], timeout_ms => 20000, env => \%env); die "git @_ failed in $at\n" unless $r->{exit} == 0 };
    my @ign = sort keys %{ $rc->{ignored_files} || {} };
    if (!defined $rc->{git} || $rc->{git}) {
        $g->('init', '-q', '-b', $rc->{branch} // 'main');
        for my $cm (@{ $rc->{commits} || [] }) {
            write_text("$at/$_", $cm->{files}{$_}) for sort keys %{ $cm->{files} || {} };
            $g->('add', '-A');
            $g->('commit', '-q', '--allow-empty', '-m', $cm->{message} // 'fixture');
        }
    } else {
        write_text("$at/$_", $rc->{files}{$_}) for sort keys %{ $rc->{files} || {} };
    }
    write_text("$at/$_", $rc->{dirty}{$_}) for sort keys %{ $rc->{dirty} || {} };
    write_text("$at/$_", $rc->{untracked}{$_}) for sort keys %{ $rc->{untracked} || {} };
    write_text("$at/$_", $rc->{ignored_files}{$_}) for @ign;
}

# Dotted path into decoded JSON: (found, value)
sub jpath {
    my ($d, $path) = @_;
    for my $k (split /\./, $path) {
        if (ref $d eq 'ARRAY' && $k =~ /\A\d+\z/) { return (0, undef) if $k > $#$d; $d = $d->[$k] }
        elsif (ref $d eq 'HASH') { return (0, undef) unless exists $d->{$k}; $d = $d->{$k} }
        else { return (0, undef) }
    }
    return (1, $d);
}

# capture {VAR: "json:<path>" | "re:<regex with one group>"} from a helper's stdout
sub capture {
    my ($cap, $out, $V) = @_;
    my $o = $out // '';
    utf8::decode($o);
    for my $k (keys %$cap) {
        my $how = $cap->{$k};
        if ($how =~ /\Ajson:(.*)\z/s) {
            my $d = eval { jsonc::decode($out) };
            my (undef, $v) = jpath($d, $1);
            $V->{$k} = $v if defined $v && !ref $v;
        } elsif ($how =~ /\Are:(.*)\z/s) {
            my $re = $1;
            $V->{$k} = $1 if $o =~ /$re/m;
        }
    }
}

# JSON booleans compare as 1/0, so a case may write true or 1.
sub scalar_text {
    my ($v) = @_;
    return 'null' unless defined $v;
    return $v ? '1' : '0' if jsonc::is_bool($v);
    return ref $v ? jsonc::encode($v) : "$v";
}

sub setup {
    my ($s, $V, $case, $st, $cdir) = @_;
    $s = subst_deep($s, $V);
    my $now = $st->{now} // $case->{now};
    if (exists $s->{write}) {
        my $p = $s->{write};
        my $text;
        if (exists $s->{json}) { $text = jsonc::encode($s->{json}) . "\n" }
        elsif (exists $s->{parts}) { $text = join('', @{ $s->{parts} }) }
        elsif (exists $s->{content_parts}) { $text = join('', @{ $s->{content_parts} }); $s->{mode} //= '0600' }
        elsif (exists $s->{content}) { $text = $s->{content}; $s->{mode} //= '0600' }
        elsif (exists $s->{bytes}) { $text = ('x' x 63 . "\n") x int($s->{bytes} / 64); $text .= 'x' x ($s->{bytes} - length $text) }
        elsif (exists $s->{lines}) { $text = join('', map { "line $_ of the output\n" } 1 .. $s->{lines}) }
        else { $text = $s->{text} // '' }
        # jsonl_pad {key, text, bytes}: the first jsonl row's dotted key holds text repeated to
        # bytes (a row longer than a reader's first block, e.g. a long agent prompt)
        if ($s->{jsonl} && $s->{jsonl_pad} && @{ $s->{jsonl} }) {
            my ($pad, $h) = ($s->{jsonl_pad}, $s->{jsonl}[0]);
            my @k = split /\./, $pad->{key};
            my $last = pop @k;
            $h = ($h->{$_} = ref $h->{$_} eq 'HASH' ? $h->{$_} : {}) for @k;
            my $t = $pad->{text};
            $h->{$last} = substr($t x (int($pad->{bytes} / length($t)) + 1), 0, $pad->{bytes});
        }
        if ($s->{jsonl}) { $text = join('', map { jsonc::encode($_) . "\n" } @{ $s->{jsonl} }) }
        # jsonl_repeat {row, count}: one row many times (a long session's stream), then the jsonl rows
        if ($s->{jsonl_repeat}) { $text = (jsonc::encode($s->{jsonl_repeat}{row}) . "\n") x $s->{jsonl_repeat}{count} . ($s->{jsonl} ? $text : '') }
        write_text($p, $text, $s->{mode});
        if (defined $s->{mtime_ago_s}) { my $t = time - $s->{mtime_ago_s}; utime($t, $t, $p) }
        return;
    }
    if (exists $s->{copy}) {
        my $src = src_file($s->{copy}, $cdir);
        util::mkdir_p(util::dirname($s->{to}));
        # "subst": true fills the placeholders ({{plugin}}, $SID, ...) in the copied text, so a
        # case file a helper reads itself (save-copy --from) carries no literal brand (RN-1).
        if ($s->{subst}) {
            my $t = util::read_file($src) // die "copy $src: unreadable\n";
            utf8::decode($t);
            write_text($s->{to}, subst($t, $V), $s->{mode} // '0600');
            return;
        }
        util::copy_file($src, $s->{to}, mode => oct($s->{mode} // '0600'));
        return;
    }
    if (exists $s->{fixture_setup}) {
        # tests/fixtures/setups/<id>.json: its "setup" steps, run in order (fixtures README "Setups")
        my $rc = jsonc::decode(util::read_file(src_file("setups/$s->{fixture_setup}", $cdir)));
        setup($_, $V, $case, $st, $cdir) for @{ $rc->{setup} || [] };
        return;
    }
    if (exists $s->{touch}) {
        # {"touch": path, "at": ISO}: the file's mtime on the case clock (age and mtime_ago_s are real-clock relative)
        my $t = util::parse_iso($s->{at} // '') // die "touch $s->{touch}: bad time " . ($s->{at} // 'none') . "\n";
        utime($t, $t, $s->{touch}) or die "touch $s->{touch}: $!\n";
        return;
    }
    if (exists $s->{append}) {
        # {"append": src, "to": path}: the source file (placeholders filled) appended to path
        # (a sequence step's transcript_append)
        my $t = util::read_file(src_file($s->{append}, $cdir)) // die "append $s->{append}: unreadable\n";
        utf8::decode($t);
        $t = subst($t, $V);
        utf8::encode($t);
        util::mkdir_p(util::dirname($s->{to}));
        open(my $fh, '>>:raw', $s->{to}) or die "append $s->{to}: $!\n";
        print $fh $t;
        close $fh;
        return;
    }
    if (exists $s->{normalized_sha}) {
        # {"normalized_sha": path, "var": NAME}: NAME = sha256 of the file's normalized summary
        # body (the staged detect.pm), e.g. a stash's raw_sha256 (AT-ST-02)
        _libs();
        my $t = util::read_file($s->{normalized_sha}) // die "normalized_sha $s->{normalized_sha}: unreadable\n";
        $V->{ $s->{var} // 'SHA' } = sha::hex256(detect::scan($t)->{normalized});
        return;
    }
    if (exists $s->{tempfiles}) { fixture_tempfiles($s, $V, $cdir); return }
    if (exists $s->{secret_files}) { fixture_secret_files($s, $V, $cdir); return }
    if (exists $s->{repo_fixture}) { fixture_repo($s, $V, $cdir); return }
    if (exists $s->{paths}) { record_paths($V, $s->{sid}, @{ $s->{paths} }); return }
    if (exists $s->{mkdir}) { util::mkdir_p($s->{mkdir}); chmod(oct($s->{mode}), $s->{mkdir}) if $s->{mode}; return }
    if (exists $s->{symlink}) {
        util::mkdir_p(util::dirname($s->{symlink}));
        symlink($s->{to}, $s->{symlink}) or die "symlink $s->{symlink}: $!\n";
        return;
    }
    if (exists $s->{stub}) {
        my $dir = $s->{dir} // "$V->{TMP}/bin";
        write_text("$dir/$s->{stub}", "#!/bin/sh\n" . ($s->{script} // 'exit 0') . "\n", '0755');
        return;
    }
    if (exists $s->{repo} && ref $s->{repo} eq 'HASH') { make_repo($s->{repo}, $s->{at}, $V); return }
    if (exists $s->{git}) {
        my $dir = $s->{cwd} // $V->{TMP};
        my $r = util::run([util::which('git') // '/usr/bin/git', @{ $s->{git} }], timeout_ms => 20000, cwd => $dir,
                          env => { %{ git_env($V) }, %{ $s->{env} || {} } });
        die "git @{ $s->{git} }: exit $r->{exit}\n" unless $r->{exit} == 0;
        if ($s->{var}) { (my $o = $r->{out}) =~ s/\s+\z//; $V->{ $s->{var} } = $o }
        return;
    }
    if (exists $s->{bigfile}) {
        util::mkdir_p(util::dirname($s->{bigfile}));
        open(my $fh, '>:raw', $s->{bigfile}) or die "bigfile $s->{bigfile}: $!\n";
        my $left = $s->{bytes} // 0;
        my $chunk = ($s->{fill} // 'b') x 65536;
        while ($left > 0) { my $n = $left < 65536 ? $left : 65536; print $fh substr($chunk, 0, $n); $left -= $n }
        # "tail": text after the filler (a value past the first scan window, RRP-06)
        if (defined $s->{tail}) { my $t = $s->{tail}; utf8::encode($t) if utf8::is_utf8($t); print $fh $t }
        close $fh;
        return;
    }
    if (exists $s->{age}) {
        my $t = time - 60 * ($s->{minutes} // 0);
        utime($t, $t, $s->{age}) or die "age $s->{age}: $!\n";
        return;
    }
    if (exists $s->{repo}) {
        my $d = $s->{repo};
        util::mkdir_p($d);
        git_run($d, $V, 'init', '-q', '-b', $s->{branch} // 'main');
        for my $f (sort keys %{ $s->{files} || { 'README.md' => "readme\n" } }) { write_text("$d/$f", $s->{files}{$f} // "readme\n") }
        write_text("$d/.gitignore", join("\n", @{ $s->{ignore} }) . "\n") if $s->{ignore};
        write_text("$d/.planning/STATE.md", $s->{planning_state}) if defined $s->{planning_state};
        git_run($d, $V, 'add', '-A');
        git_run($d, $V, 'commit', '-q', '-m', 'fixture');
        for my $f (sort keys %{ $s->{dirty} || {} }) { write_text("$d/$f", $s->{dirty}{$f}) }
        return;
    }
    if (exists $s->{dispatch}) {
        my $f = $s->{dispatch};
        my $nonce = $f->{nonce} // die "dispatch needs a nonce\n";
        my $actor = $f->{actor} // 'main';
        my $rec = jsonc::obj(v => 1, nonce => $nonce, session_id => $f->{session_id} // $V->{SID}, actor => $actor,
            agent_id => ($actor eq 'main' || $actor eq 'unknown') ? undef : $actor, trigger => $f->{trigger} // 'auto',
            channel => $f->{channel} // 'mod-hook', resume_pref => $f->{resume_pref} // ($actor eq 'main' ? 'prompt.context' : 'none'),
            midturn => jsonc::bool($f->{midturn}), tags => $f->{tags} // [], instructions_sha8 => '00000000',
            instructions_bytes => 4000, cc_version => '2.1.306', load_id => 'test', pid => 424242,
            pid_lstart => 'Tue Oct 21 09:00:00 2026', ts => $f->{ts} // iso_ago($now, $f->{age_s} // 30));
        my $sid = $f->{session_id} // $V->{SID};
        write_text("$V->{WATCH}/$sid/dispatch/$nonce.json", jsonc::encode($rec) . "\n", '0600');
        return;
    }
    if (exists $s->{transcript}) {
        my @rows;
        for my $r (@{ $s->{rows} || [] }) {
            if ($r->{boundary}) {
                my $b = $r->{boundary};
                push @rows, { type => 'system', subtype => 'compact_boundary', content => 'Conversation compacted', level => 'info',
                              parentUuid => undef, logicalParentUuid => 'p-' . util::rand_hex(8), isSidechain => jsonc::false(),
                              sessionId => $V->{SID}, uuid => $b->{uuid} // ('b-' . util::rand_hex(12)),
                              timestamp => $b->{ts} // iso_ago($now, $b->{age_s} // 5), version => '2.1.306',
                              compactMetadata => { trigger => $b->{trigger} // 'auto', preTokens => $b->{pre} // 612000,
                                                   postTokens => $b->{post} // 41000, durationMs => $b->{duration_ms} // 52000,
                                                   cumulativeDroppedTokens => 0,
                                                   ($b->{precomputed} ? (precomputed => jsonc::true()) : ()) } };
            } elsif ($r->{prompt}) {
                push @rows, { type => 'user', uuid => 'u-' . util::rand_hex(12), sessionId => $V->{SID},
                              timestamp => $r->{prompt}{ts} // iso_ago($now, $r->{prompt}{age_s} // 60),
                              message => { role => 'user', content => 'synthetic prompt' } };
            } elsif ($r->{text}) {
                push @rows, { type => 'assistant', uuid => 'a-' . util::rand_hex(12), sessionId => $V->{SID},
                              timestamp => iso_ago($now, 10), message => { role => 'assistant', content => [{ type => 'text', text => $r->{text} }] } };
            } else {
                push @rows, $r;
            }
        }
        my $text = join('', map { jsonc::encode($_) . "\n" } @rows);
        util::mkdir_p(util::dirname($s->{transcript}));
        open(my $fh, '>>:raw', $s->{transcript}) or die "transcript: $!\n";
        utf8::encode($text) if utf8::is_utf8($text);
        print $fh $text;
        close $fh;
        return;
    }
    if (exists $s->{run}) {
        my $res = invoke({ %$s, argv => $s->{run} }, $case, $V, $cdir, 'setup');
        die "run @{ $s->{run} }: exit $res->[0]{exit}, want $s->{exit}\n" if defined $s->{exit} && $res->[0]{exit} != $s->{exit};
        capture($s->{capture}, $res->[0]{out}, $V) if $s->{capture};
        return;
    }
    die "unknown setup action: " . join(',', keys %$s) . "\n";
}

sub child_env {
    my ($st, $case, $V, $i) = @_;
    my %e;
    my @pre = map { subst($_, $V) } (@{ $case->{path_prepend} || [] }, @{ $st->{path_prepend} || [] });
    $e{PATH} = join(':', @pre, '/usr/bin', '/bin', '/usr/sbin', '/sbin');
    $e{HOME} = $V->{HOME};
    $e{TMPDIR} = "$V->{TMP}/tmpdir";
    $e{TZ} = $st->{tz} // $case->{tz} // 'UTC';
    $e{STORE_TEST_MODE} = '1';
    $e{STORE_TEST_TRACE} = "$V->{TMP}/trace-$i.log";
    $e{STORE_TEST_CLAUDE_PID} = $DEFAULT_PID;
    my $now = $st->{now} // $case->{now};
    $e{STORE_TEST_NOW} = $now if defined $now;
    my %ce = (%{ $case->{env} || {} }, %{ $st->{env} || {} });
    for my $k (keys %ce) {
        if (!defined $ce{$k}) { delete $e{$k}; next }
        $e{$k} = subst($ce{$k}, $V);
    }
    return \%e;
}

sub stdin_of {
    my ($st, $V, $cdir) = @_;
    if (exists $st->{stdin_json}) { return jsonc::encode_bytes(subst_deep($st->{stdin_json}, $V)) }
    if (exists $st->{stdin_text}) { my $t = subst($st->{stdin_text}, $V); utf8::encode($t) if utf8::is_utf8($t); return $t }
    if (exists $st->{stdin_parts}) { return join('', @{ $st->{stdin_parts} }) }
    if (defined $st->{stdin}) {
        my $raw = util::read_file(src_file($st->{stdin}, $cdir));
        utf8::decode($raw);
        my $t = subst($raw, $V);
        utf8::encode($t);
        return $t;
    }
    return '';
}

# Start one helper process; returns {pid, out_r}
sub spawn {
    my ($argv, $env, $stdin, $outf, $errf, $cwd) = @_;
    my $pid = fork();
    die "fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        # The environment is bytes: a case value with a non-ASCII character goes in as UTF-8.
        %ENV = map { ($_ => util::to_bytes($env->{$_})) } keys %$env;
        if (defined $cwd) { chdir(util::to_bytes($cwd)) or POSIX::_exit(125) }
        open(STDOUT, '>', $outf) or POSIX::_exit(126);
        open(STDERR, '>', $errf) or POSIX::_exit(126);
        my $inf = "$outf.in";
        open(my $fh, '>:raw', $inf); print $fh $stdin; close $fh;
        open(STDIN, '<', $inf) or POSIX::_exit(126);
        { no warnings "exec"; exec { $argv->[0] } @$argv; }
        POSIX::_exit(127);
    }
    $KIDS{$pid} = 1;
    return $pid;
}

sub invoke {
    my ($st, $case, $V, $cdir, $i) = @_;
    my $env = child_env($st, $case, $V, $i);
    my @argv = ($V->{STORE}, map { subst($_, $V) } @{ $st->{argv} || [] });
    @argv = map { subst($_, $V) } @{ $st->{exec} } if $st->{exec};
    my $stdin = stdin_of($st, $V, $cdir);
    my @inputs = $st->{parallel_inputs} ? @{ $st->{parallel_inputs} } : ((undef) x ($st->{parallel} // 1));
    my @procs;
    my $k = 0;
    my @prepared;
    for my $in (@inputs) {
        $k++;
        my ($av, $sin) = (\@argv, $stdin);
        if ($in) {
            $av = [$V->{STORE}, map { subst($_, $V) } @{ $in->{argv} }] if $in->{argv};
            $sin = stdin_of($in, $V, $cdir) if grep { exists $in->{$_} } qw(stdin stdin_json stdin_text stdin_parts);
        }
        push @prepared, [$av, $sin, "$V->{TMP}/out-$i-$k", "$V->{TMP}/err-$i-$k"];
    }
    my $cwd = defined $st->{cwd} ? subst($st->{cwd}, $V) : $V->{TMP};
    for my $pp (@prepared) {
        my $t0 = util::clock_ms();
        push @procs, { pid => spawn($pp->[0], $env, $pp->[1], $pp->[2], $pp->[3], $cwd), outf => $pp->[2], errf => $pp->[3], t0 => $t0 };
    }
    if (defined $st->{kill_after_ms}) {
        util::sleep_ms($st->{kill_after_ms});
        kill $st->{kill_signal} // 'KILL', $_->{pid} for @procs;
    }
    my $limit = ($st->{timeout_s} // 60) * 1000;
    for my $p (@procs) {
        my $waited = 0;
        while (waitpid($p->{pid}, POSIX::WNOHANG()) == 0) {
            if (util::clock_ms() - $p->{t0} > $limit) { kill 'KILL', $p->{pid}; waitpid($p->{pid}, 0); $p->{timed_out} = 1; last }
            util::sleep_ms(5);
        }
        my $st_ = $?;
        delete $KIDS{ $p->{pid} };
        $p->{exit} = ($st_ & 127) ? 128 + ($st_ & 127) : ($st_ >> 8);
        $p->{ms} = util::clock_ms() - $p->{t0};
        $p->{out} = util::read_file($p->{outf}) // '';
        $p->{err} = util::read_file($p->{errf}) // '';
        $p->{trace} = util::read_file($env->{STORE_TEST_TRACE}) // '';
    }
    return \@procs;
}

# ---------------------------------------------------------------- built-in checks
# In-process checks over the staged helper's own libraries (no subprocess):
#   detect_tsv        {tsv, dir}: detector vs expected.tsv (AT-C-03 / AT-C-02 H)
#   assemble_goldens  {dir, runtime}: helper assembler vs tools/assemble goldens (BT-04)
#   sha_vectors       {}: embedded SHA-256 vs Digest::SHA and a known vector
#   json_roundtrip    {dir}: embedded codec vs JSON::PP on every *.json under dir
#   proc_stat_lines   {file}: identity::_proc_stat over recorded Linux /proc/<pid>/stat lines (R-4)
#   linux_start_time  {image | images, probe, mb, steps}: identity::start_time on Linux in Docker
#                     (R-4; a subprocess: the case "needs" ["docker-image:<image>"]; images: the
#                     first one held here, none: a note and not run)
my $LIBS_READY;
sub _libs {
    return if $LIBS_READY;
    for my $l (qw(sha ctx spec settings paths roots log rc identity lock nonce git detect assemble secrets dispatch)) { require "$l.pm" }
    ctx::init("$STAGE/helper");
    $LIBS_READY = 1;
}

# nocase_fs() -> 1 when the system temp folder (where the cases run) ignores letter case
# (macOS default APFS): a case "needs": ["nocase-fs"] skips elsewhere.
sub nocase_fs {
    my $d = $RUN_TMP // ($ENV{TMPDIR} || "/tmp");
    my $u = uc $d;
    return ($u ne $d && -d $u) ? 1 : 0;
}

# docker_image(ref) -> 1 when a Docker daemon answers and holds the image locally (the case
# "needs": ["docker-image:<ref>"] skips otherwise; no case pulls an image).
my %DOCKER_IMAGE;
sub docker_image {
    my ($ref) = @_;
    return $DOCKER_IMAGE{$ref} if exists $DOCKER_IMAGE{$ref};
    my $docker = util::which('docker');
    my $r = $docker ? util::run([$docker, 'image', 'inspect', '--format', '{{.Id}}', $ref], timeout_ms => 20000) : { exit => 1 };
    return $DOCKER_IMAGE{$ref} = $r->{exit} == 0 ? 1 : 0;
}

# ---------------------------------------------------------------- U-06 (builtin user_regex_bound)
# u06_within(seconds, code) -> the lines code returns, run in a forked child (its own process
# group) that is killed with its group after `seconds`: one "hung" line then. A line that starts
# with "# " is printed as a note, not returned as an error.
sub u06_within {
    my ($secs, $code) = @_;
    pipe(my $r, my $w) or return ("pipe: $!");
    my $pid = fork();
    return ("fork: $!") unless defined $pid;
    if ($pid == 0) {
        close $r;
        setpgrp(0, 0);
        my @e = eval { $code->() };
        push @e, "died: $@" if $@;
        my $out = join('', map { (my $x = $_) =~ s/\n/ /g; "$x\n" } @e);
        utf8::encode($out) if utf8::is_utf8($out);
        my $off = 0;
        while ($off < length $out) { my $n = syswrite($w, $out, length($out) - $off, $off); last unless $n; $off += $n }
        POSIX::_exit(0);
    }
    close $w;
    my ($buf, $rin, $eof) = ('', '', 0);
    vec($rin, fileno($r), 1) = 1;
    my $end = util::clock_ms() + $secs * 1000;
    while ((my $left = $end - util::clock_ms()) > 0) {
        my $n = select(my $ro = $rin, undef, undef, $left / 1000);
        next if $n == 0 || ($n < 0 && $!{EINTR});
        last if $n < 0;
        my $got = sysread($r, my $c, 65536);
        if (!$got) { $eof = 1; last }
        $buf .= $c;
    }
    close $r;
    if (!$eof) { kill 'KILL', -$pid; kill 'KILL', $pid; waitpid($pid, 0); return ("hung: no answer within $secs s (a pattern ran without a time bound)") }
    waitpid($pid, 0);
    utf8::decode($buf);
    my @l = split /\n/, $buf;
    print "$_\n" for grep { /\A# / } @l;
    return grep { !/\A# / } @l;
}

# u06_kids(pid) -> [the pids of pid's children]: from /proc/*/stat where it exists (the Linux
# floor images have no pgrep), else pgrep -P; undef when neither works.
sub u06_kids {
    my ($pp) = @_;
    if (opendir(my $d, '/proc')) {
        my @k;
        my $any = 0;
        for my $p (grep { /\A\d+\z/ } readdir $d) {
            my $s = util::read_file("/proc/$p/stat") // next;
            $any = 1;
            push @k, $p if $s =~ /\)\s+\S\s+(\d+)/ && $1 == $pp;
        }
        closedir $d;
        return \@k if $any;
    }
    my $pg = util::which('pgrep') // return undef;
    my $r = util::run([$pg, '-P', $pp], timeout_ms => 5000);
    return [grep { /\A\d+\z/ } split /\s+/, $r->{out} // ''];
}

# u06_check(check, args) -> errors of one U-06 check (in the u06_within child). args: limit and
# budget (lib/userre.pm, default 0.5 and 3 s), max_call_ms (prod-normal, default 50), seed,
# no_hires (1: the clock of a perl without Time::HiRes, STORE_TEST_NO_HIRES), cpu_share (the
# CPU share of its limit that makes a stop the pattern's, default 0 here: every stop is
# `timeout`, whatever the machine's load; the `load` check sets it out of reach).
sub u06_check {
    my ($check, $o) = @_;
    no warnings 'once';
    my @e;
    my $lim = $o->{limit} // 0.5;
    local $ENV{STORE_TEST_MODE} = '1';
    local $ENV{STORE_TEST_NO_HIRES} = $o->{no_hires} ? '1' : '0';
    # without lib/userre.pm (the code before U-06) the same calls run unbounded and hang
    my $have = defined &userre::limits;
    userre::limits($lim, $o->{budget} // 3) if $have;
    userre::clear() if $have;
    $userre::CPU_SHARE = $o->{cpu_share} // 0;
    my $allowed = sub { defined &settings::relaunch_allowed ? settings::relaunch_allowed(@_) : scalar grep { $_[0] =~ $_ } @{ $_[1]{allow} } };
    local %rc::R = ();
    my $bound = int(($lim + 0.7) * 1000);    # one stopped pattern: its limit, the fork and the kill
    my $long = ('a' x 100_000) . 'b';         # (a+)+$ backtracks quadratically from every a: minutes
    my $timed = sub { my $t0 = util::clock_ms(); my @r = $_[0]->(); return (util::clock_ms() - $t0, @r) };
    my $stopped = sub { join(' ', map { join(':', @$_) } @userre::STOPPED) };
    my $want_stopped = sub { my ($w) = @_; return $stopped->() eq $w ? () : ('stopped [' . $stopped->() . "], want [$w]") };
    my $over = sub { my ($ms, $what) = @_; return $ms > $bound ? ("$what took $ms ms, over the bound of $bound ms") : () };
    my $kids = sub { return @{ u06_kids($_[0] // $$) || [] } };
    if ($check eq 'prod') {
        # a stopped production pattern counts as production, and is not run again
        my $p = settings::prod({ values => { prod_patterns => 'acme-eu1;(a+)+$' } });
        my ($ms, $id) = $timed->(sub { settings::prod_class("echo $long", $p) });
        push @e, 'a stopped prod pattern gave ' . ($id // 'no class') . ', want user-prod-2 (production)' unless ($id // '') eq 'user-prod-2';
        push @e, $over->($ms, 'the catastrophic pattern'), $want_stopped->('prod_patterns:2:timeout');
        my @k = $kids->();
        push @e, 'a pattern child still runs: ' . join(' ', @k) if @k;
        push @e, '# U-06: no /proc and no pgrep here, so the left-over child check did not run' unless u06_kids($$);
        ($ms, $id) = $timed->(sub { settings::prod_class("echo x$long", $p) });
        push @e, "the stopped pattern ran again ($ms ms)" if $ms > 300;
        push @e, 'the next call gave ' . ($id // 'no class') . ', want user-prod-2' unless ($id // '') eq 'user-prod-2';
        return @e;
    }
    if ($check eq 'prod-normal') {
        my $p = settings::prod({ values => { prod_patterns => '--context=acme-eu1;db\.acme\.internal' } });
        my %want = ('kubectl get pods --context=acme-eu1' => 'user-prod-1', 'psql -h db.acme.internal -c 1' => 'user-prod-2',
                    'kubectl get pods --context=prod-eu' => 'prod-token', 'git status' => undef);
        for my $t (sort keys %want) {
            my $g = settings::prod_class($t, $p);
            push @e, "'$t' gave " . ($g // 'none') . ', want ' . ($want{$t} // 'none') unless ($g // '') eq ($want{$t} // '');
        }
        push @e, 'a list of texts: no class' unless (settings::prod_class(['git status', 'psql -h db.acme.internal'], $p) // '') eq 'user-prod-2';
        my $n = 20;
        my $max = $o->{max_call_ms} // 50;
        my ($ms) = $timed->(sub { settings::prod_class("make build-$_", $p) for 1 .. $n });
        push @e, sprintf('# U-06 overhead: %.1f ms per call that runs 2 user patterns (one fork)', $ms / $n);
        push @e, "$n calls took $ms ms, over $max ms each" if $ms > $n * $max;
        ($ms) = $timed->(sub { settings::prod_class('make build-1', $p) });
        push @e, sprintf('# U-06 the same call again: %d ms (kept answer)', $ms);
        push @e, 'stopped [' . $stopped->() . '] on normal input' if @userre::STOPPED;
        return @e;
    }
    if ($check eq 'secret') {
        # a stopped secret rule counts as a hit of its class over the whole text: a stopped HARD
        # rule withholds everywhere; a stopped WARN rule does what a WARN hit does
        my $ids = sub { join(',', map { "$_->{rule}/$_->{class}" } @{ $_[0] || [] }) };
        my $dir = "$RUN_TMP/u06-$$";
        util::mkdir_p($dir);
        write_text("$dir/big.txt", "plain\n$long\n", '0600');
        write_text("$dir/big.log", "plain\n$long\n", '0600');
        {
            local %rc::R = (settings => { values => { secret_extra_rules => 'WARN:FOO-[A-Z];HARD:(a+)+$' } });
            my ($ms, $h) = $timed->(sub { secrets::scan("token FOO-A\n$long") });
            push @e, 'HARD stopped: scan [' . $ids->($h) . '], want user-warn-1/WARN and regex-timeout/HARD'
                unless $ids->($h) =~ m{user-warn-1/WARN} && $ids->($h) =~ m{regex-timeout/HARD};
            push @e, $over->($ms, 'scan'), $want_stopped->('secret_extra_rules:2:timeout');
            my ($red) = secrets::redact("plain text\n$long");
            push @e, 'HARD stopped: redact kept text: ' . substr($red, 0, 60) unless $red eq '[redacted:regex-timeout]';
            my ($red2, $rh) = secrets::redact("plain text\n$long", ['HARD']);
            push @e, 'HARD stopped: a HARD-only redaction kept text' unless $red2 eq '[redacted:regex-timeout]' && $ids->($rh) eq 'regex-timeout/HARD';
            my ($cl) = secrets::classify_file("$dir/big.txt");
            push @e, "HARD stopped: classify_file (a text file): $cl, want withhold" unless $cl eq 'withhold';
            my ($cl2, undef, $raw) = secrets::classify_file("$dir/big.log");
            my ($copy) = defined $raw ? secrets::redact($raw) : ('');
            push @e, "HARD stopped: classify_file (a log): $cl2 with a copy that keeps text" unless $cl2 eq 'redact' && $copy eq '[redacted:regex-timeout]';
        }
        userre::clear() if $have;
        {
            local %rc::R = (settings => { values => { secret_extra_rules => 'HARD:ACME-[0-9]{12};WARN:(a+)+$' } });
            my ($ms, $h) = $timed->(sub { secrets::scan("token ACME-123456789012\n$long") });
            push @e, 'WARN stopped: scan [' . $ids->($h) . '], want user-hard-1/HARD and regex-timeout/WARN'
                unless $ids->($h) eq 'user-hard-1/HARD,regex-timeout/WARN';
            push @e, $over->($ms, 'scan'), $want_stopped->('secret_extra_rules:2:timeout');
            my ($red) = secrets::redact("plain text\n$long");
            push @e, 'WARN stopped: redact kept text: ' . substr($red, 0, 60) unless $red eq '[redacted:regex-timeout]';
            # the summary copy's redaction (HARD only, copies.pm): the user's HARD hit only, no
            # regex-timeout hit, the rest kept, as a WARN hit would be
            my ($red2, $rh) = secrets::redact("x ACME-123456789012 y\n$long", ['HARD']);
            push @e, 'WARN stopped: a HARD-only redaction gave [' . $ids->($rh) . '] ' . substr($red2, 0, 40)
                unless $ids->($rh) eq 'user-hard-1/HARD' && $red2 eq "x [redacted:user-hard-1] y\n$long";
            my ($cl, undef, $raw) = secrets::classify_file("$dir/big.txt");
            my ($copy) = defined $raw ? secrets::redact($raw) : ('');
            push @e, "WARN stopped: classify_file (a text file): $cl with a copy that keeps text" unless $cl eq 'redact' && $copy eq '[redacted:regex-timeout]';
        }
        unlink "$dir/big.txt", "$dir/big.log";
        rmdir $dir;
        return @e;
    }
    if ($check eq 'secret-normal') {
        local %rc::R = (settings => { values => { secret_extra_rules => 'HARD:ACME-[0-9]{12};WARN:FOO-[A-Z]' } });
        my $got = join(',', map { "$_->{rule}/$_->{class}/$_->{count}" } @{ secrets::scan("token ACME-123456789012 FOO-AFOO-B\n") });
        push @e, "scan [$got], want [user-hard-1/HARD/1,user-warn-2/WARN/2]" unless $got eq 'user-hard-1/HARD/1,user-warn-2/WARN/2';
        my ($red, $rh) = secrets::redact('x ACME-123456789012 FOO-AFOO-B y');
        push @e, "redact: '$red'" unless $red eq 'x [redacted:user-hard-1] [redacted:user-warn-2] y';
        my $n = join(',', map { "$_->{rule}:$_->{count}" } @$rh);
        push @e, "redact hits [$n]" unless $n eq 'user-hard-1:1,user-warn-2:2';
        ($red) = secrets::redact('x ACME-123456789012 FOO-AFOO-B y', ['HARD']);
        push @e, "redact HARD only: '$red'" unless $red eq 'x [redacted:user-hard-1] FOO-AFOO-B y';
        push @e, 'stopped [' . $stopped->() . '] on normal input' if @userre::STOPPED;
        return @e;
    }
    if ($check eq 'ticket') {
        # the subject is cut to 256 characters, so the catastrophic pattern is exponential: (a{1,30}){1,30}$
        my ($ms, $tk) = $timed->(sub { settings::ticket(('a' x 250) . 'b', { values => { ticket_pattern => '(a{1,30}){1,30}$' } }) });
        push @e, "a stopped ticket pattern gave '$tk', want no ticket" if defined $tk;
        push @e, $over->($ms, 'the catastrophic pattern'), $want_stopped->('ticket_pattern:1:timeout');
        for my $c (['feature/lab_77-x', '(lab_[0-9]+)', 'lab_77'], ['feature/LAB-7-retry', 'LAB-[0-9]+', 'LAB-7'],
                   ['main', '(lab_[0-9]+)', undef], ['feature/x/../y', 'feature/(x/\.\./y)', undef],
                   ['feature/LAB-7-retry', '[A-Z][A-Z0-9]+-[0-9]+', 'LAB-7']) {
            my $g = settings::ticket($c->[0], { values => { ticket_pattern => $c->[1] } });
            push @e, "ticket '$c->[0]' /$c->[1]/: " . ($g // 'none') . ', want ' . ($c->[2] // 'none') unless ($g // '') eq ($c->[2] // '');
        }
        return @e;
    }
    if ($check eq 'relaunch') {
        # a stopped relaunch_allow pattern does not match: the job asks
        my $rl = settings::relaunch({ values => { relaunch_allow => '^make test$;^(a+)+$' } });
        push @e, "'make test' is not allowlisted" unless $allowed->('make test', $rl);
        push @e, "'make deploy' is allowlisted" if $allowed->('make deploy', $rl);
        my ($ms, $ok) = $timed->(sub { $allowed->($long, $rl) });
        push @e, 'a stopped relaunch_allow pattern matched (the job must ask)' if $ok;
        push @e, $over->($ms, 'the catastrophic pattern'), $want_stopped->('relaunch_allow:2:timeout');
        return @e;
    }
    if ($check eq 'protected') {
        # a glob that mixes * and ** keeps the plain translation, bounded: a stopped one protects
        my $p = settings::protected({ values => { protected_branches => 'qa-env;uat/*;**a*a*a*a*a*a*a*a*a*a?' } });
        my $lin = join(' ', map { $_->{linear} // '-' } @{ $p->{globs} });
        push @e, "linear [$lin], want [1 1 0]" unless $lin eq '1 1 0';
        my %want = ('qa-env' => 'user-branch-1', 'uat/eu' => 'user-branch-2', 'uat/eu/x' => undef, 'feat/x' => undef,
                    'x/' . ('a' x 12) => 'user-branch-3');
        for my $t (sort keys %want) {
            my $g = settings::protected_user($t, $p);
            push @e, "'$t' gave " . ($g // 'none') . ', want ' . ($want{$t} // 'none') unless ($g // '') eq ($want{$t} // '');
        }
        my ($ms, $id) = $timed->(sub { settings::protected_user(('a' x 200) . '!b', $p) });
        push @e, 'a stopped glob gave ' . ($id // 'none') . ', want user-branch-3 (protected)' unless ($id // '') eq 'user-branch-3';
        push @e, $over->($ms, 'the catastrophic glob'), $want_stopped->('protected_branches:3:timeout');
        return @e;
    }
    if ($check eq 'name-glob') {
        # a NAME glob compiles to a regex that cannot backtrack: no time bound needed
        local %rc::R = (settings => { values => { secret_extra_rules => 'NAME:*a*a*a*a*a*a*a*a*a*a?' } });
        my ($ms, $d) = $timed->(sub { secrets::denied_name('/tmp/u06-none/' . ('a' x 200) . '!b') });
        push @e, "a 202-character name took $ms ms (the glob backtracks)" if $ms > 500;
        push @e, 'a name the glob does not match is denied' if $d;
        push @e, 'a name the glob matches is not denied' unless secrets::denied_name('/tmp/u06-none/' . ('a' x 20) . 'c');
        push @e, 'stopped [' . $stopped->() . '] (a glob needs no bound)' if @userre::STOPPED;
        return @e;
    }
    if ($check eq 'glob-same') {
        # glob_re answers as the plain translation does, on random globs and names (both flavours);
        # a glob that mixes * and ** gives the plain translation's answer through protected_user
        srand($o->{seed} // 6);
        my $plain = sub {
            my ($g, $dbl) = @_;
            my $rx = join '', map { $_ eq '**' ? '.*' : $_ eq '*' ? '[^/]*' : $_ eq '?' ? '[^/]' : quotemeta($_) }
                              grep { $_ ne '' } split($dbl ? qr/(\*\*|\*|\?)/ : qr/(\*|\?)/, $g);
            return qr/\A$rx\z/s;
        };
        my $pick = sub { my ($set, $n) = @_; return join '', map { $set->[ int rand @$set ] } 1 .. $n };
        my ($n, $bad, $mixed) = (0, 0, 0);
        for my $flavour ('name', 'branch') {
            my $dbl = $flavour eq 'branch' ? '**' : undef;
            my @gs = $flavour eq 'name' ? qw(a b * ?) : ('a', 'b', '/', '*', '?', '**');
            my @ns = $flavour eq 'name' ? qw(a b) : qw(a b /);
            for (1 .. 500) {
                my $g = $pick->(\@gs, 1 + int rand 7);
                my $old = $plain->($g, $dbl);
                if (!settings::glob_linear($g, $dbl)) {
                    next if $mixed >= 40;
                    $mixed++;
                    my $p = { globs => [{ id => 'g', re => $old, at => 1, linear => 0 }] };
                    for (1 .. 5) {
                        my $s = 'a' . $pick->(\@ns, int rand 9);
                        $n++;
                        my ($x, $y) = (defined settings::protected_user($s, $p) ? 1 : 0, $s =~ $old ? 1 : 0);
                        push @e, "mixed glob '$g' on '$s': $x, the plain translation $y" if $x != $y && $bad++ < 5;
                    }
                    next;
                }
                my $new = settings::glob_re($g, $dbl);
                for (1 .. 12) {
                    my $s = $pick->(\@ns, int rand 11);
                    $n++;
                    my ($x, $y) = ($s =~ $new ? 1 : 0, $s =~ $old ? 1 : 0);
                    push @e, "$flavour glob '$g' on '$s': $x, the plain translation $y" if $x != $y && $bad++ < 5;
                }
            }
        }
        push @e, "only $n comparisons ($mixed mixed globs)" if $n < 5000 || $mixed < 10;
        push @e, 'stopped [' . $stopped->() . ']' if @userre::STOPPED;
        return @e;
    }
    if ($check eq 'budget') {
        # after this process spent its budget in pattern children, the rest take the safe side unrun
        userre::limits(0.3, 0.5) if $have;
        my $rl = settings::relaunch({ values => { relaunch_allow => '^(a+)+$;^(a{1,30}){1,30}$;^a' } });
        my ($ms, $ok) = $timed->(sub { $allowed->($long, $rl) });
        push @e, 'allowlisted after the time ran out (the job must ask)' if $ok;
        push @e, "took $ms ms, over 1600" if $ms > 1600;
        # the first is stopped at its limit; the second at what is left of the budget; the third is not run
        push @e, $want_stopped->('relaunch_allow:1:timeout relaunch_allow:2:budget relaunch_allow:3:budget');
        return @e;
    }
    if ($check eq 'no-orphan') {
        # the pattern's child ends by its own alarm when the helper is killed mid-match (KILL), and
        # with the helper when the helper is stopped (TERM, as a hook timeout does)
        return ('# U-06: no /proc and no pgrep here; the check did not run') unless u06_kids($$);
        my @notes;
        for my $sig ('KILL', 'TERM') {
            userre::clear() if $have;
            # TERM: a 2 s limit, so a child that only ends by its own alarm (2.2 s) fails the 1 s bound
            userre::limits($sig eq 'TERM' ? 2 : 1, 5) if $have;
            my $rl = settings::relaunch({ values => { relaunch_allow => '^(a+)+$' } });
            my $pid = fork();
            return ("fork: $!") unless defined $pid;
            if ($pid == 0) { eval { $allowed->($long, $rl) }; POSIX::_exit(0) }
            util::sleep_ms(300);
            my @g = $kids->($pid);
            kill $sig, $pid;
            waitpid($pid, 0);
            return ("$sig: no pattern child under the helper") unless @g;
            my $t0 = util::clock_ms();
            # a child that ended stays a zombie until its new parent reaps it
            my $gone = sub { my $p = $_[0]; return 1 unless kill 0, $p; my $st = util::read_file("/proc/$p/stat"); return defined $st && $st =~ /\)\s+Z/ ? 1 : 0 };
            util::sleep_ms(20) while util::clock_ms() - $t0 < 4000 && grep { !$gone->($_) } @g;
            my $ms = util::clock_ms() - $t0;
            my @left = grep { !$gone->($_) } @g;
            if (@left) { kill 'KILL', @left; return ("$sig: the pattern child outlived the killed helper: " . join(' ', @left)) }
            push @e, "TERM: the pattern child ended $ms ms after its helper, want it with the helper (under 1000 ms)" if $sig eq 'TERM' && $ms > 1000;
            push @notes, sprintf('# U-06 orphan check: after %s the pattern child ended %d ms after its helper', $sig, $ms);
        }
        return (@e, @notes);
    }
    if ($check eq 'no-lock') {
        # the pattern child keeps no descriptor of the helper's: a lock the helper held is free as
        # soon as the helper is killed, while the child still runs (U-06 review: the sweep's lock)
        my $f = "$RUN_TMP/u06-lock-$$";
        my $pid = fork();
        return ("fork: $!") unless defined $pid;
        if ($pid == 0) {
            open(my $lk, '>', $f) or POSIX::_exit(2);
            flock($lk, Fcntl::LOCK_EX()) or POSIX::_exit(3);
            userre::clear() if $have;
            userre::limits(1.5, 3) if $have;
            eval { $allowed->($long, settings::relaunch({ values => { relaunch_allow => '^(a+)+$' } })) };
            POSIX::_exit(0);
        }
        util::sleep_ms(300);
        kill 'KILL', $pid;
        waitpid($pid, 0);
        open(my $lk, '>', $f) or return ("open $f: $!");
        my $free = flock($lk, Fcntl::LOCK_EX() | Fcntl::LOCK_NB()) ? 1 : 0;
        close $lk;
        unlink $f;
        push @e, "the helper's lock is still held after the helper was killed (the pattern child inherited it)" unless $free;
        return @e;
    }
    if ($check eq 'total') {
        # the budget counts all the time in pattern children, not only stopped time: twenty
        # patterns that each finish under the limit stop when it is spent, in one call or in many
        # (U-06 review: 20 deny_class_patterns took the 2 s PermissionDenied hook past its timeout)
        my $budget = $o->{budget} // 0.4;
        userre::limits($lim, $budget) if $have;
        # (a+)+$ on n a's then b: about n * n steps; grow n to about a third of the limit in CPU
        # time (the clock without Time::HiRes off Linux is the child's CPU: a wall-time n on a
        # busy machine left twenty patterns under the budget there)
        my $n = 300;
        while ($n < 400_000) {
            my $s = ('a' x $n) . 'b';
            my @c0 = times;
            my $x = $s =~ /(a+)+$/;
            my @c1 = times;
            last if ($c1[0] + $c1[1]) - ($c0[0] + $c0[1]) >= $lim / 3;
            $n = int($n * 1.4);
        }
        my $subj = ('a' x $n) . 'b';
        my @ents = map { my $c = "(?#$_)"; +{ re => qr/(a+)+$c$/, at => $_ } } 1 .. 20;
        my ($ms, $k) = $timed->(sub { userre::first('deny_class_patterns', \@ents, [$subj], 'skip') });
        my $max = int(($budget + 0.4) * 1000);
        # without Time::HiRes off Linux (no such perl ships: Time::HiRes is core, and only
        # Debian's perl-base drops it) the clock is the child's CPU time, short of the real time
        # on a busy machine: the time is not checked there (U-06-regex-bound-floor runs Linux)
        $max = 1e9 if $o->{no_hires} && $^O ne 'linux';
        push @e, "20 patterns in one call took $ms ms, over $max (the budget $budget s and the kill)" if $ms > $max;
        push @e, 'a pattern not run matched' if defined $k;
        push @e, 'no pattern was left unrun with why budget: [' . $stopped->() . ']' unless grep { $_->[2] eq 'budget' } @userre::STOPPED;
        my $one = $stopped->();
        userre::clear() if $have;
        ($ms) = $timed->(sub { userre::first('prod_patterns', [{ re => qr/(a+)+$/, at => 1 }], ["$subj$_"], 'match') for 1 .. 20 });
        # each child's start, up to $userre::FREE_S, is not counted
        my $max20 = $max + int(20 * ($have ? $userre::FREE_S : 0.05) * 1000);
        $max20 = 1e9 if $o->{no_hires} && $^O ne 'linux';
        push @e, "20 calls of one pattern took $ms ms, over $max20" if $ms > $max20;
        push @e, sprintf('# U-06 total: n=%d; one call: %s', $n, $one);
        return @e;
    }
    if ($check eq 'load') {
        # a stop where the pattern got little CPU (a busy machine: here a pattern that sleeps) is
        # `load`: the pattern runs once more, then takes the safe side for that call only; it is
        # not marked slow. A second try cut by the budget is still `load` (it ran twice; U-06
        # review: it read "not run (the time for your patterns was used up)")
        $userre::CPU_SHARE = 0.5;
        my $nap = [{ re => qr/(?{ select(undef, undef, undef, 30) })/, at => 1 }];
        my ($ms, $k) = $timed->(sub { userre::first('prod_patterns', $nap, ['echo x'], 'match') });
        push @e, 'a pattern stopped as load did not count as a match' unless defined $k && $k == 0;
        push @e, $want_stopped->('prod_patterns:1:load');
        push @e, "stopped after $ms ms, want two tries of $lim s" if $ms < 2 * $lim * 1000 || $ms > 2 * ($lim + 0.5) * 1000;
        ($ms) = $timed->(sub { userre::first('prod_patterns', $nap, ['echo x2'], 'match') });
        push @e, "the next call did not run the pattern again ($ms ms): a busy machine marked it slow" if $ms < $lim * 1000;
        userre::clear() if $have;
        userre::limits(0.25, 0.4) if $have;
        ($ms, $k) = $timed->(sub { userre::first('prod_patterns', $nap, ['echo x3'], 'match') });
        push @e, 'the second try, cut by the budget: ' . $stopped->() . ', want prod_patterns:1:load' unless $stopped->() eq 'prod_patterns:1:load';
        return @e;
    }
    if ($check eq 'accumulate') {
        # the stops of one pattern add up their CPU in the session: on a busy machine (every stop
        # `load` here) a slow pattern is skipped once its stops used its limit, not run again
        # for its whole share in every later process (U-06 review)
        $userre::CPU_SHARE = 1e9;
        my $dir = "$RUN_TMP/u06-acc-$$";
        local %rc::R = (watch => $dir, sid => 'aaaaaaaa-0000-4000-8000-000000000016');
        util::mkdir_p("$dir/$rc::R{sid}/once");
        my $e1 = [{ re => qr/(a+)+$/, at => 1 }];
        my ($calls, $ms) = (0, 0);
        while ($calls < 12) {
            userre::clear() if $have;    # a new process each time
            $calls++;
            ($ms) = $timed->(sub { userre::first('prod_patterns', $e1, ["echo $long"], 'match') });
            last if $ms < 100;
        }
        push @e, "the pattern still ran after $calls processes ($ms ms the last)" if $ms >= 100;
        push @e, $want_stopped->('prod_patterns:1:timeout') if $ms < 100;
        push @e, "# U-06 accumulate: skipped from process $calls on" if $ms < 100;
        userre::clear() if $have;
        userre::first('prod_patterns', $e1, ['echo hello'], 'match');
        push @e, 'a short text did not run the pattern: [' . $stopped->() . ']' if @userre::STOPPED || !$userre::SPENT;
        unlink glob("$dir/$rc::R{sid}/once/*");
        rmdir $_ for "$dir/$rc::R{sid}/once", "$dir/$rc::R{sid}", $dir;
        return @e;
    }
    if ($check eq 'big-linear') {
        # a plain HARD rule on a 10 MB evidence file: the limit grows with the text (0.3 s per
        # MiB), so it runs to the end and the file is copied; a pattern stopped on a large text is
        # remembered with the text's length, so a later short summary still runs it (U-06 review:
        # one stop on a big file withheld every file and redacted every summary copy for the
        # session). The base limit sits under what the rule takes on the file.
        my $dir = "$RUN_TMP/u06-big-$$";
        local %rc::R = (watch => $dir, sid => 'aaaaaaaa-0000-4000-8000-000000000026',
                        settings => { values => { secret_extra_rules => 'HARD:(?i)(?:password|passwd|pwd|secret|token)\s*[:=]\s*\S+' } });
        my $once = "$dir/$rc::R{sid}/once";
        util::mkdir_p($once);
        my $line = "2026-10-26T07:00:00Z INFO worker 17 processed batch 4411 in 23 ms; queue depth 3\n";
        my $text = $line x int(10_000_000 / length $line);
        write_text("$dir/big.txt", $text, '0600');
        my $t0 = util::clock_ms();
        my $n = () = $text =~ /(?i)(?:password|passwd|pwd|secret|token)\s*[:=]\s*\S+/g;
        my $took = (util::clock_ms() - $t0) / 1000;
        my $base = $took / 2 < 0.25 ? $took / 2 : 0.25;
        userre::limits($base, 0.4, 100) if $have;
        my ($cl) = secrets::classify_file("$dir/big.txt");
        push @e, sprintf('a plain rule (%.2f s in process) on 10 MB, base limit %.2f s: %s, want copy; stopped [%s]', $took, $base, $cl, $stopped->())
            unless $cl eq 'copy';
        my @m = glob("$once/regex_slow.*");
        push @e, 'a marker after a plain rule on a big file: ' . join(' ', map { util::basename($_) } @m) if @m;
        push @e, sprintf('# U-06 big-linear: the rule took %.2f s in process; base limit %.2f s', $took, $base);
        # a catastrophic HARD rule stopped on a 1.1 MiB text, then a short summary in a later process
        userre::clear() if $have;
        userre::limits(0.25, 3) if $have;
        local $rc::R{settings} = { values => { secret_extra_rules => 'HARD:(a+)+$' } };
        my $h = secrets::scan(('a' x 1_150_000) . 'b');
        push @e, 'the stopped rule on 1.1 MiB: [' . join(',', map { "$_->{rule}/$_->{class}" } @$h) . '], want regex-timeout/HARD'
            unless grep { $_->{rule} eq 'regex-timeout' && $_->{class} eq 'HARD' } @$h;
        userre::clear() if $have;
        my $sum = "## Summary\nThe build passed; the fix is in lib/foo.pm.\n";
        my ($red, $rh) = secrets::redact($sum, ['HARD']);
        push @e, 'a later short summary: [' . join(',', map { $_->{rule} } @$rh) . '] ' . substr($red, 0, 40) . ', want it kept' unless $red eq $sum && !@$rh;
        $userre::SPENT = 0;
        $h = secrets::scan(('a' x 1_200_000) . 'b');
        push @e, sprintf('a longer text ran the stopped rule again (%.2f s in children)', $userre::SPENT) if $userre::SPENT > 0.05;
        push @e, 'a longer text: not withheld' unless grep { $_->{rule} eq 'regex-timeout' && $_->{class} eq 'HARD' } @$h;
        unlink "$dir/big.txt", glob("$once/*");
        rmdir $_ for $once, "$dir/$rc::R{sid}", $dir;
        return @e;
    }
    if ($check eq 'warn-then-hard') {
        # a stopped WARN rule does not end the run: a HARD rule listed after it still runs, so the
        # stop counts as WARN (U-06 review: it counted as HARD, withheld and wrote a '0 ()' note)
        my $ids = sub { join(',', map { "$_->{rule}/$_->{class}" } @{ $_[0] || [] }) };
        {
            local %rc::R = (settings => { values => { secret_extra_rules => 'WARN:(a+)+$;HARD:zzz' } });
            my $h = secrets::scan("$long\n");
            push @e, 'WARN then HARD: scan [' . $ids->($h) . '], want regex-timeout/WARN' unless $ids->($h) eq 'regex-timeout/WARN';
            my ($red, $rh) = secrets::redact("$long\n", ['HARD']);
            push @e, 'WARN then HARD: a HARD-only redaction gave [' . $ids->($rh) . ']' unless $red eq "$long\n" && !@$rh;
        }
        userre::clear() if $have;
        {
            local %rc::R = (settings => { values => { secret_extra_rules => 'WARN:(a+)+$;HARD:ACME-[0-9]{12}' } });
            my $h = secrets::scan("ACME-123456789012\n$long");
            push @e, 'WARN then a HARD hit: scan [' . $ids->($h) . '], want user-hard-2/HARD,regex-timeout/WARN'
                unless $ids->($h) eq 'user-hard-2/HARD,regex-timeout/WARN';
            push @e, $want_stopped->('secret_extra_rules:1:timeout');
        }
        return @e;
    }
    if ($check eq 'wildcard') {
        # a wildcard property runs while the pattern compiles, in the helper, unbounded (perl 5.30
        # and later; 5.28 refuses the syntax): every pattern key refuses it at load
        my $w = '\p{name=/^(?:(\w+)\s?)+\1[^\w\s]/}';
        my ($ms) = $timed->(sub {
            push @e, 'pattern_ok took a wildcard property' if settings::pattern_ok($w);
            push @e, 'pattern_ok took \P{gc:/L/}' if settings::pattern_ok('\P{gc:/L/}');
            my $x = settings::secret_extra({ values => { secret_extra_rules => "HARD:$w;WARN:$w;HARD:ok" } });
            push @e, 'secret_extra_rules: invalid [' . join(',', @{ $x->{invalid} }) . '], want [1,2]' unless "@{ $x->{invalid} }" eq '1 2' && @{ $x->{rules} } == 1;
            push @e, 'ticket_pattern took a wildcard property' unless settings::ticket_re({ values => { ticket_pattern => $w } })->{invalid};
            my $rl = settings::relaunch({ values => { relaunch_allow => "^$w;^make test\$" } });
            push @e, 'relaunch_allow took a wildcard property' unless @{ $rl->{allow} } == 1;
            my $p = settings::prod({ values => { prod_patterns => $w } });
            push @e, 'prod_patterns took a wildcard property' unless @{ $p->{invalid} } == 1 && !$p->{user};
        });
        push @e, "refusing took $ms ms" if $ms > 2000;
        for my $ok ('\p{L}+', '\p{Script=Latin}', '\p{name: LATIN SMALL LETTER A}', '\pN') {
            push @e, "pattern_ok refused $ok" unless settings::pattern_ok($ok);
        }
        return @e;
    }
    if ($check eq 'trim') {
        # a setting is split and trimmed before any cap: the trim must be linear (U-06 review:
        # s/^\s+|\s+$//g took 0.5 s on 40,000 inner spaces, 43 s on 400,000)
        my $v = 'a' . (' ' x 400_000) . 'b; c ';
        my ($ms, @l) = $timed->(sub { settings::list($v) });
        push @e, "settings::list took $ms ms on 400,000 inner spaces" if $ms > 500;
        push @e, 'settings::list: [' . join('|', map { length } @l) . '], want [400002|1]' unless "@{[map { length } @l]}" eq '400002 1';
        ($ms) = $timed->(sub { settings::trim(' x' . (' ' x 400_000) . 'y ') });
        push @e, "settings::trim took $ms ms" if $ms > 500;
        push @e, 'settings::trim kept the ends' unless settings::trim("  x y \n") eq 'x y';
        # the watcher reads `watcher` and `handoff_turn` itself (U-06 review: both kept the
        # quadratic form, 2.5 s and 1.8 s on 100,000 inner spaces)
        require watch::ctx;
        my $w = ' shadow' . (' ' x 400_000) . 'x ';
        my ($wv, $wu);
        ($ms) = $timed->(sub { ($wv, $wu) = watch::ctx::_watcher_value({ watcher => $w }) });
        push @e, "watch::ctx::_watcher_value took $ms ms on 400,000 inner spaces" if $ms > 500;
        push @e, "watch::ctx::_watcher_value: $wv/$wu, want shadow/1" unless "$wv/$wu" eq 'shadow/1';
        push @e, 'watch::ctx::_watcher_value: " OFF " is not off' unless (watch::ctx::_watcher_value({ watcher => " OFF \n" }))[0] eq 'off';
        my $s;
        ($ms) = $timed->(sub { $s = watch::ctx::_settings({ settings => { values => { handoff_turn => $w } } }) });
        push @e, "watch::ctx::_settings (handoff_turn) took $ms ms on 400,000 inner spaces" if $ms > 500;
        push @e, 'watch::ctx::_settings: " Off " is not off' unless watch::ctx::_settings({ settings => { values => { handoff_turn => " Off " } } })->{handoff_turn} eq 'off';
        return @e;
    }
    if ($check eq 'no-hash') {
        # a process hashes a pattern only when the session has a marker for its key (U-06 review:
        # pure-Perl sha256 on Debian perl-base cost about 1 ms a pattern before any fork)
        my $dir = "$RUN_TMP/u06-hash-$$";
        local %rc::R = (watch => $dir, sid => 'aaaaaaaa-0000-4000-8000-000000000036');
        util::mkdir_p("$dir/$rc::R{sid}/once");
        my $n = 0;
        my $orig = \&sha::hex256;
        no warnings 'redefine';
        local *sha::hex256 = sub { $n++; return $orig->(@_) };
        my @ents = map { { re => qr/zz$_/, at => $_ } } 1 .. 32;
        userre::first('prod_patterns', \@ents, ['echo hello'], 'match');
        push @e, "$n sha256 calls with no marker in the session, want 0" if $n;
        rmdir $_ for "$dir/$rc::R{sid}/once", "$dir/$rc::R{sid}", $dir;
        return @e;
    }
    if ($check eq 'persist') {
        # a slow pattern is not run again in a later process of the session: a marker in the
        # session's once/ folder, named by key and the pattern's sha256 (never the pattern)
        my $dir = "$RUN_TMP/u06-persist-$$";
        local %rc::R = (watch => $dir, sid => 'aaaaaaaa-0000-4000-8000-000000000006');
        my $once = "$dir/$rc::R{sid}/once";
        my $p = settings::prod({ values => { prod_patterns => '(a+)+$' } });
        settings::prod_class("echo $long", $p);
        my @m = glob("$once/regex_slow.*");
        push @e, 'markers [' . join(' ', map { util::basename($_) } @m) . '], want one regex_slow.prod_patterns.<16 hex>'
            unless @m == 1 && util::basename($m[0]) =~ /\Aregex_slow\.prod_patterns\.[0-9a-f]{16}\z/;
        userre::clear() if $have;    # a new process: nothing in memory
        my ($ms, $id) = $timed->(sub { settings::prod_class("echo x$long", $p) });
        push @e, "a later process ran the slow pattern again ($ms ms)" if $ms > 200;
        push @e, 'a later process gave ' . ($id // 'no class') . ', want user-prod-1' unless ($id // '') eq 'user-prod-1';
        push @e, $want_stopped->('prod_patterns:1:timeout');
        my $p2 = settings::prod({ values => { prod_patterns => '(a+)+$x' } });
        ($ms) = $timed->(sub { settings::prod_class("echo $long", $p2) });
        push @e, "a changed pattern was not run ($ms ms)" if $ms < $lim * 1000;
        unlink glob("$once/*");
        rmdir $_ for $once, "$dir/$rc::R{sid}", $dir;
        return @e;
    }
    if ($check eq 'ticket-limit') {
        # ticket_pattern has one limit whoever calls (0.25 s), so a pattern near a caller's limit
        # cannot give a ticket in one process and none in another
        userre::limits(1, 3) if $have;
        my ($ms, $tk) = $timed->(sub { settings::ticket(('a' x 250) . 'b', { values => { ticket_pattern => '(a{1,30}){1,30}$' } }) });
        push @e, "a stopped ticket pattern gave '$tk'" if defined $tk;
        push @e, "the ticket pattern was stopped after $ms ms with a caller's limit of 1 s, want its own 0.25 s" if $ms > 800;
        return @e;
    }
    if ($check eq 'many-match') {
        # a normal WARN rule with about 60,000 matches (a long answer, read in many chunks) is
        # never stopped; without Time::HiRes the clock once read whole seconds and stopped it
        local %rc::R = (settings => { values => { secret_extra_rules => 'WARN:tok[0-9]+' } });
        my $bad = 0;
        for my $i (1 .. ($o->{rounds} // 12)) {
            my $text = join(' ', map { "tok$_" } 1 .. 60_000) . " r$i";
            my $h = secrets::scan($text);
            my $got = join(',', map { "$_->{rule}/$_->{count}" } @$h);
            push @e, "round $i: scan [$got], want [user-warn-1/60000]" if $got ne 'user-warn-1/60000' && $bad++ < 3;
        }
        push @e, 'stopped [' . $stopped->() . '] on normal input' if @userre::STOPPED;
        return @e;
    }
    if ($check eq 'rows-gate') {
        # the watcher's push check runs when only the bounded entries (globs that mix * and **)
        # are set: no spec protected_branch_re and no other user entry
        require watch::rows;
        my $p = settings::protected({ values => { protected_branches => 'rel/**/x*' } });
        my @b = grep { defined $_->{linear} && !$_->{linear} } @{ $p->{globs} };
        push @e, 'rel/**/x* is not a bounded entry' unless @b == 1;
        local $watch::rows::PROTECTED_RE = undef;
        local $watch::rows::PROTECTED_USER = [];
        local $watch::rows::PROTECTED_BOUNDED = { globs => \@b };
        my $row = { type => 'assistant', message => { content => [{ type => 'tool_use', id => 't1', name => 'Bash', input => { command => 'git push origin rel/eu/x1' } }] } };
        my $f = watch::rows::classify($row, 'afk-compact', [['push', qr/\bgit\s+push\b/]]);
        my ($c) = @{ ref $f eq 'HASH' && ref $f->{calls} eq 'ARRAY' ? $f->{calls} : [] };
        push @e, 'a push to rel/eu/x1 is not protected with only a bounded entry set' unless $c && $c->{protected};
        return @e;
    }
    # (a+)+$ on n a's then b, n grown until one match takes about `secs` of CPU here
    my $calibrate = sub {
        my ($secs) = @_;
        my $n = 300;
        while ($n < 400_000) {
            my $s = ('a' x $n) . 'b';
            my @c0 = times;
            my $x = $s =~ /(a+)+$/;
            my @c1 = times;
            last if ($c1[0] + $c1[1]) - ($c0[0] + $c0[1]) >= $secs;
            $n = int($n * 1.2);
        }
        return $n;
    };
    if ($check eq 'budget-no-mark') {
        # a run the budget cut short is not remembered against the pattern (U-06 review: ten such
        # cuts in processes with 0.12 s left added up to the pattern's 1 s limit, and a process
        # with room then skipped it as timeout where it finishes in 0.3 s)
        my $dir = "$RUN_TMP/u06-bnm-$$";
        local %rc::R = (watch => $dir, sid => 'aaaaaaaa-0000-4000-8000-000000000046');
        my $once = "$dir/$rc::R{sid}/once";
        util::mkdir_p($once);
        my $subj = 'echo ' . ('a' x $calibrate->(0.3)) . 'b';
        my $e1 = [{ re => qr/(a+)+$/, at => 1 }];
        my $bad = 0;
        for my $p (1 .. 10) {
            userre::clear() if $have;    # a new process, little of its budget left
            userre::limits(1, 0.12) if $have;
            userre::first('prod_patterns', $e1, ["$subj $p"], 'match');
            push @e, "tight process $p: stopped [" . $stopped->() . '], want prod_patterns:1:budget' if $stopped->() ne 'prod_patterns:1:budget' && $bad++ < 2;
        }
        my @m = glob("$once/regex_slow.*");
        push @e, 'markers after cuts by the budget only: ' . join(' ', map { util::basename($_) . ' (' . (util::read_file($_) // '') =~ tr/\n// . ' runs)' } @m) if @m;
        userre::clear() if $have;    # a process with room
        userre::limits(2, 4) if $have;
        my $k = userre::first('prod_patterns', $e1, [$subj], 'match');
        push @e, 'a process with room: stopped [' . $stopped->() . '], want the pattern run to the end' if @userre::STOPPED;
        unlink glob("$once/*");
        rmdir $_ for $once, "$dir/$rc::R{sid}", $dir;
        return @e;
    }
    if ($check eq 'ticket-own-time') {
        # ticket_pattern has time of its own: a process whose budget a stopped pattern spent still
        # gives the branch its ticket, and the ticket takes nothing from the budget (U-06 review:
        # it gave none, and the copy went under repo/<topic> instead of repo/<ticket>)
        userre::limits(0.25, 0.25) if $have;
        settings::prod_class("echo $long", settings::prod({ values => { prod_patterns => '(a+)+$' } }));
        my $spent = $userre::SPENT;
        push @e, sprintf('the stopped prod pattern left %.3f s of the budget, want none (the check needs it spent)', 0.25 - $spent) if 0.25 - $spent > 0.01;
        my $tk = settings::ticket('feature/lab_77-x', { values => { ticket_pattern => '(lab_[0-9]+)' } });
        push @e, 'a spent budget: ticket ' . ($tk // 'none') . ', want lab_77; stopped [' . $stopped->() . ']' unless ($tk // '') eq 'lab_77';
        push @e, sprintf('the ticket took %.3f s from the budget', $userre::SPENT - $spent) if $userre::SPENT != $spent;
        return @e;
    }
    if ($check eq 'manifest-reserve') {
        # the report scans its manifest last, inside userre::reserve('manifest'): a budget the
        # files spent does not stop the user's secret rules on it (U-06 review: every rule was
        # `budget`, the scan gave regex-timeout and the report died 'secret in the manifest')
        local %rc::R = (settings => { values => { secret_extra_rules => 'HARD:ACME-[0-9]{12}' } });
        my $m = '{"files":[{"name":"rows.jsonl","bytes":12}],"watcher":"shadow"}';
        my $ids = sub { join(',', map { $_->{rule} } @{ $_[0] || [] }) };
        userre::limits(0.25, 0.4) if $have;
        $userre::SPENT = 0.4;    # the files spent the budget
        my $h = secrets::scan($m);
        push @e, 'the budget spent, no reserve: scan [' . $ids->($h) . '], want regex-timeout' unless $ids->($h) eq 'regex-timeout';
        userre::clear() if $have;
        userre::limits(0.25, 0.4) if $have;
        $userre::SPENT = 0.4;
        $h = defined &userre::reserve ? userre::reserve('manifest', sub { secrets::scan($m) }) : secrets::scan($m);
        push @e, 'the budget spent, in the manifest reserve: scan [' . $ids->($h) . '], want no hit' if @$h;
        push @e, 'the manifest scan took time from the budget' if $userre::SPENT != 0.4;
        return @e;
    }
    if ($check eq 'answer-not-limit') {
        # a pattern that matched at once but answers with very many numbers: sending the answer
        # does not count against its limit (the child's `D` line; a09efae)
        userre::limits(0.2, 30, 30) if $have;
        my $want = $o->{numbers} // 3_000_000;
        my ($ms, $res, $st) = $timed->(sub { userre::run('prod_patterns', [{ re => qr/x/, at => 1 }], sub { return (1 .. $want) }) });
        my $got = $res->[0] ? scalar @{ $res->[0] } : 0;
        push @e, "an answer of $want numbers: $got back, stopped [" . $stopped->() . "] after $ms ms, want all of it" unless $got == $want && !@$st;
        push @e, "# U-06 answer-not-limit: $want numbers in $ms ms";
        return @e;
    }
    if ($check eq 'ceiling') {
        # the budget grows with a large text but never past the caller's ceiling (sweep 5 s,
        # checkpoint 6 s, Stop 3 s): twenty patterns that each finish under their limit on a
        # 3 MiB text stop when the ceiling is spent, so the hook stays inside its timeout
        userre::limits(0.25, 0.4, 1) if $have;
        my @ents = map { +{ re => qr/x$_/, at => $_ } } 1 .. 20;
        my ($ms, $res, $st) = $timed->(sub {
            userre::run('prod_patterns', \@ents, sub { select(undef, undef, undef, 0.3); return (0) }, size => 3 << 20) });
        my $done = grep { $res->[$_] } 0 .. 19;
        push @e, "20 patterns of 0.3 s on 3 MiB took $ms ms, over the ceiling of 1 s and the kill (1700 ms)" if $ms > 1700;
        push @e, 'no pattern was left unrun with why budget: [' . $stopped->() . ']' unless grep { $_->[2] eq 'budget' } @userre::STOPPED;
        push @e, "$done patterns finished, want 2 or more (the limit grows with the text)" if $done < 2;
        push @e, "# U-06 ceiling: $done of 20 finished in $ms ms";
        return @e;
    }
    if ($check eq 'load-no-time') {
        # a `load` stop that leaves no budget for the second try: the pattern ran once, so it
        # reads `load`, not `budget` ("not run (the time for your patterns was used up)")
        $userre::CPU_SHARE = 0.5;
        userre::limits(0.25, 0.255) if $have;
        my $nap = [{ re => qr/(?{ select(undef, undef, undef, 30) })/, at => 1 }];
        my $k = userre::first('prod_patterns', $nap, ['echo x5'], 'match');
        push @e, 'a pattern stopped as load did not count as a match' unless defined $k && $k == 0;
        push @e, $want_stopped->('prod_patterns:1:load');
        return @e;
    }
    return ("unknown check '$check'");
}

sub builtin {
    my ($name, $a, $cdir) = @_;
    _libs();
    my @e;
    if ($name eq 'detect_tsv') {
        my $tsv = src_file($a->{tsv}, $cdir);
        my $dir = $a->{dir} ? src_file($a->{dir}, $cdir) : util::dirname($tsv);
        open(my $fh, '<:raw', $tsv) or return ("cannot read $tsv");
        # copy_trailers.json beside the TSV: extra installed-message trailers for this table only
        # (AT-P5-02 'sentinel then a listed trailer'), added to the shipped lists.
        my $xt = -f "$dir/copy_trailers.json" ? eval { jsonc::decode(util::read_file("$dir/copy_trailers.json")) } : undef;
        no warnings "once";
        local @detect::TRAILERS = (detect::_trailers(), map { qr/$_/ } @{ ref $xt eq 'HASH' ? $xt->{copy_trailers} || [] : [] });
        my $head = <$fh>;
        chomp $head;
        my @cols = split /\t/, $head;
        my $n = 0;
        while (my $l = <$fh>) {
            chomp $l;
            next if $l =~ /^\s*(#|$)/;
            my %r;
            @r{@cols} = split /\t/, $l, -1;
            $n++;
            my $text = util::read_file("$dir/$r{file}");
            if (!defined $text) { push @e, "$r{file}: missing"; next }
            # The corpus carries the brand as {{plugin}} (tests/fixtures/README.md).
            utf8::decode($text) unless utf8::is_utf8($text);
            my $bn = ctx::brand();
            $text =~ s/\{\{plugin\}\}/$bn/g;
            my %vc;
            # dispatch column: '' text alone; 'none' a PostCompact with no dispatch at all;
            # a fixtures path (watch/dispatch-<nonce>.json) the record of this compaction,
            # whose agent_id / channel give the proven scope (MOD-SPEC §2.4 P1); an 8-hex
            # nonce is still taken as the dispatch nonce alone.
            my $d = $r{dispatch} // '';
            if ($d eq 'none') {
                $vc{marker_has_record} = 0;
            } elsif ($d =~ /^[0-9a-f]{8}$/) {
                $vc{dispatch_nonce} = $d;
            } elsif ($d ne '') {
                my $raw = util::read_file(src_file($d, $cdir));
                my $rec = defined $raw ? eval { jsonc::decode($raw) } : undef;
                if (ref $rec ne 'HASH') { push @e, "$r{file}: dispatch $d unreadable"; next }
                $vc{dispatch_nonce} = $rec->{nonce};
                $vc{scope} = defined $rec->{agent_id} ? 'sub'
                           : ($rec->{channel} // '') =~ /^mod-(hook|self)$/ ? 'main' : 'unknown';
            }
            $vc{scope} = $r{proof} if defined $r{proof} && $r{proof} =~ /^(main|sub|unknown)$/;
            my $s = detect::summary($text, \%vc);
            # "sha": "template" (case-local TSVs, RN-1): the sha of the normalized body with the
            # brand written back as {{plugin}}, so the expected value holds under any brand.
            my $sha = $s->{sha256};
            if (($a->{sha} // '') eq 'template') {
                (my $n = $s->{normalized}) =~ s/\Q$bn\E/{{plugin}}/g;
                $sha = sha::hex256($n);
            }
            my %got = (verdict => $s->{verdict}, marker_line => $s->{marker_line} // '-', sentinel_from_end => $s->{sentinel_from_end} // '-',
                       nonce => $s->{nonce} // '-', scope => $s->{scope} // '-', normalized_sha256 => $sha,
                       sentinel_place => $s->{sentinel_place} // '-');
            for my $k (qw(verdict marker_line sentinel_from_end nonce scope normalized_sha256 sentinel_place)) {
                next unless exists $r{$k} && defined $r{$k} && $r{$k} ne '';
                push @e, "$r{file}: $k $got{$k}, want $r{$k}" if $got{$k} ne $r{$k};
            }
        }
        close $fh;
        push @e, "no rows in $tsv" unless $n;
        return @e;
    }
    if ($name eq 'assemble_goldens') {
        my $dir = $a->{dir} // "$FIXTURES_DIR/assembly/expected";
        my $rt = assembly_runtime($a->{runtime});
        my %stem = map { (my $f = $assemble::FILES{$_}) =~ s/\.txt$//; ($f => $_) } keys %assemble::FILES;
        my $n = 0;
        for my $f (util::list_dir($dir)) {
            next unless $f =~ /^(.+?)__(.+)\.txt$/;
            my ($s, $t) = ($1, $2);
            my $asset = $stem{$s} // do { push @e, "$f: unknown asset"; next };
            my @tags = $t eq 'base' ? () : split /\+/, $t;
            my $want = util::read_file("$dir/$f");
            utf8::decode($want);
            my $got = assemble::asset($asset, \@tags, $rt);
            $n++;
            next if $got eq $want;
            my $i = 0;
            $i++ while $i < length($got) && $i < length($want) && substr($got, $i, 1) eq substr($want, $i, 1);
            push @e, "$f differs at char $i: got " . jsonc::encode(substr($got, $i, 40)) . ' want ' . jsonc::encode(substr($want, $i, 40));
        }
        push @e, "no goldens in $dir" unless $n;
        return @e;
    }
    if ($name eq 'sha_vectors') {
        push @e, 'abc vector' unless sha::pure_hex256('abc') eq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
        push @e, 'empty vector' unless sha::pure_hex256('') eq 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
        if (eval { require Digest::SHA; 1 }) {
            for my $n (0, 1, 55, 56, 57, 63, 64, 65, 119, 120, 121, 1000, 70000) {
                my $s = join '', map { chr(($_ * 31 + $n) % 256) } 0 .. $n - 1;
                push @e, "length $n differs" unless sha::pure_hex256($s) eq Digest::SHA::sha256_hex($s);
            }
        }
        return @e;
    }
    if ($name eq 'json_roundtrip') {
        return () unless eval { require JSON::PP; 1 };
        my $pp = JSON::PP->new->canonical(1);
        my @stack = ($a->{dir} // "$REPO/tests");
        while (@stack) {
            my $d = pop @stack;
            if (-d $d) { push @stack, map { "$d/$_" } util::list_dir($d); next }
            next unless $d =~ /\.json$/;
            my $raw = util::read_file($d);
            my $mine = eval { jsonc::decode($raw) };
            my $theirs = eval { $pp->decode($raw) };
            if (!defined $theirs) { push @e, "$d: JSON::PP refuses it" if defined $mine; next }
            if (!defined $mine) { push @e, "$d: embedded codec refuses it"; next }
            my $a1 = $pp->encode($theirs);
            my $a2 = $pp->encode($pp->decode(jsonc::encode_bytes($mine)));
            push @e, "$d: round trip differs" unless $a1 eq $a2;
        }
        return @e;
    }
    if ($name eq 'floor_lint') {
        # AT-P-11 (PKG-RUNTIME B.2): every .pl/.pm under plugin/helper (or args.root), three rules.
        # L1 modules: every use/require is a floor module (RUNTIME §2.4, plus overload, lib and
        #   utf8, probed present in debian:bookworm-slim perl-base), one of the helper's own
        #   libraries, or sits inside an eval with a fallback. `feature` is the core pragma (its
        #   newer features are L3).
        # L2 implicit loads: %+ %- $+{ $-{ (Tie::Hash::NamedCapture), \N{NAME} (charnames),
        #   \p{..} \P{..} (Unicode tables), use open, Encode::.
        # L3 version: use v5.N / use 5.0NN above the floor, use feature with a post-5.28
        #   feature, any builtin:: call.
        # Each hit is one line `<file>:<line>: <what> <reason>. Fix: <fix>.` (PR-4 convention).
        # args.want: regexes each hit list must match; args.known: {relative file: reason}, hits
        # in that file are accepted (an entry whose file is clean is harmless: drop it after the fix lands).
        my %floor = map { $_ => 1 } qw(strict warnings constant Fcntl POSIX Errno Cwd File::Spec File::Path File::Temp
            File::Basename IPC::Open3 Getopt::Long IO::Handle List::Util Scalar::Util Text::ParseWords IO::File IO::Select
            Socket Exporter Carp parent integer bytes overload lib utf8 feature);
        # optional: loaded only inside an eval on the same line (W-BETA B.6 allows DEFLATE for the
        # report zip only when present: watch-to-core W2C-4)
        my %optional = map { $_ => 1 } qw(Digest::SHA Time::HiRes IO::Compress::RawDeflate IO::Uncompress::RawInflate);
        my $root = defined $a->{root} ? $a->{root} : "$REPO/plugin/helper";
        # The floor value has one source in the helper: main.pl's guard (`$] < 5.028`).
        my ($floor_v) = (util::read_file("$REPO/plugin/helper/main.pl") // '') =~ /\$\]\s*<\s*(5\.\d+)/;
        $floor_v //= '5.028';
        my $floor_txt = sprintf('%d.%d', int($floor_v), int((($floor_v - int $floor_v) * 1000) + 0.5));
        my %newfeat = map { $_ => 1 } qw(isa try defer class module_true extra_paired_delimiters signatures);
        my $pb = "perl-base $floor_txt (Debian 10)";
        my @l2 = (
            [qr/\$[+-]\{|(?:keys|values|each|exists|delete|scalar)\s*\(?\s*%[+-](?![\w])|\\%[+-](?![\w])|[=(,]\s*%[+-]\s*[;,)]/,
             '%+ / %- load Tie::Hash::NamedCapture, which ' . $pb . ' lacks', 'numbered captures ($1, $2)'],
            [qr/\\N\{(?!U\+)/, '\\N{NAME} loads charnames, which perl-base trims', '\\x{HEX} escapes'],
            [qr/\\[pP](?:\{|[A-Z])/, '\\p{..} / \\P{..} load Unicode property tables, which perl-base trims', 'an explicit character class'],
            [qr/\buse\s+open\b/, 'use open loads open.pm and the Encode layers, not on the floor', 'binmode :raw and encode once at the edge (util::to_bytes)'],
            [qr/\bEncode::/, 'Encode is not in perl-base', 'utf8::encode / utf8::decode'],
        );
        my %own;
        my @stack = ("$root/lib");
        while (@stack) {
            my $d = pop @stack;
            for my $f (util::list_dir($d)) {
                if (-d "$d/$f") { push @stack, "$d/$f"; next }
                next unless $f =~ /\.pm$/;
                (my $rel = substr("$d/$f", length("$root/lib/"))) =~ s/\.pm$//;
                $rel =~ s{/}{::}g;
                $own{$rel} = 1;
            }
        }
        my %known = %{ $a->{known} || {} };
        my (%known_hit, @hits);
        @stack = ($root);
        my $n = 0;
        while (@stack) {
            my $d = pop @stack;
            for my $f (sort(util::list_dir($d))) {
                my $p = "$d/$f";
                if (-d $p) { push @stack, $p; next }
                next unless $f =~ /\.p[lm]$/;
                my $rel = substr($p, length("$root/"));
                my $src = util::read_file($p);
                my ($ln, $pod) = (0, 0);
                my @fh;
                for my $line (split /\n/, $src) {
                    $ln++;
                    if ($line =~ /^=(\w+)/) { $pod = $1 ne 'cut'; next }
                    next if $pod || $line =~ /^\s*#/;
                    last if $line =~ /^__(END|DATA)__\b/;
                    while ($line =~ /\b(use|require)\s+([A-Za-z_][A-Za-z0-9_:]*)/g) {
                        my ($kw, $m) = ($1, $2);
                        next if $m =~ /^v?\d/ || $m eq 'if';
                        $n++;
                        next if $floor{$m} || $own{$m};
                        next if $optional{$m} && $line =~ /eval\s*\{/;
                        push @fh, "$rel:$ln: $kw $m is not on the $pb floor list. Fix: a floor module, or load it in an eval with a fallback.";
                    }
                    while ($line =~ /\brequire\s+"([^"\$]+)\.pm"/g) {
                        (my $m = $1) =~ s{/}{::}g;
                        $n++;
                        push @fh, "$rel:$ln: require \"$1.pm\" is not a helper library. Fix: require a file under helper/lib." unless $own{$m};
                    }
                    for my $r (@l2) {
                        push @fh, "$rel:$ln: $r->[1]. Fix: $r->[2]." if $line =~ $r->[0];
                    }
                    if ($line =~ /\buse\s+(v5\.(\d+)(?:\.\d+)?|5\.(\d{3})(?:_?\d+)?)\b/) {
                        my $minor = defined $2 ? $2 : 0 + $3;
                        my $fmin = int((($floor_v - int $floor_v) * 1000) + 0.5);
                        push @fh, "$rel:$ln: use $1 needs perl 5.$minor, above the floor $floor_txt. Fix: drop it (use strict; use warnings)."
                            if $minor > $fmin;
                    }
                    if ($line =~ /\buse\s+feature\b(.*)/) {
                        my $rest = $1;
                        for my $ft (grep { $newfeat{$_} } $rest =~ /([a-z_]+)/g) {
                            push @fh, "$rel:$ln: feature '$ft' is newer than perl $floor_txt. Fix: plain subs and eval blocks.";
                        }
                    }
                    push @fh, "$rel:$ln: builtin:: functions need perl 5.36, above the floor $floor_txt. Fix: Scalar::Util / List::Util or plain code."
                        if $line =~ /\bbuiltin::/;
                }
                if (exists $known{$rel}) { $known_hit{$rel} = scalar @fh; next }
                push @hits, @fh;
            }
        }
        push @hits, 'no use/require found' unless $n;
        if ($a->{want}) {
            for my $re (@{ $a->{want} }) { push @e, "no lint hit matches /$re/" unless grep { /$re/ } @hits }
            my @un = grep { my $h = $_; !grep { $h =~ /$_/ } @{ $a->{want} } } @hits;
            push @e, map { "unexpected lint hit: $_" } @un;
            return @e;
        }
        return @hits;
    }
    if ($name eq 'secret_corpus') {
        # PRIV-05: every entry and name of tests/fixtures/secrets/corpus.json through the shipped
        # gate. An entry's class: HARD -> a HARD hit, WARN -> a hit, none -> no hit. Redaction
        # (all rules, the log/JSON path; HARD only, the summary path for HARD entries) leaves no
        # fragment of 8+ characters. A name: withheld <-> denied by name. Rule ids are reported
        # (the corpus ids are WP-fix's; they are not compared). `known_gaps` {id: reason} turns
        # that entry's failures into TODO lines (a gap another work package owns).
        my $c = eval { jsonc::decode(util::read_file("$FIXTURES_DIR/secrets/corpus.json")) };
        return ('no secret corpus') unless ref $c eq 'HASH';
        my %gap = %{ $a->{known_gaps} || {} };
        my $n = 0;
        for my $en (@{ $c->{entries} || [] }) {
            my $v = join('', @{ $en->{fragments} || [] });
            my @frag = grep { length >= 8 } @{ $en->{fragments} || [] };
            my $hits = secrets::scan($v);
            my $cls = $en->{class} // 'none';
            my @mine;
            push @mine, "class $cls: no HARD hit" if $cls eq 'HARD' && !secrets::has_hard($hits);
            push @mine, "class $cls: no hit" if $cls eq 'WARN' && !@$hits;
            push @mine, 'control: hit ' . secrets::rule_ids($hits) if $cls eq 'none' && @$hits;
            if ($cls ne 'none') {
                my ($all) = secrets::redact("x $v x");
                push @mine, 'redacted (all rules) keeps a fragment' if grep { index($all, $_) >= 0 } @frag;
                if ($cls eq 'HARD') {
                    my ($hard) = secrets::redact("x $v x", ['HARD']);
                    push @mine, 'redacted (HARD rules, the summary path) keeps a fragment' if grep { index($hard, $_) >= 0 } @frag;
                }
            }
            $n++;
            next unless @mine;
            if (exists $gap{ $en->{id} }) { print "# TODO $en->{id}: @mine ($gap{ $en->{id} })\n"; next }
            push @e, map { "entry $en->{id}: $_" } @mine;
        }
        for my $nm (@{ $c->{names} || [] }) {
            my $want = ($nm->{expect} // '') eq 'withheld' ? 1 : 0;
            my $got = secrets::denied_name("/tmp/corpus/$nm->{name}") ? 1 : 0;
            $n++;
            push @e, "name $nm->{name}: " . ($got ? 'withheld' : 'copied') . ", want $nm->{expect}" if $got != $want;
        }
        push @e, 'no corpus entries' unless $n;
        return @e;
    }
    if ($name eq 'resume_block') {
        # AT-TX-11 H half (T-TEXT E3) and text-to-core C-1: resumeblock::build over a stand-in
        # protocol of protocol_chars, the fixed lines (frame_chars, default 300) and a measured block of
        # remeasure_bytes keeps the block
        # untrimmed within max; the tags it asks the asset for are exactly `tags`.
        for my $l (qw(measure resumeblock)) { require "$l.pm" }
        no warnings qw(redefine once);
        my @seen;
        local *assemble::asset = sub { my ($n, $tags, $rt) = @_; @seen = @{ $tags || [] };
                                       return ('P' x ($a->{protocol_chars} // 3000)) . "\n" . ('F' x ($a->{frame_chars} // 300)) . "\n" . ($rt->{remeasure} // '') };
        local %rc::R = (settings => { values => { unattended_prod_reads => $a->{reads} // 'forbid' } });
        my $n = int(($a->{remeasure_bytes} // 3000) / 100);
        my $re = join("\n", map { sprintf('%-99s', "fact $_") } 1 .. $n);
        my $t = resumeblock::build(sid => 'x', midturn => $a->{midturn}, nonok => $a->{nonok}, saved_copy => 'p', measured_at => 'now', remeasure => $re);
        push @e, 'block is ' . length($t) . " chars > $a->{max}" if defined $a->{max} && length($t) > $a->{max};
        push @e, 'the measured block was trimmed' if $a->{untrimmed} && index($t, $re) < 0;
        push @e, 'tags [' . join(',', @seen) . '], want [' . join(',', @{ $a->{tags} }) . ']' if $a->{tags} && join(',', @seen) ne join(',', @{ $a->{tags} });
        return @e;
    }
    if ($name eq 'bd2_pins') {
        # AT-ST-12 (BD-2, C-STORE D6): the corpus pins `redacted` (the exact text after redaction
        # with every rule) and `markers` (the marker count) hold, and across every entry's output
        # no two markers touch or sit apart by whitespace only (one marker per merged span).
        my $c = eval { jsonc::decode(util::read_file("$FIXTURES_DIR/secrets/corpus.json")) };
        return ('no secret corpus') unless ref $c eq 'HASH';
        my $pins = 0;
        for my $en (@{ $c->{entries} || [] }) {
            my $v = join('', @{ $en->{fragments} || [] });
            my ($out) = secrets::redact($v);
            if (defined $en->{redacted}) { $pins++; push @e, "entry $en->{id}: redacted " . jsonc::encode($out) . ", want " . jsonc::encode($en->{redacted}) if $out ne $en->{redacted} }
            if (defined $en->{markers}) { $pins++; my $k = () = $out =~ /\[redacted:/g; push @e, "entry $en->{id}: $k markers, want $en->{markers}" if $k != $en->{markers} }
            push @e, "entry $en->{id}: two markers touch" if $out =~ /\]\[redacted:|\][ \t]+\[redacted:/;
        }
        push @e, 'no BD-2 pins in the corpus' unless $pins;
        return @e;
    }
    if ($name eq 'runner_cleanup') {
        # BH-6: run this runner on a passing and on a failing tmp_base "repo" case (case-local
        # _pass and _fail, which discovery skips). After the passing run no store-h-* work dir
        # of it is left, neither under its TMPDIR nor under the repo's tmp/; the failing run
        # keeps both (then removed here).
        my $base = "$REPO/tmp";
        my $dirs = sub {
            my ($d) = @_;
            return map { "$d/$_" } grep { /\Astore-h-\d+-[0-9a-f]{6}\z/ && -d "$d/$_" } util::list_dir($d);
        };
        for my $t (['pass', 0], ['fail', 1]) {
            my $td = ($a->{tmp} // die "runner_cleanup: no tmp\n") . "/childtmp-$t->[0]";
            util::mkdir_p($td);
            my %before = map { ($_ => 1) } $dirs->($base);
            my $r = util::run(['/usr/bin/perl', "$HERE/run.pl", "$cdir/_$t->[0]"], timeout_ms => 180000,
                              env => { TMPDIR => $td });
            my @new_repo = grep { !$before{$_} } $dirs->($base);
            my @new_tmp = $dirs->($td);
            push @e, "$t->[0] run: exit $r->{exit}" if ($r->{exit} != 0 ? 1 : 0) != $t->[1];
            if ($t->[1]) {
                push @e, "failing run: no work dir kept under its TMPDIR" unless @new_tmp;
                push @e, "failing run: no work dir kept under the repo tmp/" unless @new_repo;
                remove_tree($_, $td, $base) for @new_tmp, @new_repo;
            } else {
                push @e, "passing run: left $_" for @new_tmp, @new_repo;
                remove_tree($_, $td, $base) for @new_tmp, @new_repo;
            }
        }
        return @e;
    }
    if ($name eq 'runner_hygiene') {
        # AT-RN-01..05 (small-rulings §5.3 R1-R5): child runs of this runner on the case-local
        # _rn<NN> folders (discovery skips them), each with its own TMPDIR and, for tmp_base
        # "repo" cases, its own --repo-tmp folder, so the real <repo>/tmp is not touched.
        my $which = $a->{which} // die "runner_hygiene: no which\n";
        my $root = ($a->{tmp} // die "runner_hygiene: no tmp\n") . "/rn$which";
        my $td = "$root/tmpdir";
        my $rt = "$root/repotmp";
        util::mkdir_p($td);
        my $work = sub { my ($d) = @_; return map { "$d/$_" } grep { /\Astore-h-\d+-[0-9a-f]{6}\z/ } util::list_dir($d) };
        my $child = sub {
            my (@extra) = @_;
            return util::run(['/usr/bin/perl', "$HERE/run.pl", '--repo-tmp', $rt, @extra], timeout_ms => 180000, env => { TMPDIR => $td });
        };
        if ($which eq '01') {
            my $r = $child->("$cdir/_rn01");
            push @e, "two passing cases: exit $r->{exit}: " . chars(substr($r->{out}, -600)) if $r->{exit} != 0;
            push @e, "passing run left $_" for $work->($td);
        } elsif ($which eq '02') {
            my $r = $child->("$cdir/_rn02");
            push @e, "pass+fail run: exit $r->{exit}, want 1" if $r->{exit} != 1;
            my @w = $work->($td);
            if (@w != 1) { push @e, scalar(@w) . " work dirs under TMPDIR, want 1" }
            else {
                my $got = join(',', util::list_dir($w[0]));
                push @e, "kept [$got], want [c2,stage]" unless $got eq 'c2,stage';
                my ($line) = $r->{out} =~ /^(# kept: [^\n]*)$/m;
                my $want = "# kept: $w[0]/c2 $w[0]/stage";
                push @e, 'kept line ' . ($line // 'missing') . ", want $want" unless defined $line && $line eq $want;
            }
            remove_tree($_, $td) for @w;
        } elsif ($which eq '03') {
            for my $keep (0, 1) {
                my $pid = fork();
                die "fork: $!\n" unless defined $pid;
                if ($pid == 0) {
                    $ENV{TMPDIR} = $td;
                    open(STDOUT, '>', "$root/child-$keep.out");
                    open(STDERR, '>&', \*STDOUT);
                    no warnings 'exec';
                    exec('/usr/bin/perl', "$HERE/run.pl", '--repo-tmp', $rt, ($keep ? ('--keep') : ()), "$cdir/_rn03");
                    POSIX::_exit(127);
                }
                my $t0 = util::clock_ms();
                my $seen;
                while (util::clock_ms() - $t0 < 60000) {
                    ($seen) = grep { -d "$_/c1" } $work->($rt);
                    last if $seen;
                    util::sleep_ms(50);
                }
                util::sleep_ms(300);
                kill 'TERM', $pid;
                my $st;
                my $t1 = util::clock_ms();
                while (waitpid($pid, POSIX::WNOHANG()) == 0) {
                    if (util::clock_ms() - $t1 > 30000) { kill 'KILL', $pid; waitpid($pid, 0); push @e, "keep=$keep: no exit 30 s after TERM"; last }
                    util::sleep_ms(20);
                }
                $st = $?;
                my $code = ($st & 127) ? 128 + ($st & 127) : ($st >> 8);
                push @e, "keep=$keep: the case dir never appeared" unless $seen;
                push @e, "keep=$keep: exit $code after TERM, want 130" if $code != 130;
                my @left = ($work->($td), $work->($rt));
                if ($keep) { push @e, 'keep=1: --keep left nothing' unless @left; remove_tree($_, $td, $rt) for @left }
                else { push @e, "TERM left $_" for @left }
            }
        } elsif ($which eq '04') {
            util::mkdir_p("$root/noplugin");
            my $r = $child->('--plugin', "$root/noplugin", "$cdir/_rn01");
            push @e, 'run without a launcher exited 0' if $r->{exit} == 0;
            push @e, "die before the first case left $_" for $work->($td);
        } elsif ($which eq '05') {
            my $r = $child->("$cdir/_rn05");
            push @e, "tmp_base repo run: exit $r->{exit}" if $r->{exit} != 0;
            push @e, "empty repo tmp folder kept ($rt)" if -e $rt;
            push @e, "passing run left $_" for $work->($td);
        } else {
            push @e, "runner_hygiene: unknown which $which";
        }
        return @e;
    }
    if ($name eq 'stamp_spec') {
        # RV-24: util::stamp against the spec's time_re once the spec carries the RV-24 grammar
        # (WP-text part 1 changes time_re and adds time_legacy_re); until then only the
        # built-in shape is checked and a TODO line says so.
        my $re = eval { spec::has('time_legacy_re') ? spec::get('time_re') : undef };
        print "# TODO stamp_spec: the spec has no RV-24 time_re yet (WP-text part 1)\n" unless defined $re;
        my $shape = '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}';
        for my $tz (@{ $a->{tz} || ['UTC'] }) {
            local $ENV{TZ} = $tz;
            POSIX::tzset();
            for my $e (@{ $a->{epochs} || [] }) {
                my $s = util::stamp($e);
                push @e, "$tz $e: '$s' is not YYYY-MM-DD HH:MM +hhmm" unless $s =~ /\A$shape\z/;
                push @e, "$tz $e: '$s' does not match the spec time_re" if defined $re && $s !~ /\A(?:$re)\z/;
                my $want = POSIX::strftime('%Y-%m-%d %H:%M %z', localtime $e);
                push @e, "$tz $e: '$s', want '$want'" unless $s eq $want;
            }
        }
        POSIX::tzset();
        return @e;
    }
    if ($name eq 'assembly_runtime_fill') {
        # fix-to-core §2: runtime.json values that spell the brand {{plugin}} are filled
        my $rt = assembly_runtime($a->{file});
        for my $k (sort keys %{ $a->{want} || {} }) {
            my $w = $a->{want}{$k};
            push @e, "runtime $k: " . ($rt->{$k} // 'missing') . ", want $w" unless ($rt->{$k} // '') eq $w;
        }
        return @e;
    }
    if ($name eq 'handoff_turn_api') {
        # D-18 B7/B8: the seams begin and publish call (lib/handoff_turn.pm): the open ht
        # begin binds (newest, no .published, at most 60 min old), one stage per ht
        # (resumed), one published handoff per ht.
        for my $l (qw(bucket handoff_turn)) { require "$l.pm" }
        local $ENV{STORE_TEST_MODE} = '1';
        local $ENV{STORE_TEST_NOW} = $a->{now};
        my $d = $a->{sid_dir};
        my $open = handoff_turn::open_for_begin($d);
        push @e, 'open ht ' . ($open ? $open->{ht} : 'none') . ', want ' . ($a->{want_open} // 'none')
            unless ($open ? $open->{ht} : '') eq ($a->{want_open} // '');
        if (my $ht = $a->{bind}) {
            my ($s1, $r1) = handoff_turn::bind_stage($d, $ht, $a->{stage});
            my ($s2, $r2) = handoff_turn::bind_stage($d, $ht, "$a->{stage}-other");
            push @e, "first bind: $s1 resumed=$r1" unless $s1 eq $a->{stage} && !$r1;
            push @e, "second bind: $s2 resumed=$r2" unless $s2 eq $a->{stage} && $r2;
            my ($p1, $q1) = handoff_turn::mark_published($d, $ht, $a->{path});
            my ($p2, $q2) = handoff_turn::mark_published($d, $ht, "$a->{path}.other");
            push @e, "first publish: $p1 $q1" unless $p1 && $q1 eq $a->{path};
            push @e, "second publish: $p2 $q2" unless !$p2 && $q2 eq $a->{path};
            my $after = handoff_turn::open_for_begin($d);
            push @e, 'published ht still open' if $after && $after->{ht} eq $ht;
        }
        return @e;
    }
    if ($name eq 'queue_mode') {
        # CORE-18, skills-to-core §5: queue::mode(sid, cmd) and mode_text(sid, cmd) read only
        # that session's record under {watch} (no queue call): {mode, why, text} as expected
        require "queue.pm";
        no warnings "once";
        local %rc::R = (watch => $a->{watch}, settings => { values => {} });
        my $m = queue::mode($a->{sid}, $a->{cmd});
        my $t = queue::mode_text($a->{sid}, $a->{cmd});
        push @e, "mode $m->{mode}, want $a->{mode}" if defined $a->{mode} && $m->{mode} ne $a->{mode};
        push @e, 'why ' . ($m->{why} // 'none') . ', want ' . ($a->{why} // 'none') if exists $a->{why} && ($m->{why} // '') ne ($a->{why} // '');
        push @e, "text '$t', want '$a->{text}'" if defined $a->{text} && $t ne $a->{text};
        return @e;
    }
    if ($name eq 'settings_prod') {
        # S-SETTINGS B (CORE-02): settings::prod over resolved values {values}: reads, the
        # class id each text matches (null = none), the user pattern count, the invalid entries.
        my $p = settings::prod({ values => $a->{values} || {} });
        push @e, "reads $p->{reads}, want $a->{reads}" if defined $a->{reads} && $p->{reads} ne $a->{reads};
        push @e, "user patterns $p->{user}, want $a->{user}" if defined $a->{user} && $p->{user} != $a->{user};
        for my $t (sort keys %{ $a->{matches} || {} }) {
            my ($got, $want) = (settings::prod_class($t, $p), $a->{matches}{$t});
            push @e, "'$t' matches " . ($got // 'none') . ', want ' . ($want // 'none') unless ($got // '') eq ($want // '');
        }
        if ($a->{invalid}) {
            my $got = join(',', map { $_->{key} . (defined $_->{index} ? ":$_->{index}" : '') } @{ $p->{invalid} });
            my $want = join(',', @{ $a->{invalid} });
            push @e, "invalid [$got], want [$want]" unless $got eq $want;
        }
        return @e;
    }
    if ($name eq 'settings_protected') {
        # Owner xxxxxxxx-29: settings::protected over resolved values {values}: the user entry
        # count, the id of the user's entry each branch name matches (null = none of the user's;
        # the shipped list is the callers' own check), the ignored entries as key:index.
        my $p = settings::protected({ values => $a->{values} || {} });
        push @e, "user entries $p->{user}, want $a->{user}" if defined $a->{user} && $p->{user} != $a->{user};
        for my $t (sort keys %{ $a->{matches} || {} }) {
            my ($got, $want) = (settings::protected_user($t, $p), $a->{matches}{$t});
            push @e, "'$t' matches " . ($got // 'none') . ', want ' . ($want // 'none') unless ($got // '') eq ($want // '');
        }
        if ($a->{invalid}) {
            my $got = join(',', map { "$_->{key}:$_->{index}" } @{ $p->{invalid} });
            my $want = join(',', @{ $a->{invalid} });
            push @e, "invalid [$got], want [$want]" unless $got eq $want;
        }
        return @e;
    }
    if ($name eq 'user_regex_bound') {
        # U-06 (REVIEW-NIGHT-2): the user's own patterns run with a wall-clock bound
        # (lib/userre.pm) and a stopped one takes its setting's safe side. One `check` per step;
        # it runs in a forked child this runner kills after `within_s` (default 20), so code
        # without the bound fails as "hung" instead of backtracking for minutes.
        return u06_within($a->{within_s} // 20, sub { u06_check($a->{check} // '', $a) });
    }
    if ($name eq 'settings_export') {
        # W-BETA D (CORE-02): settings::export_view; every key has an export class (AT-WB-08).
        my @none = grep { !defined $_->[3] || $_->[3] !~ /^(num|bool|enum|path|list|drop)$/ } do { no warnings "once"; @settings::KEYS };
        push @e, 'keys without an export class: ' . join(', ', map { $_->[0] } @none) if @none;
        local $ENV{HOME} = $a->{home} if defined $a->{home};
        # "noarg": export_view() with no argument (the watcher's report call, W2C-2). With
        # "values" the run context holds them; without, there is no run context (no rc::init)
        # and the view must still be the resolved settings, not empty values.
        my $view;
        if ($a->{noarg}) {
            local $ENV{CLAUDE_CONFIG_DIR};
            delete local @ENV{ grep { /^CLAUDE_PLUGIN_OPTION_/ } keys %ENV };
            local %rc::R = $a->{values} ? (settings => { values => $a->{values} }) : ();
            $view = settings::export_view();
        }
        else { $view = settings::export_view({ values => $a->{values} || {} }) }
        my %got = @$view;
        for my $k (sort keys %{ $a->{want} || {} }) {
            my ($g, $w) = ($got{$k}, $a->{want}{$k});
            $g = "$g" if jsonc::is_bool($g);
            push @e, "$k exports " . ($g // 'null') . ', want ' . ($w // 'null') unless ($g // "\0") eq ($w // "\0");
        }
        for my $k (@{ $a->{absent} || [] }) { push @e, "$k is exported" if exists $got{$k} }
        return @e;
    }
    if ($name eq 'jobs_output_path') {
        # DP-2 / DP-13 / DP-24 (a): the two output-path readers of lib/jobrec.pm and the
        # switch between them. The default source is the result text, used only when it
        # equals a layout candidate (job cwd, or session_cwd when given): want_check.
        require "jobrec.pm";
        my $in = { task_id => $a->{task}, cwd => $a->{cwd}, session_cwd => $a->{session_cwd}, result_text => $a->{text} };
        my $rt = jobrec::path_from_result_text($a->{text}, $a->{task});
        my $ly = jobrec::path_from_layout($a->{sid}, $a->{cwd}, $a->{task});
        my $ls = jobrec::path_from_layout($a->{sid}, $a->{session_cwd}, $a->{task});
        push @e, "default source $jobrec::OUTPUT_PATH_SOURCE, want result-text" unless $jobrec::OUTPUT_PATH_SOURCE eq 'result-text';
        my $agrees = defined $rt && grep { defined && $_ eq $rt } ($ly, $ls);
        push @e, 'result text: ' . ($rt // 'none') . ', want ' . ($a->{want_result_text} // 'none')
            unless ($rt // '') eq ($a->{want_result_text} // '');
        # the layout sits under the system temp root and the user's uid: the case gives the rest
        my $wl = defined $a->{want_layout_tail} ? ($^O eq 'darwin' ? '/private/tmp' : '/tmp') . "/claude-$<$a->{want_layout_tail}" : undef;
        push @e, 'layout: ' . ($ly // 'none') . ', want ' . ($wl // 'none') unless ($ly // '') eq ($wl // '');
        no warnings 'once';
        for my $src (qw(none result-text layout)) {
            local $jobrec::OUTPUT_PATH_SOURCE = $src;
            my ($p, $s, undef, $c) = jobrec::output_path($in, $a->{sid});
            my $want = $src eq 'layout' ? $ly : $src eq 'result-text' && $agrees ? $rt : undef;
            my $wsrc = defined $want ? $src : 'none';
            push @e, "switch $src: path " . ($p // 'null') . ' source ' . $s . ', want ' . ($want // 'null') . " $wsrc"
                unless ($p // '') eq ($want // '') && $s eq $wsrc;
            push @e, 'check ' . ($c // 'null') . ", want $a->{want_check}"
                if $src eq 'result-text' && defined $a->{want_check} && ($c // '') ne $a->{want_check};
        }
        return @e;
    }
    if ($name eq 'proc_stat_lines') {
        # R-4: identity::_proc_stat over real /proc/<pid>/stat lines recorded on Linux ({lines:
        # [{id, line, comm, ppid, starttime, vsize}]}): the comm whole (spaces, parentheses, a
        # newline, a tab, fake fields after a `)`), the ppid, and the start ticks of field 22,
        # never field 23 (vsize). Each line is served in place of /proc/<pid>/stat, so the
        # parser runs on any host.
        my $doc = eval { jsonc::decode(util::read_file(src_file($a->{file}, $cdir)) // '') };
        return ("$a->{file}: unreadable") unless ref $doc eq 'HASH' && ref $doc->{lines} eq 'ARRAY' && @{ $doc->{lines} };
        no warnings qw(redefine once);
        my $orig = \&util::read_file;
        for my $l (@{ $doc->{lines} }) {
            my ($pid) = ($l->{line} // '') =~ /\A(\d+) /;
            if (!defined $pid) { push @e, "$l->{id}: no pid in the line"; next }
            local *util::read_file = sub { return $_[0] eq "/proc/$pid/stat" ? $l->{line} : $orig->(@_) };
            my @got = identity::_proc_stat($pid);
            if (!@got) { push @e, "$l->{id}: the line does not parse"; next }
            push @e, "$l->{id}: comm " . jsonc::encode($got[0]) . ', want ' . jsonc::encode($l->{comm}) if $got[0] ne $l->{comm};
            push @e, "$l->{id}: ppid $got[1], want $l->{ppid}" if $got[1] != $l->{ppid};
            push @e, "$l->{id}: start ticks $got[2], want $l->{starttime} (field 22)"
                . ($got[2] == ($l->{vsize} // -1) ? ' - that is field 23, vsize' : '') if $got[2] != $l->{starttime};
        }
        return @e;
    }
    if ($name eq 'linux_start_time') {
        # R-4: the probe (a Perl file in the case folder) runs in a Linux container with the
        # plugin's helper/ mounted read-only and nothing else writable but a tmpfs /tmp, offline.
        # It checks identity::start_time against `ps -o lstart=` (where the image has ps) and
        # the fork time, and that it stays the same while the process allocates memory. Each
        # `FAIL: ` line it prints is an error; it must end with `DONE`.
        my $docker = util::which('docker') // return ('no docker on PATH');
        # "images": the first of them this machine holds (no pull); none: a note, not run
        if (ref $a->{images} eq 'ARRAY') {
            my ($img) = grep { docker_image($_) } @{ $a->{images} };
            if (!defined $img) { print '# not run: none of ' . join(', ', @{ $a->{images} }) . " is here (no pull)\n"; return () }
            $a = { %$a, image => $img };
            print "# $img\n";
        }
        my $probe = util::read_file(src_file($a->{probe} // 'probe.pl', $cdir)) // return ('no probe');
        my $helper = ($PLUGIN_SRC // "$REPO/plugin") . '/helper';
        my $cname = "store-h-r4-$$-" . util::rand_hex(4);
        my @run = ($docker, 'run', '--rm', '-i', '--init', '--pull', 'never', '--name', $cname, '--network', 'none',
                   '--read-only', '--tmpfs', '/tmp', '-e', 'LC_ALL=C', '-e', 'TZ=UTC', '-v', "$helper:/w/helper:ro",
                   $a->{image}, 'perl', '-', $a->{mb} // 32, $a->{steps} // 3);
        # docker's own errors (no such image, a path Docker cannot share) go to stdout too
        my $r = util::run(['/bin/sh', '-c', 'exec "$0" "$@" 2>&1', @run], stdin => $probe, timeout_ms => ($a->{timeout_s} // 120) * 1000);
        if ($r->{timed_out}) {
            util::run([$docker, 'rm', '-f', $cname], timeout_ms => 30000);
            push @e, "$a->{image}: timed out after " . ($a->{timeout_s} // 120) . ' s';
        }
        my $out = $r->{out} // '';
        print map { "#   $a->{image}| $_\n" } split /\n/, $out if $VERBOSE;
        push @e, map { "$a->{image}: $_" } $out =~ /^FAIL: (.*)$/mg;
        push @e, "$a->{image}: exit $r->{exit}" . ($out =~ /\S/ ? ': ' . chars(substr($out, -600)) : '') if $r->{exit} != 0 && !@e;
        push @e, "$a->{image}: no DONE line" if $r->{exit} == 0 && $out !~ /^DONE /m;
        return @e;
    }
    if ($name eq 'live_peers') {
        # AT-M5-10 reader: a live- record counts only when its pid runs with the same start time
        # and no ended- record exists.
        for my $l (qw(sessions)) { require "$l.pm" }
        no warnings 'once';
        local %rc::R = (paths => { root => $a->{root} });
        my @live = map { $_->{session_id} } @{ sessions::live_peers() };
        my $want = join(',', sort @{ $a->{expect} || [] });
        my $got = join(',', sort @live);
        push @e, "live peers [$got], want [$want]" unless $got eq $want;
        return @e;
    }
    if ($name eq 'no_age_rule') {
        # AT-ST-06 (RRP-05 "no age limit"): no file-time test in the staged files named (file
        # tests -M -A -C, a stat() field 8-10, File::stat's ->mtime, the word mtime)
        for my $f (@{ $a->{files} || [] }) {
            my $p = "$STAGE/helper/$f";
            my $src = util::read_file($p) // do { push @e, "$f: unreadable"; next };
            my $k = 0;
            for my $l (split /\n/, $src) {
                $k++;
                next if $l =~ /^\s*#/;
                push @e, "$f:$k: file-time test: $l"
                    if $l =~ /(?:^|[\s(!])-[MAC]\s+[\$"'_]|\bstat\s*\(.*\)\s*\)?\s*\[\s*(?:8|9|10)\s*\]|\$s\[\s*(?:8|9|10)\s*\]|->\s*mtime\b|\bmtime\b/;
            }
        }
        return @e;
    }
    if ($name eq 'repo_check') {
        # CR-F1: roots::repo_check(top, root) for each root of `cases` -> 'ok' or the reason
        my $c = $a->{cases} || {};
        for my $root (sort keys %$c) {
            my $r = roots::repo_check($a->{top}, $root);
            my $got = $r->{ok} ? 'ok' : $r->{reason};
            push @e, "repo_check $root: $got, want $c->{$root}" unless $got eq $c->{$root};
        }
        return @e;
    }
    if ($name eq 'exports_bound') {
        # CR-F6: repomode::exports reads no folder entry past $EXPORTS_MAX in all. The tree
        # `dir` holds `topics` topic folders of `files` exports each.
        require "repomode.pm";
        my $d = $a->{dir};
        for my $t (1 .. $a->{topics}) {
            util::mkdir_p("$d/t$t");
            util::write_atomic("$d/t$t/e$_.md", "x\n") for 1 .. $a->{files};
        }
        my $all = repomode::exports($d);
        my $want_all = $a->{topics} * $a->{files};
        push @e, "exports without the bound: $all, want $want_all" unless $all == $want_all;
        no warnings qw(once redefine);
        my $orig = \&util::list_dir_max;
        my ($reads, $entries) = (0, 0);
        local *util::list_dir_max = sub { $reads++; my @x = $orig->(@_); $entries += @x; return @x };
        local $repomode::EXPORTS_MAX = $a->{max};
        my $n = repomode::exports($d);
        push @e, "entries read $entries, want at most $a->{max}" if $entries > $a->{max};
        push @e, "folders read $reads, want at most $a->{max_reads}" if $reads > $a->{max_reads};
        push @e, "exports under the bound: $n, want fewer than $want_all" unless $n < $want_all;
        return @e;
    }
    if ($name eq 'jsonc_bytes') {
        # CR-F2: encode_bytes gives every string once as UTF-8, whether it came in as
        # characters or as bytes; log::append writes the same bytes.
        my $mid = "\xc2\xb7";                                  # `·` as a byte literal (no `use utf8`)
        my $chars = "\x{414}ok";                               # a character string
        my $path = "/Users/r/\x{414}ok/h";
        utf8::encode($path);                                   # a path as bytes
        my $latin = "caf\xe9";                                 # bytes that are not UTF-8
        my $obj = jsonc::obj(m => "a ${mid} b", c => $chars, p => $path, l => $latin, n => 42, u => "\x{2028}", "k\x{414}" => 1);
        my $out = jsonc::encode_bytes($obj);
        push @e, 'encode_bytes returned a character string' if utf8::is_utf8($out);
        my $back = eval { jsonc::decode($out) };
        if (ref $back ne 'HASH') { return (@e, "encode_bytes output does not decode: $@") }
        my $want_mid = "a \x{b7} b";
        my $want_path = "/Users/r/\x{414}ok/h";
        my %want = (m => $want_mid, c => "\x{414}ok", p => $want_path, l => "caf\x{e9}", u => "\x{2028}");
        for my $k (sort keys %want) {
            my $g = $back->{$k} // '';
            utf8::decode($g) unless utf8::is_utf8($g);
            push @e, "$k: " . join(' ', map { sprintf 'U+%04X', ord } split //, $g) . ' after the round trip' unless $g eq $want{$k};
        }
        push @e, 'number came back as ' . ($back->{n} // 'null') unless ($back->{n} // '') eq '42';
        push @e, 'non-ASCII key lost' unless exists $back->{"k\x{414}"};
        push @e, 'U+2028 not escaped' unless index($out, '\\u2028') >= 0;
        # a mixed row written by log::append comes back the same
        my $f = "$a->{dir}/rows.jsonl";
        util::mkdir_p($a->{dir});
        log::append($f, $obj);
        my $line = util::read_file($f) // '';
        $line =~ s/\n\z//;
        push @e, 'log::append wrote other bytes than encode_bytes' unless $line eq $out;
        return @e;
    }
    if ($name eq 'redact_bound') {
        # redact_bound {unit_parts, bytes, expected, max_s}: the joined unit (UTF-8 bytes, as a
        # file reads) repeated to at least `bytes` goes through secrets::redact (all rules) within
        # max_s seconds of this process's CPU time (user + system; wall time fails on a loaded
        # machine), and the output equals the `expected` file (the redacted unit) repeated.
        my $unit = join('', @{ $a->{unit_parts} || [] });
        utf8::upgrade($unit);
        utf8::encode($unit);
        return ('empty unit') if $unit eq '';
        my $reps = int(($a->{bytes} + length($unit) - 1) / length $unit);
        my $text = $unit x $reps;
        my $want = util::read_file(src_file($a->{expected}, $cdir));
        return ("no expected file $a->{expected}") unless defined $want;
        $want x= $reps;
        my ($u0, $s0) = times;
        my ($got, $hits) = secrets::redact($text);
        my ($u1, $s1) = times;
        my $dt = ($u1 - $u0) + ($s1 - $s0);
        my $n = 0;
        $n += $_->{count} for @{ $hits || [] };
        push @e, sprintf('redact used %.2f s of CPU on %d bytes (%d hits), want under %s s', $dt, length $text, $n, $a->{max_s}) if $dt >= $a->{max_s};
        push @e, 'redacted output is a character string' if utf8::is_utf8($got);
        if ($got ne $want) {
            my $i = 0;
            $i++ while $i < length($got) && $i < length($want) && substr($got, $i, 1) eq substr($want, $i, 1);
            push @e, sprintf('redacted output differs from %s x %d at byte %d (got %d bytes, want %d)', $a->{expected}, $reps, $i, length $got, length $want);
        }
        print "#   redact: ${\ length $text} bytes, $n hits, " . sprintf('%.2f s', $dt) . "\n" if $VERBOSE;
        return @e;
    }
    return ("unknown builtin $name");
}

# The runtime values tools/assemble uses for goldens: tests/fixtures/assembly/runtime.json
# when present, else its worst-case defaults (path length 141).
sub assembly_runtime {
    my ($file) = @_;
    my $prefix = '~/.claude/handoffs/example-repo/LAB-123/';
    my $prev = $prefix . ('p' x (141 - length $prefix));
    my %rt = (nonce => 'a1b2c3d4', previous_copy => $prev, measured_at => '2026-10-21T04:40:00+03:00',
              session_id => '00000000-0000-4000-8000-000000000000', saved_copy => $prev, tokens => '612,345',
              queue_add => "$BRAND-store queue-add --sid 00000000-0000-4000-8000-000000000000 --nonce a1b2c3d4", measured_facts => '', remeasure => '',
              # D-18 tokens, the worst case tools/assemble uses (DP-19: max_calls = 1 + call_cap + recipe_cap)
              halt_reason => 'compactions keep repeating without progress', max_calls => '34', handoff_path => $prev,
              draft_state => 'present',
              handoff_finish => "`$BRAND-store publish --stage '$prev/.staging/xxxxxxxx-a1b2c3d4' --slug example-topic-slug --status in-progress`");
    my $rf = $file // "$FIXTURES_DIR/assembly/runtime.json";
    # runtime.json may spell the brand {{plugin}} (the BT-02 rename drill regenerates goldens first)
    if (-f $rf) { my $j = jsonc::decode(util::read_file($rf)); %rt = (%rt, map { my $v = $j->{$_}; $v =~ s/\{\{plugin\}\}/$BRAND/g if defined $v && !ref $v; ($_ => $v) } keys %$j) if ref $j eq 'HASH' }
    return \%rt;
}

# ---------------------------------------------------------------- assertions
# stdout_golden {files: [golden...], nonce?: "<the goldens' nonce>"}: stdout must equal
# (nonce defaults to tests/fixtures/assembly/runtime.json's, the one tools/assemble used)
# the goldens joined, with the goldens' nonce replaced by the first n=<8 hex> in
# stdout (the helper draws its own). Exact bytes, so no banner, prefix or trailer
# can pass (BUILD-PLAN §3.3 "exactly as tools/assemble composes it").
sub golden_diff {
    my ($g, $got) = @_;
    my ($n) = $got =~ /\bn=([0-9a-f]{8})\b/;
    return ('stdout_golden: no nonce in stdout') unless defined $n;
    my $want = '';
    for my $f (@{ $g->{files} || [] }) {
        my $t = util::read_file($f);
        return ("stdout_golden: no golden $f") unless defined $t;
        utf8::decode($t);
        $want .= $t;
    }
    return ('stdout_golden: no files') if $want eq '';
    # The goldens' nonce is the one tools/assemble used: runtime.json, unless the case names one.
    my $gn = defined $g->{nonce} && $g->{nonce} ne '' ? $g->{nonce} : assembly_runtime()->{nonce};
    $want =~ s/\Q$gn\E/$n/g if defined $gn && $gn ne '';
    return () if $got eq $want;
    my $i = 0;
    $i++ while $i < length($got) && $i < length($want) && substr($got, $i, 1) eq substr($want, $i, 1);
    return ("stdout differs from the goldens at char $i: got " . jsonc::encode(substr($got, $i, 60))
            . ' want ' . jsonc::encode(substr($want, $i, 60)));
}

sub expand_glob {
    my ($pat) = @_;
    return ($pat) unless $pat =~ /[*?\[]/;
    return sort glob($pat =~ /\s/ ? qq("$pat") : $pat);
}

sub read_rows {
    my ($file) = @_;
    my @rows;
    for my $f (expand_glob($file)) {
        open(my $fh, '<:raw', $f) or next;
        while (my $l = <$fh>) { my $j = eval { jsonc::decode($l) }; push @rows, $j if ref $j eq 'HASH' }
        close $fh;
    }
    return @rows;
}

sub subset {
    my ($want, $got, $path) = @_;
    $path //= '';
    if (ref $want eq 'HASH') {
        return "$path: not an object" unless ref $got eq 'HASH';
        for my $k (sort keys %$want) {
            if (!exists $got->{$k}) { return "$path.$k: missing" unless !defined $want->{$k} && 0; return "$path.$k: missing" }
            my $e = subset($want->{$k}, $got->{$k}, "$path.$k");
            return $e if $e;
        }
        return undef;
    }
    if (ref $want eq 'ARRAY') {
        return "$path: not an array" unless ref $got eq 'ARRAY';
        return "$path: length " . scalar(@$got) . ' != ' . scalar(@$want) unless @$got == @$want;
        for my $i (0 .. $#$want) { my $e = subset($want->[$i], $got->[$i], "$path\[$i\]"); return $e if $e }
        return undef;
    }
    if (!defined $want) { return defined $got ? "$path: expected null, got " . (ref $got ? jsonc::encode($got) : $got) : undef }
    if (jsonc::is_bool($want)) { return (jsonc::is_bool($got) && (!!$want == !!$got)) ? undef : "$path: expected $want" }
    return "$path: expected '$want', got " . (defined $got ? (ref $got ? jsonc::encode($got) : "'$got'") : 'nothing')
        unless defined $got && !ref $got && "$got" eq "$want";
    return undef;
}

sub check {
    my ($x, $res, $V, $st) = @_;
    $x = subst_deep($x, $V);
    my @e;
    for my $r (@$res) {
        my $out = $r->{out};
        my $outc = $out;
        utf8::decode($outc);
        push @e, "timed out" if $r->{timed_out};
        push @e, "exit $r->{exit}, want $x->{exit}" . ($r->{err} ? " (stderr: " . chars(substr($r->{err}, 0, 300)) . ")" : '')
            if defined $x->{exit} && $r->{exit} != $x->{exit};
        push @e, "stdout differs: got " . jsonc::encode(substr($outc, 0, 400)) if defined $x->{stdout} && $outc ne $x->{stdout};
        push @e, "stdout does not match /$x->{stdout_re}/: " . jsonc::encode(substr($outc, 0, 300)) if defined $x->{stdout_re} && $outc !~ /$x->{stdout_re}/m;
        for my $c (@{ $x->{stdout_contains} || [] }) { push @e, "stdout lacks " . jsonc::encode($c) if index($outc, $c) < 0 }
        for my $c (@{ $x->{stdout_absent} || [] }) { push @e, "stdout has " . jsonc::encode($c) if index($outc, $c) >= 0 }
        for my $re (@{ $x->{stdout_has} || [] }) { push @e, "stdout lacks /$re/: " . jsonc::encode(substr($outc, 0, 1500)) unless $outc =~ /$re/m }
        for my $re (@{ $x->{stdout_lacks} || [] }) { push @e, "stdout has /$re/" if $outc =~ /$re/m }
        if ($x->{json_keys} || $x->{json}) {
            my $d = eval { jsonc::decode($out) };
            if (ref $d ne 'HASH') { push @e, "stdout is not a JSON object: " . jsonc::encode(substr($outc, 0, 300)) }
            else {
                if ($x->{json_keys}) {
                    my ($got, $want) = (join(',', sort keys %$d), join(',', sort @{ $x->{json_keys} }));
                    push @e, "json keys [$got], want [$want]" if $got ne $want;
                }
                for my $p (sort keys %{ $x->{json} || {} }) {
                    my ($ok, $v) = jpath($d, $p);
                    my $w = $x->{json}{$p};
                    if (ref $w eq 'HASH') {
                        push @e, "json $p !~ /$w->{re}/: " . scalar_text($v) if exists $w->{re} && !($ok && defined $v && !ref $v && $v =~ /$w->{re}/);
                        push @e, "json $p not null" if exists $w->{null} && $ok && defined $v;
                        push @e, "json $p length, want $w->{len}" if exists $w->{len} && !(ref $v eq 'ARRAY' && @$v == $w->{len});
                        push @e, "json $p missing" if exists $w->{present} && !$ok;
                        if (exists $w->{max_bytes}) {
                            my $b = defined $v && !ref $v ? $v : '';
                            utf8::encode($b) if utf8::is_utf8($b);
                            push @e, "json $p is " . length($b) . " bytes > $w->{max_bytes}" if !$ok || !defined $v || length($b) > $w->{max_bytes};
                        }
                    } elsif (scalar_text($v) ne scalar_text($w)) {
                        push @e, "json $p = " . scalar_text($v) . ", want " . scalar_text($w);
                    }
                }
            }
        }
        push @e, "stdout is " . length($out) . " bytes > $x->{stdout_max_bytes}" if defined $x->{stdout_max_bytes} && length($out) > $x->{stdout_max_bytes};
        push @e, golden_diff($x->{stdout_golden}, $outc) if $x->{stdout_golden};
        push @e, "stderr not empty: " . chars(substr($r->{err}, 0, 200)) if $x->{stderr_empty} && length $r->{err};
        if (defined $x->{stdout_lines}) { my $n = () = $out =~ /\n/g; push @e, "stdout has $n lines, want $x->{stdout_lines}" if $n != $x->{stdout_lines} }
        if ($x->{stdout_json}) {
            my $j = eval { jsonc::decode($out) };
            if (!$j) { push @e, "stdout is not JSON: " . substr($outc, 0, 200) }
            else { my $m = subset($x->{stdout_json}, $j, 'stdout'); push @e, $m if $m }
        }
        if (defined $x->{context_max_chars} || $x->{context_contains} || $x->{context_absent}) {
            my $j = eval { jsonc::decode($out) };
            my $ctx = ref $j eq 'HASH' && ref $j->{hookSpecificOutput} eq 'HASH' ? $j->{hookSpecificOutput}{additionalContext} : undef;
            if (!defined $ctx) { push @e, 'no hookSpecificOutput.additionalContext' }
            else {
                push @e, 'additionalContext is ' . length($ctx) . " chars > $x->{context_max_chars}" if defined $x->{context_max_chars} && length($ctx) > $x->{context_max_chars};
                for my $c (@{ $x->{context_contains} || [] }) { push @e, "additionalContext lacks " . jsonc::encode($c) if index($ctx, $c) < 0 }
                for my $c (@{ $x->{context_absent} || [] }) { push @e, "additionalContext has " . jsonc::encode($c) if index($ctx, $c) >= 0 }
            }
        }
        for my $t (@{ $x->{trace_absent} || [] }) { push @e, "trace has $t" if $r->{trace} =~ /^\Q$t\E$/m }
        for my $t (@{ $x->{trace_has} || [] }) { push @e, "trace lacks $t" unless $r->{trace} =~ /^\Q$t\E$/m }
        push @e, "took $r->{ms} ms > $x->{ms_max}" if defined $x->{ms_max} && $r->{ms} > $x->{ms_max};
        last if @e;
    }
    if (my $pc = $x->{parallel_stdout_count}) {
        for my $k (sort keys %$pc) {
            my $n = grep { $_->{out} eq $k } @$res;
            push @e, "parallel stdout " . jsonc::encode($k) . " seen $n times, want $pc->{$k}" if $n != $pc->{$k};
        }
    }
    for my $f (@{ $x->{files} || [] }) {
        my @m = expand_glob($f->{path});
        @m = grep { -e $_ } @m;
        if (defined $f->{count}) { push @e, "$f->{path}: " . scalar(@m) . " files, want $f->{count}" if @m != $f->{count}; next if !$f->{count} }
        if (exists $f->{exists} && !$f->{exists}) { push @e, "$f->{path}: exists" if @m; next }
        if (!@m) { push @e, "$f->{path}: missing"; next }
        for my $p (@m) {
            # snapshot <label> keeps the file's bytes for a later step's same_bytes_as <label>
            if (defined $f->{snapshot}) { $V->{"__snapshot_$f->{snapshot}"} = util::read_file($p) }
            if (defined $f->{same_bytes_as}) {
                my $was = $V->{"__snapshot_$f->{same_bytes_as}"};
                push @e, "$p: no snapshot $f->{same_bytes_as}" unless defined $was;
                push @e, "$p: bytes differ from snapshot $f->{same_bytes_as}" if defined $was && (util::read_file($p) // '') ne $was;
            }
            if (defined $f->{mode}) { my $mode = sprintf('%04o', (stat $p)[2] & 07777); push @e, "$p: mode $mode, want $f->{mode}" if $mode ne $f->{mode} }
            next if -d $p;
            my $raw = util::read_file($p) // '';
            my $txt = $raw; utf8::decode($txt);
            for my $c (@{ $f->{contains} || [] }) { push @e, "$p lacks " . jsonc::encode($c) if index($txt, $c) < 0 }
            for my $c (@{ $f->{absent_text} || [] }) { push @e, "$p has " . jsonc::encode($c) if index($txt, $c) >= 0 }
            for my $re (@{ $f->{has} || [] }) { push @e, "$p lacks /$re/" unless $txt =~ /$re/m }
            for my $re (@{ $f->{lacks} || [] }) { push @e, "$p has /$re/" if $txt =~ /$re/m }
            if (defined $f->{lines}) { my $n = () = $raw =~ /\n/g; push @e, "$p: $n lines, want $f->{lines}" if $n != $f->{lines} }
            if (defined $f->{max_lines}) { my $n = () = $raw =~ /\n/g; push @e, "$p: $n lines > $f->{max_lines}" if $n > $f->{max_lines} }
            if ($f->{json_lines}) { my $k = 0; for my $l (split /\n/, $raw) { $k++; push @e, "$p line $k is not JSON" unless eval { jsonc::decode($l); 1 } } }
            if ($f->{json}) { my $j = eval { jsonc::decode($raw) }; my $m = $j ? subset($f->{json}, $j, util::basename($p)) : "$p: not JSON"; push @e, $m if $m }
            if ($f->{keys_absent}) { my $j = eval { jsonc::decode($raw) } || {}; for my $k (@{ $f->{keys_absent} }) { push @e, "$p: key $k present" if exists $j->{$k} } }
            if ($f->{keys}) { my $j = eval { jsonc::decode($raw) } || {}; for my $k (@{ $f->{keys} }) { push @e, "$p: key $k missing" unless exists $j->{$k} } }
            if ($f->{frontmatter}) {
                my ($fm) = $txt =~ /\A---\n(.*?)\n---\n/s;
                if (!defined $fm) { push @e, "$p: no frontmatter" }
                else {
                    my %h = map { /^([A-Za-z0-9_]+): (.*)$/ ? ($1 => $2) : () } split /\n/, $fm;
                    for my $k (sort keys %{ $f->{frontmatter} }) {
                        my $w = $f->{frontmatter}{$k};
                        if (!defined $w) { push @e, "$p: frontmatter $k present" if exists $h{$k}; next }
                        my $g = $h{$k};
                        $g =~ s/^"(.*)"$/$1/ if defined $g;
                        push @e, "$p: frontmatter $k = " . ($g // 'missing') . ", want $w" unless defined $g && ($w eq '*' || $g eq $w || ($w =~ m{^/(.*)/$} && $g =~ /$1/));
                    }
                }
            }
        }
    }
    for my $a (@{ $x->{absent} || [] }) {
        if ($a =~ /^(.*):count>(\d+)$/) { my @m = grep { -e } expand_glob($1); push @e, "$1: " . scalar(@m) . " files > $2" if @m > $2 }
        else { my @m = grep { -e } expand_glob($a); push @e, "$a exists" if @m }
    }
    for my $rw (@{ $x->{rows} || [] }) {
        my @rows = grep { ($_->{ev} // '') eq $rw->{ev} } read_rows($rw->{file});
        @rows = grep { !subset($rw->{fields}, $_) } @rows if $rw->{fields};
        # fields_ge {field: min}: every matched row has a number >= min there
        for my $k (sort keys %{ $rw->{fields_ge} || {} }) {
            for my $r (@rows) { push @e, "rows $rw->{ev}: $k = " . ($r->{$k} // 'null') . " < $rw->{fields_ge}{$k}" unless defined $r->{$k} && !ref $r->{$k} && $r->{$k} =~ /^-?\d+(?:\.\d+)?$/ && $r->{$k} >= $rw->{fields_ge}{$k} }
        }
        if (defined $rw->{count}) { push @e, "rows $rw->{ev} in $rw->{file}: " . scalar(@rows) . ", want $rw->{count}" if @rows != $rw->{count} }
        elsif (!@rows) { push @e, "no $rw->{ev} row" . ($rw->{fields} ? ' with ' . jsonc::encode($rw->{fields}) : '') . " in $rw->{file}" }
    }
    # joined [{nonce, field: value}]: the rollup row as the staged rollup::rows returns it after
    # the nonce join with compaction_boundary (PKG-RUNTIME E.2)
    if ($x->{joined}) {
        _libs();
        require "rollup.pm";
        my $rows = rollup::rows("$V->{WATCH}/$V->{SID}");
        for my $j (@{ $x->{joined} }) {
            my @m = grep { ($_->{nonce} // '') eq ($j->{nonce} // '') } @$rows;
            if (@m != 1) { push @e, "joined: " . scalar(@m) . " rollup rows for nonce " . ($j->{nonce} // '-') . ", want 1"; next }
            my $msg = subset($j, $m[0], "joined");
            push @e, $msg if $msg;
        }
    }
    for my $rw (@{ $x->{rows_absent} || [] }) {
        my @rows = grep { ($_->{ev} // '') eq $rw->{ev} } read_rows($rw->{file});
        push @e, "unexpected $rw->{ev} row in $rw->{file}" if @rows;
    }
    for my $g (@{ $x->{grep_absent} || [] }) {
        my $text = exists $g->{parts} ? join('', @{ $g->{parts} }) : $g->{text};
        my @stack = ($g->{dir});
        while (@stack) {
            my $d = pop @stack;
            next unless -e $d;
            if (-d $d) { push @stack, map { "$d/$_" } util::list_dir($d); next }
            next if defined $g->{exclude} && $d =~ /$g->{exclude}/;
            my $raw = util::read_file($d) // '';
            push @e, "$d contains the canary text" if index($raw, $text) >= 0;
        }
    }
    for my $c (@{ $x->{all_rows_content_free} || [] }) {
        for my $r (read_rows($c->{file})) { push @e, "row $r->{ev} carries a forbidden key" if grep { exists $r->{$_} } @{ $c->{keys} } }
    }
    return @e;
}
