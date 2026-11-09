package trial;
# lib/trial.pm: the local shadow trial (TRIAL-DUAL-HANDOFF §4.2-§4.6, owner 2026-10-26 21:2x
# "dual handoffs"): the one trial config at a fixed path, the fail-closed owner checks, the
# old-skill and native-prompt files read at run time and checked against their sha256 lists,
# the facts the old skill's commands would have printed, and the save of the two shadow
# replies (secret scan and redaction before disk) with one content-free moment record.
# Owner: WP-core. Everything here is off unless <home>/.cache/<brand>-trial/trial.json exists
# and says `on`. No text of the owner's skill or of Claude Code's prompt is part of the plugin:
# both are read from the paths the local config names.
use strict;
use warnings;
use utf8;

our $CONFIG_MAX = 65536;
our $SKILL_MAX = 262144;
our $PROMPT_MAX = 131072;
our $NOW_MD_MAX = 8192;
our $PREV_MAX = 49152;
our $REPLY_MAX = 1048576;
# The two files of the old skill the old arm needs, relative to the configured folder.
our @OLD_FILES = ('create-handoff/SKILL.md', 'create-handoff/references/handoff-template.md');
# The two fixed lines that frame the old fork's reply (the adapter asset names the same).
our $OLD_START = qr/^=== OLD-HANDOFF START(?: ([^\n]*?))? ===[ \t]*$/m;
our $OLD_END = qr/^=== OLD-HANDOFF END ===[ \t]*$/m;
our $OLD_EXT = '.old-handoff.txt';
our $NATIVE_EXT = '.native-summary.txt';
our @KEYS = qw(v on trial_until installed handoff_root log_dir cc_versions skip_repos m3 native_tail old_skill native_prompt);
our %MOMENT_KINDS = map { $_ => 1 } qw(m1-owner m1-self m2-halt m2-precompact m2-idle m3-idle m3-auto m3-manual m3-plugin);
our %ARM_STATUS = map { $_ => 1 } qw(ok reuse cancelled aborted api-error empty nothing-to-fork denied rejected no-scan
                                      no-old-skill no-native-prompt bad-reuse lost);
our $SKIP_RE = qr/^skipped:(?:facts-timeout|no-limits|near-limit|cold|repo-skipped|not-owner-config|cc-version|m3-off)$/;

# ---------------------------------------------------------------- places

sub dir { return util::home() . '/.cache/' . ctx::brand() . '-trial' }
sub config_path { return dir() . '/trial.json' }

# inside(path, root) -> 1 when path is root or below it, by whole `/` segments
sub inside {
    my ($p, $r) = @_;
    return 0 unless defined $p && defined $r && $p ne '' && $r ne '';
    $r =~ s{/+$}{};
    $p =~ s{/+$}{};
    return 1 if $r eq '' || $p eq $r;
    return index($p, "$r/") == 0 ? 1 : 0;
}

sub _real { my ($p) = @_; return defined $p && $p ne '' ? util::text(util::real_path($p)) : undef }

# ---------------------------------------------------------------- config

sub _hex64 { my ($v) = @_; return defined $v && !ref $v && $v =~ /^[0-9a-f]{64}$/ ? 1 : 0 }
sub _date { my ($v) = @_; return defined $v && !ref $v && $v =~ /^\d{4}-\d{2}-\d{2}$/ ? 1 : 0 }
sub _abs { my ($v) = @_; return defined $v && !ref $v && $v =~ m{^/} && $v !~ /[\0\n]/ ? 1 : 0 }
sub _rel { my ($v) = @_; return defined $v && !ref $v && $v ne '' && $v !~ m{^/} && $v !~ m{(^|/)\.\.?(/|$)} && $v !~ /[\0\n\\]/ ? 1 : 0 }
sub _bool { my ($v) = @_; return jsonc::is_bool($v) }

sub _sums {
    my ($h, $what) = @_;
    return "$what.sha256 is not an object" unless ref $h eq 'HASH';
    for my $k (sort keys %$h) {
        return "$what.sha256 has a bad path" unless _rel($k);
        return "$what.sha256 has a bad sum" unless _hex64($h->{$k});
    }
    return undef;
}

# parse(raw, today) -> {state => off|bad|on, why, cfg}. `today` is YYYY-MM-DD. Unknown keys are
# refused (a cap, a sampling seed or a typo never passes as a setting: owner "No cap").
sub parse {
    my ($raw, $today) = @_;
    my $j = eval { jsonc::decode(util::text($raw)) };
    return { state => 'bad', why => 'not-json' } unless ref $j eq 'HASH';
    for my $k (sort keys %$j) { return { state => 'bad', why => "unknown-key:$k" } unless grep { $_ eq $k } @KEYS }
    return { state => 'bad', why => 'version' } unless defined $j->{v} && !ref $j->{v} && $j->{v} eq '1';
    return { state => 'bad', why => 'on' } unless _bool($j->{on});
    return { state => 'off', why => 'off' } unless ${ $j->{on} };
    return { state => 'bad', why => 'trial_until' } unless _date($j->{trial_until});
    return { state => 'off', why => 'ended' } if defined $today && $today gt $j->{trial_until};
    return { state => 'bad', why => 'installed' } if exists $j->{installed} && !_date($j->{installed});
    for my $k (qw(handoff_root log_dir)) { return { state => 'bad', why => $k } unless _abs($j->{$k}) }
    return { state => 'bad', why => 'cc_versions' }
        unless ref $j->{cc_versions} eq 'ARRAY' && !grep { !defined $_ || ref $_ || $_ !~ /^\d+\.\d+\.\d+([.+-][0-9A-Za-z.+-]*)?$/ } @{ $j->{cc_versions} };
    if (exists $j->{skip_repos}) {
        return { state => 'bad', why => 'skip_repos' }
            unless ref $j->{skip_repos} eq 'ARRAY' && !grep { !defined $_ || ref $_ || $_ eq '' } @{ $j->{skip_repos} };
    }
    for my $k (qw(m3 native_tail)) { return { state => 'bad', why => $k } if exists $j->{$k} && !_bool($j->{$k}) }
    for my $k (qw(old_skill native_prompt)) {
        next unless exists $j->{$k};
        my $o = $j->{$k};
        return { state => 'bad', why => $k } unless ref $o eq 'HASH' && _abs($o->{dir});
        for my $x (sort keys %$o) { return { state => 'bad', why => "unknown-key:$k.$x" } unless $x eq 'dir' || $x eq 'sha256' }
        my $e = _sums($o->{sha256}, $k);
        return { state => 'bad', why => $e } if defined $e;
    }
    if ($j->{old_skill}) {
        for my $f (@OLD_FILES) { return { state => 'bad', why => "old_skill.sha256 lacks $f" } unless $j->{old_skill}{sha256}{$f} }
    }
    my %c = (
        trial_until => $j->{trial_until}, installed => $j->{installed},
        handoff_root => $j->{handoff_root}, log_dir => $j->{log_dir},
        cc_versions => [@{ $j->{cc_versions} }], skip_repos => [@{ $j->{skip_repos} || [] }],
        m3 => ($j->{m3} && ${ $j->{m3} }) ? 1 : 0, native_tail => ($j->{native_tail} && ${ $j->{native_tail} }) ? 1 : 0,
        old_skill => $j->{old_skill}, native_prompt => $j->{native_prompt},
    );
    return { state => 'on', cfg => \%c };
}

# load() -> parse's answer, or {state => absent} when the file is not there. The folder is
# refused when, by real path, it lies inside the handoff root, the log folder, a git work tree
# or the Claude Code config folder (whole segments; §4.3).
sub load {
    my $p = config_path();
    return { state => 'absent' } unless -e $p;
    return { state => 'bad', why => 'not-a-file' } unless -f $p && !-l $p;
    my $raw = util::read_file($p, $CONFIG_MAX + 1);
    return { state => 'bad', why => 'unreadable' } unless defined $raw;
    return { state => 'bad', why => 'too-large' } if length($raw) > $CONFIG_MAX;
    my $r = parse($raw, util::day());
    return $r unless $r->{state} eq 'on';
    my $why = dir_refused($r->{cfg});
    return { state => 'bad', why => $why } if defined $why;
    return $r;
}

sub dir_refused {
    my ($cfg) = @_;
    my $d = _real(dir());
    return 'dir-unresolved' unless defined $d;
    for my $k (qw(handoff_root log_dir)) {
        my $r = _real($cfg->{$k});
        return "dir-in-$k" if defined $r && inside($d, $r);
    }
    my $cd = _real(settings::config_dir());
    return 'dir-in-config' if defined $cd && inside($d, $cd);
    my $p = $d;
    while (defined $p && $p ne '' && $p ne '/') {
        return 'dir-in-git' if -e "$p/.git";
        $p = util::dirname($p);
    }
    return undef;
}

# owner_skip(cfg) -> undef when this session runs in the owner's own config, else
# `not-owner-config` with the reason: another CLAUDE_CONFIG_DIR whose settings.json is not the
# account's own file, a HOME that is not the account home, or a handoff root / log folder other
# than the pinned ones (lab cells, §4.3).
sub owner_skip {
    my ($cfg) = @_;
    # The owner's same-file rule (2026-10-27 20:38), as for the consent keys: a config folder whose
    # settings.json is the account's ~/.claude/settings.json (a symlink or a hard link to it) is
    # the owner's own config; any other config folder is not.
    return 'config-dir' if settings::config_dir_foreign();
    my $acct = settings::consent_dir();
    return 'home' unless defined $acct;
    my $h = _real(util::home());
    my $a = _real(util::dirname($acct));
    return 'home' unless defined $h && defined $a && $h eq $a;
    my $root = _real(rc::root());
    my $watch = _real(rc::watch());
    return 'handoff-root' unless defined $root && $root eq (_real($cfg->{handoff_root}) // '');
    return 'log-dir' unless defined $watch && $watch eq (_real($cfg->{log_dir}) // '');
    return undef;
}

# ---------------------------------------------------------------- run-time texts

# _read_checked(dir, rel, sum, max) -> (bytes) or (undef, why)
sub _read_checked {
    my ($dir, $rel, $sum, $max) = @_;
    my $p = "$dir/$rel";
    return (undef, "missing:$rel") unless -f $p;
    my $raw = util::read_file($p, $max + 1);
    return (undef, "missing:$rel") unless defined $raw;
    return (undef, "too-large:$rel") if length($raw) > $max;
    return (undef, "sum:$rel") unless defined $sum && sha::hex256($raw) eq $sum;
    return ($raw);
}

# old_skill(cfg, queue_cmd) -> {status => ok, skill, template, sums, filled_sha256} or
# {status => no-old-skill, why}. The H10 copy's two tokens are filled as the lab fills them:
# {RUN_HANDOFFS} with the trial folder's old root, {RUN_QUEUE_CMD} with queue_cmd (or a note).
sub old_skill {
    my ($cfg, $queue_cmd) = @_;
    my $o = $cfg->{old_skill};
    return { status => 'no-old-skill', why => 'not-configured' } unless ref $o eq 'HASH';
    my (%txt, %sums);
    for my $f (@OLD_FILES) {
        my ($raw, $why) = _read_checked($o->{dir}, $f, $o->{sha256}{$f}, $SKILL_MAX);
        return { status => 'no-old-skill', why => $why } unless defined $raw;
        $txt{$f} = util::text($raw);
        $sums{$f} = $o->{sha256}{$f};
    }
    my $root = dir() . '/old';
    my $q = defined $queue_cmd && $queue_cmd ne '' ? util::text($queue_cmd) : '(no queue command is set: treat the list as empty)';
    my ($skill, $tpl) = map { my $t = $_; $t =~ s/\{RUN_HANDOFFS\}/$root/g; $t =~ s/\{RUN_QUEUE_CMD\}/$q/g; $t } @txt{@OLD_FILES};
    return { status => 'ok', skill => $skill, template => $tpl, sums => \%sums, filled_sha256 => sha::hex256($skill . "\0" . $tpl) };
}

# served(config_dir) -> {arm, arm_source, cache_prefix_flag}: the compaction prompt arm from the
# env, else Claude Code's cached feature value, else `control`; the cached prefix flag as read
# (null when absent). Only the two values are matched in the cache file; nothing else is read.
sub served {
    my $env = $ENV{CLAUDE_CODE_CURRIED_TRINKET};
    my %r = (arm => 'control', arm_source => 'default', cache_prefix_flag => undef);
    # Claude Code's own cache file: <CLAUDE_CONFIG_DIR>/.claude.json, else <home>/.claude.json
    # (the same place the mod's served idle hint reads, deps.ts SERVED_FILE).
    my $cd = $ENV{CLAUDE_CONFIG_DIR};
    my $base = defined $cd && $cd ne '' ? util::expand_tilde($cd) : util::home();
    my $raw = util::read_file("$base/.claude.json", 8000000);
    if (defined $env && $env =~ /^[a-z0-9_]{1,40}$/) { @r{qw(arm arm_source)} = ($env, 'env') }
    elsif (defined $raw && $raw =~ /"tengu_curried_trinket"\s*:\s*"([a-z0-9_]{1,40})"/) { @r{qw(arm arm_source)} = ($1, 'cached') }
    if (defined $raw && $raw =~ /"tengu_compact_cache_prefix"\s*:\s*(true|false)/) { $r{cache_prefix_flag} = $1 eq 'true' ? 1 : 0 }
    return \%r;
}

# precompact_hooks(brand) -> 1 when the user's settings.json lists a PreCompact hook that is not
# this plugin's (its text lands in a real compaction's instructions, §4.2b); 0 none; undef unread.
sub precompact_hooks {
    my $raw = util::read_file(settings::config_dir() . '/settings.json', 1048576);
    return 0 unless defined $raw;
    my $j = eval { jsonc::decode(util::text($raw)) };
    return undef unless ref $j eq 'HASH';
    my $pc = ref $j->{hooks} eq 'HASH' ? $j->{hooks}{PreCompact} : undef;
    return 0 unless ref $pc eq 'ARRAY';
    # the plugin's own launcher, by its file name (tools/build writes it into hooks.json)
    my $own = '/' . util::basename(ctx::launcher());
    for my $m (@$pc) {
        next unless ref $m eq 'HASH' && ref $m->{hooks} eq 'ARRAY';
        for my $h (@{ $m->{hooks} }) {
            next unless ref $h eq 'HASH';
            return 1 unless defined $h->{command} && index($h->{command}, $own) >= 0;
        }
    }
    return 0;
}

# transcript_flag(sid) -> 1 when the session has a transcript file under the config folder.
sub transcript_flag {
    my ($sid) = @_;
    my $base = settings::config_dir() . '/projects';
    for my $d (util::list_dir_max($base, 4096)) { return 1 if -f "$base/$d/$sid.jsonl" }
    return 0;
}

# native(cfg, cc_version, sid) -> {status => ok, head, tail, sums, ...} or {status => no-native-prompt, why, ...}.
# The head ends where the engine inserts its additional instructions; the tail is the part
# after them (written per Claude Code version, arm and transcript flag by the lab's extractor).
sub native {
    my ($cfg, $ver, $sid) = @_;
    my $sv = served();
    my $t = transcript_flag($sid);
    my %r = (cc_version => $ver, prompt_arm => $sv->{arm}, arm_source => $sv->{arm_source},
             cache_prefix_flag => $sv->{cache_prefix_flag}, transcript_flag => $t, precompact_hooks => precompact_hooks());
    my $n = $cfg->{native_prompt};
    return { %r, status => 'no-native-prompt', why => 'not-configured' } unless ref $n eq 'HASH';
    return { %r, status => 'no-native-prompt', why => 'no-version' } unless defined $ver && $ver =~ /^[0-9A-Za-z.+-]{1,40}$/;
    my %got;
    for my $part (qw(head tail)) {
        my $rel = "$ver/$sv->{arm}.t$t.$part.txt";
        my ($raw, $why) = _read_checked($n->{dir}, $rel, $n->{sha256}{$rel}, $PROMPT_MAX);
        return { %r, status => 'no-native-prompt', why => (defined $n->{sha256}{$rel} ? $why : "unlisted:$rel") } unless defined $raw;
        $got{$part} = util::text($raw);
        $r{"${part}_sha256"} = $n->{sha256}{$rel};
    }
    return { %r, status => 'ok', head => $got{head}, tail => $got{tail} };
}

# ---------------------------------------------------------------- facts (§4.2 item 3)

sub _git_out {
    my ($cwd, $args, $left) = @_;
    my $r = git::cmd($cwd, $args, $left->());
    return undef if $r->{timed_out} || $r->{unavailable} || $r->{exit} != 0;
    my $o = util::text($r->{out});
    $o =~ s/\s+\z//;
    return $o;
}

# repo_ticket(cwd, branch, common_dir) -> (repo, ticket, repo_name) by the old skill's own rules:
# the repo is the folder that holds the git common dir (else the cwd's name); the ticket is the
# branch's first `[A-Z]+-[0-9]+`, else `general`. `repo` is that name as one safe path component
# (bucket()); `repo_name` is the name as found, used only to read the real handoff bucket.
sub repo_ticket {
    my ($cwd, $branch, $common) = @_;
    my $repo;
    if (defined $common && $common ne '') { (my $c = $common) =~ s{/+$}{}; $repo = util::basename(util::dirname($c)) }
    $repo = util::basename($cwd // '') unless defined $repo && $repo ne '';
    my ($ticket) = (defined $branch ? $branch : '') =~ /([A-Z]+-[0-9]+)/;
    return (bucket($repo), $ticket // 'general', $repo);
}

sub component { my ($v) = @_; return defined $v && $v =~ /^[A-Za-z0-9._-]{1,100}$/ && $v ne '.' && $v ne '..' ? 1 : 0 }

# bucket(name) -> the name when it is a safe path component, else a slug of it plus 8 hex of its
# sha256 (`My Project` -> `My-Project-<8 hex>`), so every repo gets a trial bucket and the name
# reaches no path as it is (a space, a non-ASCII letter, `.`, `..`, the root's empty name).
sub bucket {
    my ($name) = @_;
    $name = '' unless defined $name;
    return $name if component($name);
    my $raw = util::to_bytes($name);
    (my $s = $raw) =~ s/[^A-Za-z0-9._-]+/-/g;
    $s =~ s/^[.-]+//;
    $s =~ s/-+$//;
    $s = substr($s, 0, 60);
    $s =~ s/-+$//;
    return ($s eq '' ? 'repo' : $s) . '-' . substr(sha::hex256($raw), 0, 8);
}

# skipped_repo(cfg, repo, repo_name) -> 1 when the skip-list names the repo, as found or as its bucket.
sub skipped_repo {
    my ($cfg, $repo, $name) = @_;
    for my $x (@{ $cfg->{skip_repos} || [] }) {
        return 1 if (defined $name && $x eq $name) || $x eq $repo || bucket($x) eq $repo;
    }
    return 0;
}

# A plain file that is not a symlink (a FIFO, a device or a link out of the folder is never read).
sub _plain { my ($p) = @_; return -f $p && !-l $p ? 1 : 0 }

sub _stamp_of { my ($n) = @_; return $n =~ /^(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})/ ? $1 : '' }

# The frontmatter of a markdown file: (has kind:, previous_handoff value).
sub _front {
    my ($text) = @_;
    return (0, undef) unless defined $text && $text =~ /\A---\r?\n(.*?)\r?\n---\r?\n/s;
    my $fm = $1;
    my $kind = $fm =~ /^kind:/m ? 1 : 0;
    my ($prev) = $fm =~ /^previous_handoff:[ \t]*"?([^"\n]*?)"?[ \t]*$/m;
    return ($kind, $prev);
}

# old_chain(cfg, repo, ticket, sid8) -> {prev => {path, text} | undef, flagged => n, own => {path, text} | undef}
# The newest of this bucket's old shadows and its genuine old-skill files (no `kind:`, and dated
# before the install or with a previous_handoff that names no file with a `kind:`); never the
# plugin's own files. `own` is this session's newest old shadow (the old skill's Step 0).
sub old_chain {
    my ($cfg, $repo, $ticket, $sid8, $name) = @_;
    my %r = (prev => undef, flagged => 0, own => undef);
    return \%r unless component($repo) && component($ticket);
    my @cand;
    my $sd = dir() . "/old/$repo/$ticket";
    for my $f (util::list_dir_max($sd, 2000)) {
        next unless $f =~ /\Q$OLD_EXT\E$/ && _plain("$sd/$f");
        push @cand, { path => "$sd/$f", stamp => _stamp_of($f), name => $f, shadow => 1 };
    }
    # The real bucket is named as the old skill names it: the repo's name as found.
    $name = $repo unless defined $name && $name ne '' && $name ne '.' && $name ne '..' && $name !~ m{[/\0]};
    my $root = util::clean_path($cfg->{handoff_root});
    my $rb = "$root/" . util::to_bytes($name) . "/$ticket";
    my $inst = defined $cfg->{installed} ? $cfg->{installed} : undef;
    for my $f (util::list_dir_max($rb, 2000)) {
        next unless $f =~ /\.md$/ && _plain("$rb/$f") && _stamp_of($f) ne '';
        my $head = util::read_file("$rb/$f", 8192);
        my ($kind, $prev) = _front(util::text($head));
        next if $kind;
        my $genuine = defined $inst && substr(_stamp_of($f), 0, 10) lt $inst ? 1 : 0;
        if (!$genuine) {
            $genuine = 1;
            if (defined $prev && $prev ne '') {
                my $pp = util::expand_tilde($prev);
                $pp = "$rb/$pp" unless $pp =~ m{^/};
                my ($pk) = -f $pp ? _front(util::text(util::read_file($pp, 8192))) : (0);
                $genuine = 0 if $pk;
            }
        }
        if (!$genuine) { $r{flagged}++; next }
        push @cand, { path => "$rb/$f", stamp => _stamp_of($f), name => $f, shadow => 0 };
    }
    my @s = sort { $b->{stamp} cmp $a->{stamp} || $b->{name} cmp $a->{name} } @cand;
    if (my $n = $s[0]) { $r{prev} = { path => $n->{path}, text => util::text(util::read_file($n->{path}, $PREV_MAX)) } }
    if (defined $sid8) {
        my ($own) = grep { $_->{shadow} && index($_->{name}, "_${sid8}_") >= 0 } @s;
        # Step 0 reads this session's own shadow: its text too when it is not the previous one.
        $r{own} = { path => $own->{path}, same => ($r{prev} && $r{prev}{path} eq $own->{path} ? 1 : 0) } if $own;
        $r{own}{text} = util::text(util::read_file($own->{path}, $PREV_MAX)) if $own && !$r{own}{same};
    }
    return \%r;
}

# place(cwd, budget_ms) -> {w (git::where), repo, ticket, repo_name, t0}: the bucket first, so a
# skipped repo costs one git call and nothing else is gathered (§4.5 skip-list).
sub place {
    my ($cwd, $budget_ms) = @_;
    my $t0 = util::clock_ms();
    my $w = git::where($cwd, _left($t0, $budget_ms)->());
    my ($repo, $ticket, $name) = repo_ticket($cwd, $w->{in_git} ? $w->{branch} : undef, $w->{common_dir});
    return { w => $w, repo => $repo, ticket => $ticket, repo_name => $name, t0 => $t0 };
}

sub _left {
    my ($t0, $budget_ms) = @_;
    return sub { my $l = $t0 + ($budget_ms // 2500) - util::clock_ms(); return $l < 50 ? 50 : ($l > 2000 ? 2000 : $l) };
}

# now_md(toplevel) -> the bytes of <toplevel>/.remember/now.md (capped), only when it is a plain
# file whose real path lies inside the toplevel's (a link out of the repository is never read).
sub now_md {
    my ($top) = @_;
    return undef unless defined $top && $top ne '';
    my $p = "$top/.remember/now.md";
    return undef unless _plain($p);
    my ($rt, $rp) = (_real($top), _real($p));
    return undef unless defined $rt && defined $rp && inside($rp, $rt) && $rp ne $rt;
    return util::read_file($p, $NOW_MD_MAX);
}

# facts(sid, cwd, cfg, budget_ms, place) -> {text, repo, ticket, worktree, branch, head, dirty, old_chain_flagged}
# Read-only: no file is written, and the queue tool's list is read without the adapter's
# contract record or caps cache (queue::lane quiet), so the trial changes nothing the plugin shows.
sub facts {
    my ($sid, $cwd, $cfg, $budget_ms, $pl) = @_;
    $pl //= place($cwd, $budget_ms);
    my $left = _left($pl->{t0}, $budget_ms);
    my $w = $pl->{w};
    my ($branch, $head, $log, $stat, $dirty) = (undef, undef, undef, undef, undef);
    if ($w->{in_git}) {
        $branch = $w->{branch};
        $head = _git_out($cwd, ['rev-parse', '--short', 'HEAD'], $left);
        $log = _git_out($cwd, ['log', '--oneline', '-10'], $left);
        $stat = _git_out($cwd, ['diff', '--stat'], $left);
        my $st = _git_out($cwd, ['status', '--porcelain=v1', '--untracked-files=normal'], $left);
        $dirty = defined $st ? scalar(grep { /\S/ } split /\n/, $st) : undef;
    }
    my ($repo, $ticket, $name) = @$pl{qw(repo ticket repo_name)};
    my $top = $w->{toplevel} // $cwd;
    my $now_md = now_md($top);
    my $qcmd = rc::val('queue_cmd');
    my $queue = 'nothing queued (not measured)';
    if (defined $qcmd && $qcmd ne '') {
        my $l = eval { queue::lane($sid, $qcmd, 1500, 1) } || {};
        $queue = ($l->{status} // '') eq 'ok' ? ($l->{queued_line} // "lane $l->{lane}: nothing queued") : "nothing queued (queue status: " . ($l->{status} // 'unknown') . ")";
    }
    my $sid8 = substr($sid, 0, 8);
    my $chain = old_chain($cfg, $repo, $ticket, $sid8, $name);
    my $na = '(not available)';
    my $own = $chain->{own};
    my @t = (
        "Date: " . util::iso(util::now()),
        "Repository: $repo" . ($repo ne $name ? ' (the folder ' . util::text($name) . ', as one path part)' : ''),
        "Ticket bucket: $ticket",
        "\$ git branch --show-current\n" . ($branch // $na),
        "\$ git rev-parse --short HEAD\n" . ($head // $na),
        "\$ git log --oneline -10\n" . ($log // $na),
        "\$ git diff --stat\n" . (defined $stat ? ($stat eq '' ? '(no changes)' : $stat) : $na),
        ".remember/now.md:\n" . (defined $now_md ? util::text($now_md) : 'absent'),
        "Queue list:\n$queue",
        "Previous handoff in this bucket (newest by file name):\n"
            . ($chain->{prev} ? util::abbrev($chain->{prev}{path}) . "\n" . ($chain->{prev}{text} // '') : 'none'),
        "This session's earlier handoff (Step 0): "
            . (!$own ? 'none' : $own->{same} ? util::abbrev($own->{path}) . ' (the previous handoff above)'
                                             : util::abbrev($own->{path}) . "\n" . ($own->{text} // '')),
    );
    return { text => join("\n\n", @t), repo => $repo, ticket => $ticket, worktree => (defined $w->{toplevel} ? util::text($w->{toplevel}) : undef),
             branch => $branch, head => $head, dirty => $dirty, old_chain_flagged => $chain->{flagged} };
}

# ---------------------------------------------------------------- save (§4.5, §4.6)

# scan_redact(text) -> (redacted text, [rule ids]) or (undef, 'no-scan'): nothing is saved when
# the scanner has no rules or fails (core::secrets_scan would answer [] on a failure).
sub scan_redact {
    my ($text) = @_;
    my $rules = eval { spec::secret_rules() };
    return (undef, 'no-scan') unless ref $rules eq 'ARRAY' && @$rules;
    my ($red, $hits) = eval { secrets::redact($text) };
    return (undef, 'no-scan') unless defined $red && ref $hits eq 'ARRAY';
    my %seen;
    my @ids = grep { !$seen{$_}++ } map { $_->{rule} } @$hits;
    return ($red, \@ids);
}

# native_body(reply) -> the summary body by the engine's rule: the first <analysis>…</analysis>
# dropped, the <summary> body kept (the whole reply when it has none).
sub native_body {
    my ($t) = @_;
    $t =~ s{<analysis>.*?</analysis>}{}s;
    return $1 if $t =~ m{<summary>(.*?)</summary>}s;
    return $1 if $t =~ m{<summary>(.*)\z}s;
    return $t;
}

# old_reply(reply, repo, ticket) -> {kind => file, slug, body} | {kind => reuse, path} | {kind => bad-reuse}
sub old_reply {
    my ($reply, $repo, $ticket) = @_;
    my $t = $reply;
    $t =~ s/\A\s+//;
    if ($t =~ /\AREUSE[ \t]+(\S[^\n]*?)[ \t]*(?:\n|\z)/) {
        my $p = util::expand_tilde($1);
        my $base = _real(dir() . "/old/$repo/$ticket");
        my $rp = $p =~ m{^/} && -f $p ? _real($p) : undef;
        return { kind => 'reuse', path => $rp } if defined $base && defined $rp && inside($rp, $base) && $rp ne $base && $rp =~ /\Q$OLD_EXT\E$/;
        return { kind => 'bad-reuse' };
    }
    my $slug = 'handoff';
    my $body = $reply;
    if ($reply =~ $OLD_START) {
        my $d = defined $1 ? $1 : '';
        my $from = $+[0];
        my $rest = substr($reply, $from);
        $rest =~ s/\A\r?\n//;
        $rest = substr($rest, 0, $-[0]) if $rest =~ $OLD_END;
        $body = $rest;
        $slug = $d if $d =~ /^[a-z0-9-]{1,60}$/;
    }
    return { kind => 'file', slug => $slug, body => $body };
}

# clean_slug(slug) -> the slug when the secret scan finds nothing in it, else `handoff`: a file name
# and the record's path are never a token's carrier (the body copy is redacted, the name cannot be).
sub clean_slug {
    my ($slug) = @_;
    return 'handoff' unless defined $slug && $slug =~ /^[a-z0-9-]{1,60}$/;
    my ($red, $ids) = scan_redact($slug);
    return defined $red && ref $ids eq 'ARRAY' && !@$ids ? $slug : 'handoff';
}

# write_shadow(dir, name stem, ext, text) -> path (exclusive create 0600; `-2`, `-3`… on a clash)
sub write_shadow {
    my ($d, $stem, $ext, $text) = @_;
    util::mkdir_p($d);
    for my $i (1 .. 20) {
        my $p = "$d/$stem" . ($i > 1 ? "-$i" : '') . $ext;
        return $p if util::write_excl($p, $text, 0600);
    }
    die "trial: no free shadow name\n";
}

# The moment fields the mod may pass (content-free by type); anything else is dropped.
my $ID = qr/^[A-Za-z0-9._:\/-]{1,120}$/;
# The mod's local times (isoLocal: an offset east of UTC is `+HH:MM`), with optional milliseconds.
our $TIME = qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/;
# The served model by the export's own class (watch/export.pm `model`, MG-4): a plain id with
# Claude Code's `[1m]`-style suffix kept; a cloud ARN or profile path (an account id) dropped.
our $MODEL = qr{^[a-z][a-z0-9._-]{0,63}(?:\[[0-9a-z]{1,8}\])?$};
# D-76: a near-limit skip's usage windows, each `kind:percent` (`arm:percent` from the idle
# record), as the export's `window` class takes them; at most 8 kept.
our $WINDOW = qr/\A[a-z][a-z0-9_]{0,31}:(?:[0-9]{1,4}|unknown)\z/;
our %MOMENT_FIELD = (
    session_id => $ID, kind => qr/^[a-z0-9-]{1,20}$/, trigger => qr/^[a-z-]{1,20}$/, position => 'int',
    ht => $ID, ht_rerun => $ID, turn_id => $ID, nonce => qr/^[0-9a-f]{8}$/, opened_at => $TIME, plugin_side => qr/^[a-z-]{1,20}$/,
    facts_age_s => 'int', model => $MODEL, cc_version => $ID, worktree => 'path', branch => 'text', head => qr/^[0-9a-f]{4,64}$/,
    dirty => 'int', old_chain_flagged => 'int', tokens => 'int', status => qr/^[a-z:-]{1,40}$/, windows => 'windows',
);
our %ARM_FIELD = (
    status => qr/^[a-z:-]{1,40}$/, started_at => $TIME, ended_at => $TIME, http_status => 'int', error => qr/^[a-z_]{1,40}$/,
    input_tokens => 'int', output_tokens => 'int', cache_read_input_tokens => 'int', cache_creation_input_tokens => 'int',
    read_share => 'num', reads_est => 'num', late => 'bool',
);
our %OLD_FIELD = (filled_sha256 => qr/^[0-9a-f]{64}$/, adapter_sha256 => qr/^[0-9a-f]{64}$/);
our %NATIVE_FIELD = (
    cc_version => $ID, head_sha256 => qr/^[0-9a-f]{64}$/, tail_sha256 => qr/^[0-9a-f]{64}$/, prompt_arm => qr/^[a-z0-9_]{1,40}$/,
    arm_source => qr/^(env|cached|default)$/, cache_prefix_flag => 'bool', transcript_flag => 'int', precompact_hooks => 'bool',
    tail_supplied => 'bool', compact_text_added => 'bool', tail_line_sha256 => qr/^[0-9a-f]{64}$/,
);

# arm_meta(in, extra spec) -> the arm's content-free fields (its usage and status included)
sub arm_meta {
    my ($in, $extra) = @_;
    my $o = _clean($in, { %ARM_FIELD, %{ $extra || {} } });
    $o->{status} = 'rejected' unless defined $o->{status} && ($ARM_STATUS{ $o->{status} } || $o->{status} =~ $SKIP_RE);
    if (ref $in eq 'HASH' && ref $in->{skill_sha256} eq 'HASH') {
        my %s = map { ($_ => $in->{skill_sha256}{$_}) } grep { _rel($_) && _hex64($in->{skill_sha256}{$_}) } keys %{ $in->{skill_sha256} };
        $o->{skill_sha256} = \%s;
    }
    return $o;
}

sub moment_meta { return _clean($_[0], \%MOMENT_FIELD) }

# A moment id: <sid8>-<ht, turn nonce or dispatch nonce> (8 hex).
sub valid_moment_id { my ($v) = @_; return defined $v && !ref $v && $v =~ /^[A-Za-z0-9]{8}-[0-9a-f]{8}$/ ? 1 : 0 }

# record_path(moment_id, suffix) -> <trial>/moments/<YYYY-MM>/<id><suffix>.json
sub record_path {
    my ($id, $suffix) = @_;
    my $month = substr(util::iso(util::now()), 0, 7);
    return dir() . "/moments/$month/$id" . ($suffix // '') . '.json';
}

sub _clean {
    my ($in, $spec) = @_;
    my %o;
    return \%o unless ref $in eq 'HASH';
    for my $k (sort keys %$spec) {
        next unless exists $in->{$k};
        my ($v, $t) = ($in->{$k}, $spec->{$k});
        if (!defined $v) { $o{$k} = undef; next }
        if ($t eq 'int') { $o{$k} = 0 + $v if !ref $v && $v =~ /^-?\d{1,15}$/; next }
        if ($t eq 'num') { $o{$k} = 0 + $v if !ref $v && $v =~ /^-?\d{1,15}(\.\d{1,6})?$/; next }
        if ($t eq 'bool') { $o{$k} = jsonc::bool(jsonc::is_bool($v) ? $$v : $v) if jsonc::is_bool($v) || (!ref $v && $v =~ /^[01]$/); next }
        if ($t eq 'path') { $o{$k} = $v if !ref $v && $v =~ m{^/} && $v !~ /[\0\n]/ && length($v) <= 1024; next }
        if ($t eq 'text') { $o{$k} = $v if !ref $v && $v !~ /[\0\n]/ && length($v) <= 255; next }
        if ($t eq 'windows') {
            next unless ref $v eq 'ARRAY';
            my @w = grep { defined $_ && !ref $_ && $_ =~ $WINDOW } @$v;
            $o{$k} = [ splice(@w, 0, 8) ];
            next;
        }
        $o{$k} = $v if !ref $v && $v =~ $t;
    }
    return \%o;
}

1;
