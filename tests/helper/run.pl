#!/usr/bin/perl
# tests/helper/run.pl: the H-test case runner (BUILD-PLAN §3.5). Owner: WP-core.
# Runs `bin/<name>-store` (a staged copy of plugin/) for every tests/helper/cases/**/case.json
# given on the command line (files or folders), each case in a fresh temporary HOME
# with STORE_TEST_MODE=1, and asserts exit codes, stdout, files, log rows and traces.
#
# Usage: tests/helper/run.pl [--filter RE] [--keep] [-v] <case dir|case.json|cases root>...
#
# Case file (JSON): {"id", "sid"?, "tz"?, "env"?, "path_prepend"?, "needs"?: ["baseline","spec"],
#   "steps": [step...]}  or the one-step form of §3.5 (argv, stdin, setup, expect, then).
# Step: {"argv", "stdin" (file in the case dir or tests/fixtures/), "stdin_json", "stdin_text",
#   "env", "now", "setup": [...], "parallel": N, "kill_after_ms": N, "expect": {...}}
# Setup actions: write (text|json|parts|bytes|lines; mode; mtime_ago_s), copy, mkdir,
#   repo (git recipe), dispatch (record fields + age_s), transcript (rows; boundary/prompt
#   shortcuts), stub (executable script), run (a helper call without assertions).
# Placeholders in every string: $TMP $HOME $ROOT $WATCH $SID $SID8 $PLUGIN $FIX $CASE
#   $BRAND $HOST $CLAUDE_BIN $DISP $TODAY $LSTART1 (pid 1's start time), plus every
#   variable a step captured.
# Additions used by the WP-skills cases (one runner for every layer, BUILD-PLAN §3.5):
#   case "tmp_base": "repo"  the case's temp dir sits under the repo's git-ignored tmp/,
#                            not the system temp folder (the publish lint treats paths
#                            under /tmp, /private/tmp and /var/folders as ephemeral)
#   step "cwd"               the helper's working directory (default: the case's $TMP)
#   step "capture"           {VAR: "json:<dotted path>" | "re:<regex, one group>"} from stdout
#   a step without argv, lib or setup that holds a setup action runs as a setup step
#   setup: write with content | content_parts (mode 0600 unless given); repo {recipe} + at;
#     git [argv] (+ cwd, env, var = stdout); bigfile + bytes (+ fill); age + minutes;
#     run (+ capture, exit)
#   expect: stdout_has / stdout_lacks (regexes, /m); json_keys; json {dotted path: value |
#     {re} | {null} | {len} | {present}}; files has / lacks (regexes, /m)
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

my ($FILTER, $KEEP, $VERBOSE, @ARGS);
while (@ARGV) {
    my $a = shift @ARGV;
    if ($a eq '--filter') { $FILTER = shift @ARGV; next }
    if ($a eq '--keep') { $KEEP = 1; next }
    if ($a eq '-v') { $VERBOSE = 1; next }
    push @ARGS, $a;
}
@ARGS = ("$HERE/cases") unless @ARGS;

my $BRAND = do { my $b = jsonc::decode(util::read_file("$REPO/brand.json")); $b->{name} };
my $HOSTNAME = (POSIX::uname())[1];
my $CLAUDE_BIN = find_claude_bin();
my $DEFAULT_SID = '11111111-2222-4333-8444-555555555555';
my $DEFAULT_PID = '424242:Tue Oct 21 09:00:00 2026';

sub find_claude_bin {
    my $vdir = util::home() . '/.local/share/claude/versions';
    my @v = sort { my @x = split /\./, $a; my @y = split /\./, $b; $x[0] <=> $y[0] || $x[1] <=> $y[1] || $x[2] <=> $y[2] }
            grep { /^\d+\.\d+\.\d+$/ } util::list_dir($vdir);
    return @v ? "$vdir/$v[-1]" : '';
}

# ---------------------------------------------------------------- staging
my $RUN_TMP = do {
    my $base = $ENV{TMPDIR} && -d $ENV{TMPDIR} ? $ENV{TMPDIR} : '/tmp';
    $base =~ s{/+$}{};
    my $d = "$base/store-h-" . $$ . '-' . util::rand_hex(6);
    util::mkdir_p($d);
    $d;
};
my %STAGE_INFO;
my $STAGE = stage_plugin("$RUN_TMP/stage/plugin");
my $REPO_TMP;
sub repo_tmp {
    return $REPO_TMP if $REPO_TMP;
    $REPO_TMP = "$REPO/tmp/store-h-" . $$ . '-' . util::rand_hex(6);
    util::mkdir_p($REPO_TMP);
    return $REPO_TMP;
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
    copy_tree("$REPO/plugin", $dst);
    my $launcher = "$dst/bin/$BRAND-store";
    die "run.pl: no launcher at plugin/bin/$BRAND-store (run tools/build)\n" unless -x $launcher;
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
                      || ($_ eq 'docker' && !util::which('docker')) || ($_ eq 'darwin' && $^O ne 'darwin') || ($_ eq 'corpus' && !-f "$REPO/tests/fixtures/summaries/expected.tsv") } @{ $case->{needs} || [] };
    if ($miss) { $SKIPPED++; print "ok $N - $id # SKIP needs " . join(',', @{ $case->{needs} }) . "\n"; next }
    my @errs = eval { run_case($case, File::Basename::dirname($cf)) };
    push @errs, "runner error: $@" if $@;
    if (@errs) {
        $FAILED++;
        push @FAIL_IDS, $id;
        print "not ok $N - $id\n";
        print map { "#   $_\n" } @errs;
    } else {
        print "ok $N - $id\n";
    }
}
print "1..$N\n";
print "# passed " . ($N - $FAILED - $SKIPPED) . ", failed $FAILED, skipped $SKIPPED\n";
print "# failed: @FAIL_IDS\n" if @FAIL_IDS;
print "# work dir: $RUN_TMP (left in place; the OS temp cleaner removes it)\n" if $KEEP || $VERBOSE;
exit($FAILED ? 1 : 0);

# ---------------------------------------------------------------- one case
sub run_case {
    my ($case, $cdir) = @_;
    my $tmp = (($case->{tmp_base} // '') eq 'repo' ? repo_tmp() : $RUN_TMP) . "/c$N";
    util::mkdir_p("$tmp/home");
    util::mkdir_p("$tmp/tmpdir");
    my %V;
    $V{TMP} = Cwd::abs_path($tmp);
    $V{HOME} = "$V{TMP}/home";
    $V{SID} = $case->{sid} // $DEFAULT_SID;
    $V{SID8} = substr($V{SID}, 0, 8);
    $V{PLUGIN} = $STAGE;
    $V{FIX} = "$REPO/tests/fixtures";
    $V{CASE} = $cdir;
    $V{BRAND} = $BRAND;
    $V{HOST} = $HOSTNAME;
    $V{CLAUDE_BIN} = $CLAUDE_BIN;
    $V{LSTART1} = $LSTART1;
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
        for my $s (@{ $st->{setup} || [] }) {
            my $e = eval { setup($s, \%V, $case, $st, $cdir); 1 };
            if (!$e) { push @errs, "$label setup: $@"; return @errs }
        }
        if ($st->{lib}) {
            my @le = eval { builtin($st->{lib}, subst_deep($st->{args} || {}, \%V), $cdir) };
            push @le, "builtin error: $@" if $@;
            push @errs, map { "$label: $_" } @le;
            next;
        }
        if (!$st->{argv} && !$st->{setup} && is_setup_action($st)) {
            my $e = eval { setup($st, \%V, $case, $st, $cdir); 1 };
            if (!$e) { push @errs, "$label setup: $@"; return @errs }
            next;
        }
        next unless $st->{argv};
        my $res = invoke($st, $case, \%V, $cdir, $i);
        push @errs, map { "$label: $_" } check($st->{expect} || {}, $res, \%V, $st);
        capture($st->{capture}, $res->[0]{out}, \%V) if $st->{capture} && @$res;
        if ($VERBOSE) {
            for my $r (@$res) { print "#   [$label] exit $r->{exit}\n"; print map { "#   | $_\n" } split /\n/, substr($r->{out}, 0, 4000) }
        }
    }
    return @errs;
}

sub subst {
    my ($s, $V) = @_;
    return $s unless defined $s && !ref $s;
    $s =~ s{\$\{(TMP|HOME|ROOT|WATCH|SID8|SID|PLUGIN|FIX|CASE|BRAND|HOST|CLAUDE_BIN|DISP|TODAY)\}}{$V->{$1} // ''}ge;
    $s =~ s/\$(TMP|HOME|ROOT|WATCH|SID8|SID|PLUGIN|FIX|CASE|BRAND|HOST|CLAUDE_BIN|DISP|TODAY)\b/$V->{$1} \/\/ ''/ge;
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
    return "$cdir/$name" if -e "$cdir/$name";
    return "$REPO/tests/fixtures/$name" if -e "$REPO/tests/fixtures/$name";
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
    return scalar grep { exists $s->{$_} } qw(write copy mkdir stub repo dispatch transcript run git bigfile age);
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
        if ($s->{jsonl}) { $text = join('', map { jsonc::encode($_) . "\n" } @{ $s->{jsonl} }) }
        write_text($p, $text, $s->{mode});
        if (defined $s->{mtime_ago_s}) { my $t = time - $s->{mtime_ago_s}; utime($t, $t, $p) }
        return;
    }
    if (exists $s->{copy}) { my $src = src_file($s->{copy}, $cdir); util::mkdir_p(util::dirname($s->{to})); util::copy_file($src, $s->{to}, mode => 0600); return }
    if (exists $s->{mkdir}) { util::mkdir_p($s->{mkdir}); chmod(oct($s->{mode}), $s->{mkdir}) if $s->{mode}; return }
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
        %ENV = %$env;
        if (defined $cwd) { chdir($cwd) or POSIX::_exit(125) }
        open(STDOUT, '>', $outf) or POSIX::_exit(126);
        open(STDERR, '>', $errf) or POSIX::_exit(126);
        my $inf = "$outf.in";
        open(my $fh, '>:raw', $inf); print $fh $stdin; close $fh;
        open(STDIN, '<', $inf) or POSIX::_exit(126);
        { no warnings "exec"; exec { $argv->[0] } @$argv; }
        POSIX::_exit(127);
    }
    return $pid;
}

sub invoke {
    my ($st, $case, $V, $cdir, $i) = @_;
    my $env = child_env($st, $case, $V, $i);
    my @argv = ("$STAGE/bin/$BRAND-store", map { subst($_, $V) } @{ $st->{argv} });
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
            $av = ["$STAGE/bin/$BRAND-store", map { subst($_, $V) } @{ $in->{argv} }] if $in->{argv};
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
        kill 'KILL', $_->{pid} for @procs;
    }
    my $limit = ($st->{timeout_s} // 60) * 1000;
    for my $p (@procs) {
        my $waited = 0;
        while (waitpid($p->{pid}, POSIX::WNOHANG()) == 0) {
            if (util::clock_ms() - $p->{t0} > $limit) { kill 'KILL', $p->{pid}; waitpid($p->{pid}, 0); $p->{timed_out} = 1; last }
            util::sleep_ms(5);
        }
        my $st_ = $?;
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
my $LIBS_READY;
sub _libs {
    return if $LIBS_READY;
    for my $l (qw(ctx spec settings paths roots log rc identity lock nonce git detect assemble secrets dispatch)) { require "$l.pm" }
    ctx::init("$STAGE/helper");
    $LIBS_READY = 1;
}

sub builtin {
    my ($name, $a, $cdir) = @_;
    _libs();
    my @e;
    if ($name eq 'detect_tsv') {
        my $tsv = src_file($a->{tsv}, $cdir);
        my $dir = $a->{dir} ? src_file($a->{dir}, $cdir) : util::dirname($tsv);
        open(my $fh, '<:raw', $tsv) or return ("cannot read $tsv");
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
            my %got = (verdict => $s->{verdict}, marker_line => $s->{marker_line} // '-', sentinel_from_end => $s->{sentinel_from_end} // '-',
                       nonce => $s->{nonce} // '-', scope => $s->{scope} // '-', normalized_sha256 => $s->{sha256});
            for my $k (qw(verdict marker_line sentinel_from_end nonce scope normalized_sha256)) {
                next unless exists $r{$k} && defined $r{$k} && $r{$k} ne '';
                push @e, "$r{file}: $k $got{$k}, want $r{$k}" if $got{$k} ne $r{$k};
            }
        }
        close $fh;
        push @e, "no rows in $tsv" unless $n;
        return @e;
    }
    if ($name eq 'assemble_goldens') {
        my $dir = $a->{dir} // "$REPO/tests/fixtures/assembly/expected";
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
        # AT-P-11: every use/require in plugin/helper is a floor module (RUNTIME §2.4, plus
        # overload, lib and utf8, probed present in debian:bookworm-slim perl-base), one of
        # the helper's own libraries, or sits inside an eval with a fallback.
        my %floor = map { $_ => 1 } qw(strict warnings constant Fcntl POSIX Errno Cwd File::Spec File::Path File::Temp
            File::Basename IPC::Open3 Getopt::Long IO::Handle List::Util Scalar::Util Text::ParseWords IO::File IO::Select
            Socket Exporter Carp parent integer bytes overload lib utf8);
        my %optional = map { $_ => 1 } qw(Digest::SHA Time::HiRes);
        my $root = "$REPO/plugin/helper";
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
        @stack = ($root);
        my $n = 0;
        while (@stack) {
            my $d = pop @stack;
            for my $f (util::list_dir($d)) {
                my $p = "$d/$f";
                if (-d $p) { push @stack, $p; next }
                next unless $f =~ /\.p[lm]$/;
                my $src = util::read_file($p);
                my $ln = 0;
                for my $line (split /\n/, $src) {
                    $ln++;
                    next if $line =~ /^\s*#/;
                    while ($line =~ /\b(use|require)\s+([A-Za-z_][A-Za-z0-9_:]*)/g) {
                        my ($kw, $m) = ($1, $2);
                        next if $m =~ /^v?\d/ || $m eq 'if';
                        $n++;
                        next if $floor{$m} || $own{$m};
                        next if $optional{$m} && $line =~ /eval\s*\{/;
                        push @e, "$p:$ln: $kw $m is not on the floor";
                    }
                    while ($line =~ /\brequire\s+"([^"\$]+)\.pm"/g) {
                        (my $m = $1) =~ s{/}{::}g;
                        $n++;
                        push @e, "$p:$ln: require \"$1.pm\" is not a helper library" unless $own{$m};
                    }
                }
            }
        }
        push @e, 'no use/require found' unless $n;
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
              queue_add => 'queue-cmd add --lane example-repo/LAB-123', measured_facts => '', remeasure => '');
    my $rf = $file // "$REPO/tests/fixtures/assembly/runtime.json";
    if (-f $rf) { my $j = jsonc::decode(util::read_file($rf)); %rt = (%rt, %$j) if ref $j eq 'HASH' }
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
        push @e, "exit $r->{exit}, want $x->{exit}" . ($r->{err} ? " (stderr: " . substr($r->{err}, 0, 300) . ")" : '')
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
                    } elsif (scalar_text($v) ne scalar_text($w)) {
                        push @e, "json $p = " . scalar_text($v) . ", want " . scalar_text($w);
                    }
                }
            }
        }
        push @e, "stdout is " . length($out) . " bytes > $x->{stdout_max_bytes}" if defined $x->{stdout_max_bytes} && length($out) > $x->{stdout_max_bytes};
        push @e, golden_diff($x->{stdout_golden}, $outc) if $x->{stdout_golden};
        push @e, "stderr not empty: " . substr($r->{err}, 0, 200) if $x->{stderr_empty} && length $r->{err};
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
        if (defined $rw->{count}) { push @e, "rows $rw->{ev} in $rw->{file}: " . scalar(@rows) . ", want $rw->{count}" if @rows != $rw->{count} }
        elsif (!@rows) { push @e, "no $rw->{ev} row" . ($rw->{fields} ? ' with ' . jsonc::encode($rw->{fields}) : '') . " in $rw->{file}" }
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
