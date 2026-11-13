package watch::export;
# lib/watch/export.pm: `report` and the export
# transform it shares with `watch report --export`.
#
# The bundle is built from the allowlist inputs only, every row goes through the
# export schema (lib/watch/export_schema.pm), each staged file then passes the fail-closed
# identity scan and the secret scan, and what passes is zipped (lib/watch/
# bundle.pm). Nothing is uploaded and nothing under <watch> is changed or deleted: the
# only files this writes are the zip, the local salt and the install id (AT-WB-06),
# plus one `report_withheld` row when a file is withheld. `--dry-run` writes nothing at all.
# No network module is used (AT-WB-11).
use strict;
use warnings;
use utf8;
use Cwd ();
use POSIX ();
use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_RDONLY);
use watch::ctx;
use watch::io;
use watch::json;
use watch::spec;
use watch::export_schema;
use watch::bundle;
use watch::alerts;

our $SCHEMA_NAME_SUFFIX = '-report/1';
our @FIXED = qw(README.txt manifest.json config.json probes.json sizes.json keep-warm.json);
our $MAX_MB_DEFAULT = 20;
our $IDENTITY_MIN = 4;
our $GIT_REPOS_MAX = 20;
our $GIT_BUDGET_S = 2;
my $HSID_RE = qr/\A[0-9a-f]{12}\z/;
my $SID_RE = qr/\A[0-9A-Za-z][0-9A-Za-z-]{0,63}\z/;

# --- the export transform ---------------------------------------------------

# A hasher: sub(value) -> the first 12 hex of HMAC-SHA256(salt, value).
sub hasher {
    my ($salt, $sha256) = @_;
    my %memo;
    return sub {
        my ($v) = @_;
        return undef unless defined $v && !ref $v && length $v;
        return $memo{$v} //= substr(watch::bundle::hmac_sha256_hex($salt, "$v", $sha256), 0, 12);
    };
}

my %ACTOR_KEEP = map { $_ => 1 } qw(main unknown sub sub-unknown unattributed);
my %RX = (
    nonce   => qr/\A[0-9a-f]{8}\z/,
    id6     => qr/\A(?:[0-9a-f]{6}|h[0-9a-f]{5})(?:-[0-9]{1,3})?\z/,
    hex8    => qr/\A[0-9a-f]{8}\z/,
    hex12   => qr/\A[0-9a-f]{12}\z/,
    stamp   => qr/\A[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}\z/,
    ts      => qr/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:?[0-9]{2})\z/,
    version => qr/\A[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,6}(?:-[0-9A-Za-z.]{1,20})?\z/,
    word    => qr/\A[a-z][a-z0-9_-]{0,31}\z/,
    # a plain model id only; no `:` or `/`, so a cloud ARN or profile path (an account id)
    # is dropped, never exported
    model   => qr{\A[a-z][a-z0-9._-]{0,63}(?:\[[0-9a-z]{1,8}\])?\z},
    rule    => qr/\A[A-Z]-[0-9]{2}\z/,
    # a usage window as a near-limit row names it, `kind:percent` (Claude Code's window kind
    # or `arm`, a whole percent or `unknown`)
    window  => qr/\A[a-z][a-z0-9_]{0,31}:(?:[0-9]{1,4}|unknown)\z/,
    # where a usage window's reading came from, `kind:source` (`plugin`, `statusline`, `peer`)
    wsrc    => qr/\A[a-z][a-z0-9_]{0,31}:(?:plugin|statusline|peer)\z/,
);

sub _is_num {
    my ($v) = @_;
    return 0 if !defined $v || ref $v;
    return $v =~ /\A-?(?:0|[1-9][0-9]{0,17})(?:\.[0-9]{1,12})?(?:[eE][-+]?[0-9]{1,3})?\z/ ? 1 : 0;
}

sub _bool {
    my ($v) = @_;
    return $$v ? \1 : \0 if ref $v eq 'SCALAR';
    return undef if ref $v || !defined $v;
    return ($v eq '1' || $v eq 'true') ? \1 : ($v eq '0' || $v eq 'false') ? \0 : undef;
}

sub _slot {
    my ($v) = @_;
    return undef if ref $v || !defined $v;
    return 'subagents' if $v =~ m{(?:\A|/)subagents(?:/|\z)};
    return 'unattributed' if $v =~ m{(?:\A|/)unattributed(?:/|\z)};
    return 'main' if $v =~ m{(?:\A|/)compact/};
    return 'other';
}

# One value through one class. Returns (1, value) to keep, or (0) to drop.
sub xvalue {
    my ($class, $v, $X) = @_;
    return (1, undef) unless defined $v;
    if (ref $class eq 'ARRAY') {
        my ($k, @a) = @$class;
        if ($k eq 'enum') {
            return (0) if ref $v;
            return (1, (grep { $_ eq $v } @a) ? $v : 'other');
        }
        if ($k eq 'pre') {
            return (0) if ref $v;
            my ($vals, $pres) = @a;
            return (1, $v) if grep { $_ eq $v } @$vals;
            if ($v =~ /\A([A-Za-z-]+):(.*)\z/s && grep { $_ eq $1 } @$pres) {
                my ($p, $w) = ($1, $2);
                return (1, "$p:" . ($w =~ $RX{word} ? $w : 'other'));
            }
            return (1, 'other');
        }
        if ($k eq 'list') {
            return (0) unless ref $v eq 'ARRAY';
            my @out;
            for my $i (@$v) {
                my ($ok, $x) = xvalue($a[0], $i, $X);
                push @out, $x if $ok && defined $x;
            }
            return (1, \@out);
        }
        if ($k eq 'counts') {
            return (0) unless ref $v eq 'HASH';
            my $kc = $a[0] // 'word';
            my %o;
            for my $key (sort keys %$v) {
                my ($ok, $kk) = xvalue($kc, $key, $X);
                $kk = 'other' unless $ok && defined $kk && !ref $kk;
                my $n = $v->{$key};
                next unless _is_num($n);
                $o{$kk} += 0 + $n;
            }
            return (1, \%o);
        }
        if ($k eq 'or') {
            my ($inner, @words) = @a;
            return (1, $v) if !ref $v && grep { $_ eq $v } @words;
            return xvalue($inner, $v, $X);
        }
        if ($k eq 'obj') {
            return (0) unless ref $v eq 'HASH';
            my $o = _fields($a[0], $v, $X, $X->{_path});
            return (1, $o);
        }
        return (0);
    }
    return (0) if $class eq 'drop';
    if ($class eq 'num') { return _is_num($v) ? (1, 0 + $v) : (0) }
    if ($class eq 'int') { return (!ref $v && defined $v && $v =~ /\A-?[0-9]{1,15}\z/) ? (1, 0 + $v) : (0) }
    if ($class eq 'bool') { my $b = _bool($v); return defined $b ? (1, $b) : (0) }
    if ($class eq 'hash') { return ref $v ? (0) : (1, $X->{hash}->($v)) }
    if ($class eq 'actor') {
        return (0) if ref $v;
        return (1, $ACTOR_KEEP{$v} ? $v : $X->{hash}->($v));
    }
    if ($class eq 'slot') { my $s = _slot($v); return defined $s ? (1, $s) : (0) }
    if ($class eq 'tool') {
        return (0) if ref $v;
        return (1, 'mcp') if $v eq 'mcp' || $v =~ /\Amcp__/;
        return (1, watch::export_schema::builtin_tool($v) ? $v : 'other');
    }
    if ($class eq 'heading') {
        return (0) if ref $v;
        return (1, $v) if grep { $_ eq $v } @watch::export_schema::SECTION_KEEP;
        my $id = $X->{headings}{$v};
        return (1, defined $id ? $id : 'other');
    }
    if ($RX{$class}) {
        return (0) if ref $v;
        return $v =~ $RX{$class} ? (1, $v) : $class eq 'word' ? (1, 'other') : (0);
    }
    return (0);
}

sub _fields {
    my ($spec, $row, $X, $path) = @_;
    my %o;
    for my $f (sort keys %$row) {
        next if $f =~ /\A_/;
        my $class = $spec->{$f};
        if (!defined $class) { $X->{dropped}{"$path.$f"}++; next }
        local $X->{_path} = "$path.$f";
        my ($ok, $v) = xvalue($class, $row->{$f}, $X);
        if ($ok) { $o{$f} = $v } elsif ($class ne 'drop') { $X->{dropped}{"$path.$f"}++ }
    }
    return \%o;
}

# transform_row(row, X) -> the exported row, or undef (the whole row dropped and counted).
# X = {hash => sub, dropped => {}, headings => {}}.
sub transform_row {
    my ($row, $X) = @_;
    return undef unless ref $row eq 'HASH';
    my $ev = $row->{ev} // 'compaction';
    my $schema = watch::export_schema::schema();
    my $s = (!ref $ev && $ev =~ $RX{word}) ? $schema->{$ev} : undef;
    unless ($s) {
        $X->{dropped}{ (!ref $ev && $ev =~ $RX{word}) ? $ev : 'other' }++;
        return undef;
    }
    my $env = watch::export_schema::envelope();
    my %o;
    for my $f (sort keys %$row) {
        next if $f =~ /\A_/;
        my $class = exists $s->{$f} ? $s->{$f} : $env->{$f};
        if (!defined $class) { $X->{dropped}{"$ev.$f"}++; next }
        local $X->{_path} = "$ev.$f";
        my ($ok, $v) = xvalue($class, $row->{$f}, $X);
        if ($ok) { $o{$f} = $v } elsif ($class ne 'drop') { $X->{dropped}{"$ev.$f"}++ }
    }
    $o{ev} = $ev;
    return \%o;
}

# Spec headings -> fixed section ids, for the `heading` class (stable section
# ids; was `main:<n>`/`sub:<n>` by position, spec_version 1). From spec_version 2 the spec's
# `section_ids` gives each heading literal of sections_main / sections_subagent its id
# (`main:<role>` / `sub:<role>`). Keys: the literal, the slug a section_chars row holds
# (watch::shape::_slug, its producer) and the id itself. A heading without a well-formed id of its
# form, or a slug two headings share, maps to nothing (`other`). An older spec maps nothing, so a
# bundle's ids always follow the spec_version its manifest states.
sub heading_ids {
    my ($spec) = @_;
    my %h;
    my $t = ref $spec eq 'HASH' ? $spec->{section_ids} : undef;
    my $sv = _spec_version($spec);
    return \%h unless ref $t eq 'HASH' && defined $sv && $sv >= 2;
    require watch::shape;
    my %slug;
    for my $k (qw(sections_main sections_subagent)) {
        my $form = $k eq 'sections_main' ? 'main' : 'sub';
        for my $lit (watch::spec::list($spec, $k)) {
            next unless defined $lit && !ref $lit;
            my $id = $t->{$lit};
            next unless defined $id && !ref $id && $id =~ $watch::export_schema::SECTION_ID_RE && $id =~ /\A\Q$form\E:/;
            $h{$lit} = $h{$id} = $id;
            push @{ $slug{ watch::shape::_slug($lit) } }, $id;
        }
    }
    for my $s (keys %slug) {
        next if exists $h{$s};
        my %u = map { $_ => 1 } @{ $slug{$s} };
        $h{$s} = $slug{$s}[0] if keys %u == 1;
    }
    return \%h;
}

# --- inputs (B.1) -----------------------------------------------------------

# The sessions under <watch>: name -> {mod, classic, alerts, rollup, events}.
sub sessions {
    my ($w) = @_;
    my %s;
    for my $f (watch::io::list_dir($w)) {
        my $p = "$w/$f";
        next if -l $p;
        if (-f $p) {
            if ($f =~ /\A(.+)\.classic\.jsonl\z/) { $s{$1}{classic} = $p }
            elsif ($f =~ /\A(.+)\.alerts\.jsonl\z/) { $s{$1}{alerts} = $p }
            elsif ($f =~ /\A(.+)\.jsonl\z/) { $s{$1}{mod} = $p }
        } elsif (-d $p) {
            $s{$f}{rollup} = "$p/compactions.jsonl" if -f "$p/compactions.jsonl" && !-l "$p/compactions.jsonl";
            $s{$f}{events} = "$p/events" if -d "$p/events" && !-l "$p/events";
        }
    }
    delete $s{$_} for grep { $_ !~ $SID_RE || !%{ $s{$_} } } keys %s;
    return \%s;
}

sub _rows_of_session {
    my ($in) = @_;
    my @rows;
    for my $k (qw(mod classic alerts rollup)) {
        next unless $in->{$k};
        my $bad = 0;
        push @rows, @{ watch::io::read_jsonl($in->{$k}, \$bad) };
    }
    if ($in->{events}) {
        for my $f (watch::io::list_dir($in->{events})) {
            next unless $f =~ /\.json\z/ && -f "$in->{events}/$f" && !-l "$in->{events}/$f";
            my $r = watch::io::read_json_file("$in->{events}/$f");
            push @rows, $r if ref $r eq 'HASH';
        }
    }
    return \@rows;
}

# _since(arg, now) -> epoch | undef (no --since) | 'bad'. A YYYY-MM-DD date must be a real
# calendar date (PF-6): mktime would move 2026-02-31 to 3 March and 2026-13-01 into 2027.
sub _since {
    my ($arg, $now) = @_;
    return undef unless defined $arg;
    return $now - $1 * 86400 if $arg =~ /\A([1-9][0-9]{0,4})d\z/;
    if ($arg =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/) {
        my ($y, $m, $d) = (0 + $1, 0 + $2, 0 + $3);
        return 'bad' unless $m >= 1 && $m <= 12 && $d >= 1 && $d <= _month_days($y, $m);
        my $t = POSIX::mktime(0, 0, 0, $d, $m - 1, $y - 1900);
        return $t if defined $t;
    }
    return 'bad';
}

# _month_days(year, month 1-12) -> the month's days; February has 29 in a Gregorian leap year
sub _month_days {
    my ($y, $m) = @_;
    return 30 if $m == 4 || $m == 6 || $m == 9 || $m == 11;
    return 31 unless $m == 2;
    return ($y % 4 == 0 && ($y % 100 != 0 || $y % 400 == 0)) ? 29 : 28;
}

# --- identity list (B.3) ----------------------------------------------------

sub _git_remotes {
    my ($roots, $deadline) = @_;
    my @out;
    my $n = 0;
    for my $r (@$roots) {
        last if ++$n > $GIT_REPOS_MAX || watch::io::mono() >= $deadline;
        next unless -d $r;
        my $left = $deadline - watch::io::mono();
        last if $left <= 0;
        my $text = _run_capture([ 'git', '-C', $r, 'remote', '-v' ], $left);
        next unless defined $text;
        for my $l (split /\n/, $text) {
            my (undef, $url) = split /\s+/, $l;
            next unless defined $url;
            if ($url =~ m{\A[a-z+]+://(?:[^@/]+@)?([^/:]+)(?::[0-9]+)?/(.+?)(?:\.git)?/?\z}i
                || $url =~ m{\A(?:[^@/]+@)?([^/:]+):(.+?)(?:\.git)?/?\z}) {
                my ($host, $path) = ($1, $2);
                push @out, $host, $path;
                push @out, split(m{/}, $path);
            }
        }
    }
    return @out;
}

# Run argv (no shell) with a time limit; stdout, or undef on failure or timeout.
sub _run_capture {
    my ($argv, $secs) = @_;
    my $pid = open(my $fh, '-|');
    return undef unless defined $pid;
    if (!$pid) {
        open(STDERR, '>', '/dev/null');
        open(STDIN, '<', '/dev/null');
        exec { $argv->[0] } @$argv or POSIX::_exit(127);
    }
    my $out = '';
    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(($secs > 1 ? int($secs + 0.999) : 1));
        local $/;
        $out = <$fh> // '';
        alarm 0;
        1;
    };
    alarm 0;
    unless ($ok) { kill 'KILL', $pid }
    close $fh;
    return $ok && $? == 0 ? $out : undef;
}

sub identity_list {
    my ($ctx, %o) = @_;
    my @c;
    push @c, $ENV{HOME} if defined $ENV{HOME};
    my @pw = getpwuid($<);
    push @c, $pw[0], $pw[7], (defined $pw[6] ? split(/[ ,]+/, $pw[6]) : ());
    # the account name as the process sees it too (USER, LOGNAME), besides the user database
    push @c, grep { defined && length } @ENV{qw(USER LOGNAME)};
    my $host = (POSIX::uname())[1];
    if (defined $host) { push @c, $host; (my $short = $host) =~ s/\..*//s; push @c, $short }
    # B.3 names `hostname -s`: run it through PATH as written (2 s, as the git budget), besides uname
    my $hs = _run_capture([ 'hostname', '-s' ], $GIT_BUDGET_S);
    if (defined $hs) { $hs =~ s/\s+\z//; $hs =~ s/\A\s+//; push @c, $hs if length $hs && $hs !~ /\n/ }
    my @roots;
    my $rr = $ctx->{settings}{repo_roots_list} || [];
    for my $r (@$rr) { push @c, $r; (my $b = $r) =~ s{/+\z}{}; $b =~ s{.*/}{}s; push @c, $b; push @roots, $r }
    # Legacy root (0.1.2): the repository and bucket names of the pre-0.1.2 default root
    # ~/.claude/handoffs count too (rows written before the update name them); more names only
    # withhold more, so it is read whatever handoff_root says (the path is
    # watch::ctx's one constant, $LEGACY_ROOT).
    my $legacy = watch::ctx::legacy_root();
    for my $root (grep { defined && -d } ($ctx->{root}, (defined $legacy && $legacy ne ($ctx->{root} // '') ? $legacy : ()))) {
        for my $repo (watch::io::list_dir($root)) {
            next if $repo =~ /\A\./ || !-d "$root/$repo";
            push @c, $repo;
            for my $b (watch::io::list_dir("$root/$repo")) {
                next if $b =~ /\A\./ || !-d "$root/$repo/$b";
                push @c, $b;
            }
        }
    }
    push @c, @{ $o{extra} || [] };
    push @c, _git_remotes(\@roots, watch::io::mono() + $GIT_BUDGET_S) unless $o{no_git};
    my %seen;
    # The vocabulary exemption holds for the class-checked files only; free text (a summary
    # or a handoff) is scanned against every identity string (`all => 1`).
    my $vocab = $o{all} ? {} : vocabulary($ctx->{brand} // 'plugin', $ctx->{spec});
    return [ grep { length($_) >= $IDENTITY_MIN && !$vocab->{ lc $_ } && !$seen{ lc $_ }++ }
             map { my $x = $_; utf8::encode($x) if utf8::is_utf8($x); $x } grep { defined && !ref } @c ];
}

# --- summaries and handoffs -------------------------------------------------------

# The summaries a report may add when the user says yes in
# that run: the saved main compaction copies, <root>/<repo>/<bucket>/compact/*.md (not subagent
# or unattributed copies). The handoffs:
# published handoffs, a second and separate yes: the top-level <root>/<repo>/<bucket>/*.md files
# whose frontmatter says `kind: handoff` and `writer: handoff` (what `publish` writes), not an
# imported copy of a repository export (`imported_from`: a teammate's text) and not an export.
# Both: plain files (no link), modified at or after --since; a file over $SUMMARY_MAX_BYTES is
# not offered.
our $SUMMARY_MAX_BYTES = 1 << 20;

sub _bucket_dirs {
    my ($root) = @_;
    my @out;
    return @out unless defined $root && -d $root && !-l $root;
    for my $repo (watch::io::list_dir($root)) {
        next if $repo =~ /\A\./;
        my $rd = "$root/$repo";
        next if -l $rd || !-d $rd;
        for my $b (watch::io::list_dir($rd)) {
            next if $b =~ /\A\./ || -l "$rd/$b" || !-d "$rd/$b";
            push @out, "$rd/$b";
        }
    }
    return @out;
}

sub _md_files {
    my ($dir, $since) = @_;
    my @out;
    return @out if -l $dir || !-d $dir;
    for my $f (watch::io::list_dir($dir)) {
        next if $f =~ /\A\./ || $f !~ /\.md\z/;
        my $p = "$dir/$f";
        next if -l $p || !-f $p;
        my @st = stat $p;
        next if !@st || $st[7] > $SUMMARY_MAX_BYTES;
        next if defined $since && $st[9] < $since;
        push @out, { path => $p, bytes => $st[7], mtime => $st[9] };
    }
    return @out;
}

sub summary_files {
    my ($root, $since) = @_;
    return [ map { _md_files("$_/compact", $since) } _bucket_dirs($root) ];
}

# The frontmatter keys of a file the plugin wrote (`---` first line, `key: value` lines, `---`);
# undef when it has none.
sub _frontmatter {
    my ($path) = @_;
    my $head = watch::io::slurp($path, 16384);
    return undef unless defined $head && $head =~ /\A---\r?\n(.*?)\r?\n---\r?\n/s;
    my %fm;
    for my $l (split /\r?\n/, $1) {
        $fm{$1} = $2 if $l =~ /\A([A-Za-z0-9_]+):[ \t]*(.*?)[ \t]*\z/;
    }
    return \%fm;
}

sub handoff_files {
    my ($root, $since) = @_;
    my @out;
    for my $b (_bucket_dirs($root)) {
        for my $f (_md_files($b, $since)) {
            my $fm = _frontmatter($f->{path}) or next;
            next unless ($fm->{kind} // '') eq 'handoff' && ($fm->{writer} // '') eq 'handoff';
            next if length($fm->{imported_from} // '') || exists $fm->{export};
            push @out, $f;
        }
    }
    return \@out;
}

# The staged files of one kind: [zip name, bytes, source path], the name a keyed hash of the path.
my %ZIP_DIR = (summaries => [ 'summaries', 'summary' ], handoffs => [ 'handoffs', 'handoff' ]);
sub _content_entries {
    my ($kind, $files, $X) = @_;
    my ($dir, $salt) = @{ $ZIP_DIR{$kind} };
    my @e;
    for my $s (@$files) {
        my $data = watch::io::slurp($s->{path}, $SUMMARY_MAX_BYTES);
        next unless defined $data;
        push @e, [ "$dir/" . $X->{hash}->("$salt:" . $s->{path}) . '.md', $data, $s->{path} ];
    }
    return \@e;
}

# The bundle's own vocabulary. The transform
# can emit these words only as themselves (field names, enum values, event names, the brand,
# the fixed README words), so an identity string that is exactly one of them (case-folded) is
# no leak and is left off the list; otherwise a repo folder named like the plugin, `main` or
# `shadow` would withhold every file.
sub vocabulary {
    my ($brand, $spec) = @_;
    my %v;
    my $add = sub { for my $w (@_) { $v{ lc $w } = 1 if defined $w && !ref $w && length $w } };
    my $walk;
    $walk = sub {
        my ($c) = @_;
        return unless ref $c eq 'ARRAY';
        my ($k, @a) = @$c;
        if ($k eq 'enum') { $add->(@a) }
        elsif ($k eq 'pre') { $add->(@{ $a[0] }, @{ $a[1] }) }
        elsif ($k eq 'list' || $k eq 'counts') { $walk->($a[0]) }
        elsif ($k eq 'or') { $add->(@a[1 .. $#a]); $walk->($a[0]) }
        elsif ($k eq 'obj') { for my $f (keys %{ $a[0] }) { $add->($f); $walk->($a[0]{$f}) } }
    };
    my $s = watch::export_schema::schema();
    for my $ev (keys %$s) {
        $add->($ev);
        for my $f (keys %{ $s->{$ev} }) { $add->($f); $walk->($s->{$ev}{$f}) }
    }
    $add->(keys %{ watch::export_schema::envelope() });
    $add->($brand, @FIXED, 'rows', 'other', 'none', 'true', 'false', 'null', 'report');
    # The manifest, probes and sizes files' own keys and fixed values, and the system facts the
    # manifest states (operating system name and architecture, the runtime word).
    $add->(qw(schema plugin plugin_version created install_id cc_versions_seen os name release_major arch runtime
              window from to truncated since notice_shown watcher files bytes sha256 withheld dropped scan
              secret_rules_version identity_list_size export_schema ms file reason count rules identity secret
              shadow off perl available why no-export-classes export-view-failed
              smoke result check version smokeDue last_version canaries seat_state mod_alive yes no keyset_hashes
              triggers idle idle_source output_path_source runtime_trailer_active alert_delivery status-only
              system-message watch_error_classes PASS FAIL total kinds classic_stream alerts mod_stream rollup events
              dispatch pending bg handoff-turn checkpoint watch-cache offsets heal resume-claimed jobs fingerprints
              keyset notice reports .orphans key));
    # keep-warm.json's own keys and words (watch::report::keep_warm)
    $add->(qw(v gaps armed warmed refused open refused_by stops_by pings sent hit missed late failed ping_results
              handovers next_request miss not_seen miss_reasons gap_list gap_list_truncated outcome next handover));
    # config.json's own words: its fields, the export classes and path values,
    # the settings key names and the enum values core exports as themselves.
    $add->(qw(keys class value default clamped num bool enum path list unset custom custom-in-home unknown));
    {
        no warnings qw(once);
        $add->(map { ref $_ eq 'ARRAY' ? $_->[0] : () } @settings::KEYS);
        $add->(map { ref $_ eq 'ARRAY' ? @$_ : () } values %settings::ENUM);
    }
    my @u = POSIX::uname();
    $add->($u[0], $u[4]);
    $add->(_readme($brand) =~ /([A-Za-z][A-Za-z0-9_-]{3,})/g);
    # the manifest keys and README words of a bundle with summaries, handoffs or both
    for my $k (@watch::export_schema::CONTENT_KINDS) {
        $add->($watch::export_schema::CONTENT{$k}{flag}, $k, "${k}_n", "${k}_withheld");
    }
    for my $w ({ summaries => 1 }, { handoffs => 1 }, { summaries => 1, handoffs => 1 }) {
        $add->(_readme($brand, $w) =~ /([A-Za-z][A-Za-z0-9_-]{3,})/g);
    }
    # the manifest's spec_version and the fixed section ids the rows hold (each id
    # and its role word), so a repo or bucket folder named like a section is no identity hit
    $add->('spec_version', @watch::export_schema::SECTION_KEEP);
    $add->($_, (split /:/, $_, 2)[1]) for grep { $_ =~ $watch::export_schema::SECTION_ID_RE } values %{ heading_ids($spec) };
    return \%v;
}

sub identity_hits {
    my ($data, $list) = @_;
    my $lc = lc $data;
    my $n = 0;
    for my $s (@$list) { $n++ if index($lc, lc $s) >= 0 }
    return $n;
}

# --- secret scan (B.4) ------------------------------------------------------

# What the secret scan reads in a staged
# JSON file. Field names are the schema's fixed vocabulary (the WARN key-value rule hits the
# schema's own `"key":"soft_max"`), so a JSON file is scanned as its values, one per line
# (every string value and every object key below the top level, which are class-checked
# words). A file that does not parse is scanned as it is.
sub scan_text {
    my ($name, $data) = @_;
    return $data unless defined $name && $name =~ /\.jsonl?\z/;
    my @vals;
    my $walk;
    $walk = sub {
        my ($v, $depth) = @_;
        if (ref $v eq 'HASH') { for my $k (sort keys %$v) { push @vals, $k if $depth > 0; $walk->($v->{$k}, $depth + 1) } }
        elsif (ref $v eq 'ARRAY') { $walk->($_, $depth + 1) for @$v }
        elsif (defined $v && !ref $v) { push @vals, $v }
    };
    for my $line ($name =~ /\.jsonl\z/ ? split(/\n/, $data) : ($data)) {
        next unless $line =~ /\S/;
        my $j = eval { watch::json::decode($line) };
        return $data unless defined $j || !$@;
        $walk->($j, 0);
    }
    return join("\n", @vals) . "\n";
}

sub secret_hits {
    my ($ctx, $data) = @_;
    if (defined &secrets::scan) {
        my $h = eval { secrets::scan($data) };
        return [ map { $_->{rule} } @$h ] if ref $h eq 'ARRAY';
        return ['scan-error'];
    }
    # No core rule set loaded (secrets.pm reads the shared spec, not this one): the spec's rules,
    # compiled here and applied as secrets::_matches applies them (keep the two in step): the
    # value without its guard characters, min_entropy, and skip_paths (0.1.12, spec §19).
    my @ids;
    my $rules = $ctx->{spec}{secret_rules};
    $rules = $rules->{rules} if ref $rules eq 'HASH';
    for my $r (@{ ref $rules eq 'ARRAY' ? $rules : [] }) {
        next unless ref $r eq 'HASH' && defined $r->{re} && defined $r->{id};
        my $src = $r->{re};
        my $re = eval { qr/$src/ } or next;
        push @ids, $r->{id} if _fb_hit($data, { re => $re, min => $r->{min_entropy}, paths => $r->{skip_paths},
            lead => ($src =~ /\A\(\^\|\[\^/ ? 1 : 0), trail => ($src =~ /\(\$\|\[\^(?:\\.|[^\]\\])*\]\)\z/ ? 1 : 0) });
    }
    return \@ids;
}
sub _fb_hit {
    my ($t, $r) = @_;
    while ($t =~ /$r->{re}/g) {
        my ($s, $e) = ($-[0], $+[0]);
        if ($e == $s) { last unless defined pos($t); pos($t) = $e + 1; next }
        $s = $+[1] if $r->{lead} && defined $+[1];
        if ($r->{trail} && defined $-[$#+] && $-[$#+] > $s) { $e = $-[$#+]; pos($t) = $e }
        next if $e <= $s;
        my $m = substr($t, $s, $e - $s);
        next if defined $r->{min} && _fb_entropy($m) < $r->{min};
        next if $r->{paths} && _fb_path($t, $s, $e, $m, $r);
        return 1;
    }
    return 0;
}
sub _fb_path {
    my ($t, $s, $e, $m, $r) = @_;
    my @g = grep { length } split m{/}, $m;
    return 0 if @g < 3 || grep { _fb_hit($_, { %$r, paths => 0 }) } @g;
    my $from = $s > 1024 ? $s - 1024 : 0;
    my ($w) = substr($t, $from, $s - $from) =~ m{([^\s"'`<>()\[\]{},;:=|]*)\z};
    return 1 if substr($m, 0, 1) eq '/' || (($from == 0 || length($w) < $s - $from) && $w =~ m{\A(?:/|~/|\.\.?/)});
    return 1 if substr($t, $e, 10) =~ /\A\.[A-Za-z0-9]{1,8}(?![A-Za-z0-9])/;
    return !grep { !/\A(?:[A-Za-z]+[0-9]{0,3}|[0-9]{1,4})\z/ || _fb_entropy($_) >= 4.1 } @g;
}
sub _fb_entropy {
    my ($v) = @_;
    my ($n, $h, %c) = (length $v, 0);
    return 0 unless $n;
    $c{$_}++ for split //, $v;
    $h -= $_ / $n * log($_ / $n) / log(2) for values %c;
    return $h;
}

# --- the staged files -------------------------------------------------------

sub _readme {
    my ($brand, $with) = @_;
    $with = {} unless ref $with eq 'HASH';
    # A bundle the user chose to add summaries or handoffs to says so, and that
    # business content in them is not masked; without them the content-free promise stands as it
    # was.
    my ($s, $h) = ($with->{summaries} ? 1 : 0, $with->{handoffs} ? 1 : 0);
    my @never;
    if ($s || $h) {
        push @never, 'summaries/ holds compaction summaries you chose to add when you made this file.' if $s;
        push @never, 'handoffs/ holds handoffs you chose to add when you made this file.' if $h;
        my $dirs = join(' and ', ($s ? 'summaries/' : ()), ($h ? 'handoffs/' : ()));
        push @never,
            'They hold your sessions\' text. Secrets and your names, paths and hosts were scanned and any',
            'file with a hit was left out, but business content is not masked.',
            '',
            "Outside $dirs, never inside: conversation text, " . ($s ? '' : 'summaries, ') . ($h ? '' : 'handoffs, ')
                . 'commands, file or folder paths,',
            'repo, branch or bucket names, settings paths, secrets. Session, agent and task ids are replaced',
            'by keyed hashes that only your machine can make.';
    } else {
        @never = ('Never inside: conversation text, summaries, handoffs, commands, file or folder paths, repo,',
                  'branch or bucket names, settings paths, secrets. Session, agent and task ids are replaced by',
                  'keyed hashes that only your machine can make.');
    }
    return join("\n",
        "$brand report",
        '',
        'This zip holds the content-free logs of the ' . $brand . ' plugin, so that its developer can',
        'see how the plugin behaved on your machine. You made this file yourself; the plugin sent nothing.',
        '',
        'Inside: manifest.json (versions, operating system, file list with sha256 values), config.json',
        '(your settings as classes: numbers, on/off, default or changed, counts of list items),',
        'probes.json (capability checks already recorded), sizes.json (log sizes per file kind),',
        'keep-warm.json (keep-warm counts per idle gap: pings, results, stop reasons, the cache result',
        'of the next request) and rows/ (one file per session: event rows with ids, counts, enum values',
        'and times).',
        '',
        @never,
        '',
        'Times are included as they were logged (date, time and time zone offset), so rows can be',
        'lined up with release dates.',
        '',
        'To look inside: unzip -l <file>, or open the files in any text editor.',
        '');
}

sub _sizes {
    my ($w) = @_;
    my %k;
    my $walk;
    $walk = sub {
        my ($d, $depth) = @_;
        for my $e (watch::io::list_dir($d)) {
            my $p = "$d/$e";
            next if -l $p;
            if (-d $p) { $walk->($p, $depth + 1) if $depth < 6; next }
            next unless -f _;
            my $kind = _kind($p, $w);
            $k{$kind}{files}++;
            $k{$kind}{bytes} += -s $p;
        }
    };
    $walk->($w, 0) if -d $w;
    my ($tb, $tf) = (0, 0);
    for (values %k) { $tb += $_->{bytes}; $tf += $_->{files} }
    return { total => { bytes => $tb, files => $tf }, kinds => \%k };
}

sub _kind {
    my ($p, $w) = @_;
    (my $r = substr($p, length($w) + 1)) =~ s{\A/+}{};
    return 'classic_stream' if $r =~ m{\A[^/]+\.classic\.jsonl\z};
    return 'alerts' if $r =~ m{\A[^/]+\.alerts\.jsonl\z};
    return 'mod_stream' if $r =~ m{\A[^/]+\.jsonl\z};
    return 'rollup' if $r =~ m{\A[^/]+/compactions\.jsonl\z};
    return $1 if $r =~ m{\A[^/]+/(events|dispatch|pending|bg|handoff-turn|checkpoint|watch-cache|offsets|heal|resume-claimed)/};
    return 'jobs' if $r =~ m{\A[^/]+/jobs\.jsonl\z};
    return $1 if $r =~ m{\A(fingerprints|keyset|notice|reports|\.orphans)/};
    return 'version' if $r eq 'version.json';
    return 'key' if $r eq 'export-salt' || $r eq 'install-id';
    return 'other';
}

sub _probes {
    my ($ctx, $all) = @_;
    my $vj = watch::io::read_json_file("$ctx->{watch}/version.json");
    $vj = {} unless ref $vj eq 'HASH';
    my (%seat, %trig, %idle, %idle_src, %werr, %ks, %canary);
    my ($alive_y, $alive_n) = (0, 0);
    my $smoke;
    # the rollup rows joined with core's compaction_boundary rows by nonce (the idle facts are
    # settled there); idle is a JSON bool (1 or 0) or `unknown`
    my %bound;
    for my $r (@$all) {
        next unless ($r->{ev} // '') eq 'compaction_boundary' && defined $r->{nonce} && !ref $r->{nonce};
        $bound{ $r->{nonce} } //= $r;
    }
    require watch::rules;
    for my $r (@$all) {
        my $ev = $r->{ev} // 'compaction';
        if ($ev eq 'compaction') {
            my $b = (defined $r->{nonce} && !ref $r->{nonce}) ? $bound{ $r->{nonce} } : undef;
            my $j = $b ? watch::rules::join_row($r, $b) : $r;
            my $iv = ref $j->{idle} eq 'SCALAR' ? ${ $j->{idle} } : $j->{idle};
            $iv = ($iv eq '1' ? 'true' : $iv eq '0' ? 'false' : $iv) if defined $iv && !ref $iv;
            $seat{ _w($r->{seat_state}) }++;
            $trig{ _w($r->{trigger}) }++;
            $idle{ _w($iv) }++;
            $idle_src{ _w($j->{idle_source}) }++ if defined $j->{idle_source};
        } elsif ($ev eq 'watch_error') {
            $werr{ _w($r->{error_class}) }++;
        } elsif ($ev eq 'postcompact' || $ev eq 'precompact') {
            $ks{ $r->{keyset_hash} }++ if defined $r->{keyset_hash} && !ref $r->{keyset_hash} && $r->{keyset_hash} =~ /\A[0-9a-f]{8}\z/;
            if ($ev eq 'postcompact') {
                my $b = _bool($r->{mod_alive_this_turn});
                if (defined $b) { $$b ? $alive_y++ : $alive_n++ }
            }
        } elsif ($ev =~ /\A(?:version_change|keyset_change|trigger_unknown|order_anomaly)\z/) {
            $canary{$ev}++;
        } elsif ($ev eq 'smoke_pass' || $ev eq 'smoke_fail') {
            my $t = watch::io::parse_iso($r->{ts}) // 0;
            $smoke = { t => $t, result => ($ev eq 'smoke_pass' ? 'PASS' : 'FAIL'), check => $r->{check}, version => $r->{version} }
                if !$smoke || $t >= $smoke->{t};
        }
    }
    my $ver = sub { my $v = shift; return (defined $v && !ref $v && $v =~ /\A[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,6}\z/) ? $v : undef };
    return {
        smoke => $smoke ? { result => $smoke->{result}, check => (defined $smoke->{check} && $smoke->{check} =~ /\A[a-z0-9_-]{1,32}\z/i ? $smoke->{check} : undef),
                            version => $ver->($smoke->{version}) } : undef,
        smokeDue => $ver->($vj->{smokeDue}),
        last_version => $ver->($vj->{lastVersion}),
        canaries => \%canary,
        seat_state => \%seat,
        mod_alive => { yes => $alive_y, no => $alive_n },
        keyset_hashes => \%ks,
        triggers => \%trig,
        idle => \%idle,
        idle_source => \%idle_src,
        output_path_source => undef,
        runtime_trailer_active => undef,
        alert_delivery => $watch::alerts::DELIVERY,
        watch_error_classes => \%werr,
    };
}

sub _w { my $v = shift; return (defined $v && !ref $v && $v =~ /\A[a-z][a-z0-9_.:-]{0,31}\z/) ? $v : defined $v ? 'other' : 'none' }

# config.json. Core's settings::export_view([resolved]) returns an ordered
# object (jsonc::obj, a blessed array of key/value pairs; a plain hash is read too) of the
# exported values. The watcher wraps it as
# {available: true, keys: {<key>: {class, value, default, clamped}}}: `class` from
# %settings::EXPORT; `default` true when the value equals core's export of the key's default
# (export_view over the defaults resolve() would use); `clamped` true for a number the clamp
# moves (_clamped). Any failure exports nothing: {available: false, why}.
sub _config {
    my ($ctx) = @_;
    # settings.pm has no export classes yet: export nothing rather than guess.
    return { available => \0, why => 'no-export-classes' } unless defined &settings::export_view;
    my $r = eval {
        # `report` runs without rc::init (cmd/report.pl), so rc::settings() is empty there:
        # pass this call's resolved settings (the ones watch::ctx resolved) explicitly.
        my $rs = defined &rc::settings ? rc::settings() : undef;
        $rs = settings::resolve({}) if !(ref $rs eq 'HASH' && ref $rs->{values} eq 'HASH') && defined &settings::resolve;
        die "no resolved settings\n" unless ref $rs eq 'HASH' && ref $rs->{values} eq 'HASH';
        my $cur = _pairs(settings::export_view($rs));
        my %def = @{ _pairs(settings::export_view({ values => _default_values() })) };
        my (%v, @order);
        for (my $i = 0; $i < @$cur; $i += 2) {
            my $k = $cur->[$i];
            die "config key\n" unless defined $k && !ref $k && $k =~ /\A[a-z][a-z0-9_]{0,63}\z/;
            push @order, $k unless exists $v{$k};
            $v{$k} = _plain($cur->[ $i + 1 ]);
        }
        my $cl = _clamped($ctx, \%v);
        my %keys;
        for my $k (@order) {
            $keys{$k} = { class => (defined $settings::EXPORT{$k} ? $settings::EXPORT{$k} : 'unknown'), value => $v{$k},
                          default => ((exists $def{$k} && _same($v{$k}, _plain($def{$k}))) ? \1 : \0),
                          clamped => ($cl->{$k} ? \1 : \0) };
        }
        +{ available => \1, keys => \%keys };
    };
    return $r if ref $r eq 'HASH';
    return { available => \0, why => 'export-view-failed' };
}

sub _pairs {
    my ($v) = @_;
    return [@$v] if ref $v eq 'jsonc::Obj';
    return [ map { ($_ => $v->{$_}) } sort keys %$v ] if ref $v eq 'HASH';
    die "export view\n";
}

# An exported value as a plain JSON scalar: a jsonc bool becomes \1 or \0; a reference of any
# other kind is no exported value (fail closed).
sub _plain {
    my ($x) = @_;
    return $x unless ref $x;
    return ($$x ? \1 : \0) if ref $x eq 'jsonc::Bool' || ref $x eq 'SCALAR';
    die "config value\n";
}

sub _same {
    my ($x, $y) = @_;
    return !defined $y if !defined $x;
    return 0 unless defined $y;
    ($x, $y) = map { ref $_ ? ($$_ ? 1 : 0) : $_ } ($x, $y);
    my $num = qr/\A-?[0-9]+(?:\.[0-9]+)?\z/;
    return $x == $y if $x =~ $num && $y =~ $num;
    return "$x" eq "$y";
}

# The defaults resolve() uses: the manifest's userConfig default, else the @KEYS fallback,
# coerced the same way.
sub _default_values {
    no warnings qw(once);
    my $uc = defined &ctx::user_config ? (eval { ctx::user_config() } || {}) : {};
    $uc = {} unless ref $uc eq 'HASH';
    my %d;
    for my $k (@settings::KEYS) {
        next unless ref $k eq 'ARRAY';
        my ($key, undef, $fallback) = @$k;
        my $v = (ref $uc->{$key} eq 'HASH' && exists $uc->{$key}{default}) ? $uc->{$key}{default} : $fallback;
        if (defined &settings::_coerce) {
            my $c = eval { settings::_coerce($key, $v) };
            $v = $c if defined $c;
        }
        $d{$key} = $v;
    }
    return \%d;
}

# clamped_keys(resolved, spec) -> {key => 1} for the keys the clamp moves: _clamped over
# settings::export_view of those resolved settings, the flags the watcher exports as `clamped`.
# `settings show` (0.1.2 onboarding) reads them, so both name the same keys. Dies on a bad view.
sub clamped_keys {
    my ($rs, $spec) = @_;
    my $cur = _pairs(settings::export_view($rs));
    my %v;
    for (my $i = 0; $i < @$cur; $i += 2) { $v{ $cur->[$i] } = _plain($cur->[ $i + 1 ]) }
    return _clamped({ spec => $spec }, \%v);
}

# The number keys the clamp moves (the mod's config.ts): a value outside the
# manifest's min/max; a window below the window floor; handoff_turn_max_tokens outside its
# bounds; the soft max and target over what the clamp gives for the configured window
# (watch::rules::fallback_thresholds, the watcher's copy of that clamp).
sub _clamped {
    my ($ctx, $v) = @_;
    my %c;
    # a whole-number key rounded down first, as config.ts reads it (settings::whole)
    my $n = sub { my $x = $v->{ $_[0] }; return undef unless defined $x && !ref $x && $x =~ /\A-?[0-9]+(?:\.[0-9]+)?\z/;
                  return defined &settings::whole ? settings::whole($_[0], 0 + $x) : 0 + $x };
    for my $key (keys %$v) {
        next unless (defined $settings::EXPORT{$key} ? $settings::EXPORT{$key} : '') eq 'num' && defined &settings::limits;
        my $x = $n->($key);
        next unless defined $x;
        my ($lo, $hi) = eval { settings::limits($key) };
        $c{$key} = 1 if (defined $lo && $x < $lo) || (defined $hi && $x > $hi);
    }
    require watch::rules;
    my $K = watch::rules::clamp_constants($ctx->{spec});
    my $w = $n->('native_window_tokens');
    $c{native_window_tokens} = 1 if defined $w && $w > 0 && $w < $K->{window_floor};
    my $ht = $n->('handoff_turn_max_tokens');
    $c{handoff_turn_max_tokens} = 1 if defined $ht && ($ht < $K->{handoff_tokens_min} || $ht > $K->{handoff_tokens_max});
    my ($soft, $target) = ($n->('compact_soft_max_tokens'), $n->('compact_target_tokens'));
    if (defined $soft && defined $target) {
        my %s = map { ($_ => (ref $v->{$_} ? (${ $v->{$_} } ? 'true' : 'false') : $v->{$_})) } keys %$v;
        my $t = watch::rules::fallback_thresholds(\%s, $ctx->{spec});
        if ($t && !$t->{off}) {
            $c{compact_soft_max_tokens} = 1 if $t->{soft_max} < $soft;
            $c{compact_target_tokens} = 1 if $t->{target} < $target;
        }
    }
    return \%c;
}

# --- keys ---------------------------------------------------------------------

sub _random_bytes {
    my ($n) = @_;
    if (sysopen(my $fh, '/dev/urandom', O_RDONLY)) {
        my $b = '';
        my $got = sysread($fh, $b, $n);
        close $fh;
        return $b if defined $got && $got == $n;
    }
    die "report: no random source\n";
}

# The local salt and install id (O_EXCL, 0600). With $dry, nothing is created: an existing
# salt is read, else an ephemeral one is used; the install id is read or null.
sub keys_for {
    my ($w, $dry) = @_;
    my $sp = "$w/export-salt";
    my $ip = "$w/install-id";
    my $salt = -f $sp && !-l $sp ? watch::io::slurp($sp, 64) : undef;
    if (!defined $salt || length($salt) != 32) {
        if ($dry) { $salt = _random_bytes(32) }
        else {
            watch::io::excl_create($sp, _random_bytes(32));
            $salt = watch::io::slurp($sp, 64);
            die "report: salt\n" unless defined $salt && length($salt) == 32;
        }
    }
    my $id = -f $ip && !-l $ip ? watch::io::slurp($ip, 64) : undef;
    $id =~ s/\s+\z// if defined $id;
    if (!defined $id || $id !~ /\A[0-9a-f]{16}\z/) {
        if ($dry) { $id = undef }
        else {
            watch::io::excl_create($ip, unpack('H*', _random_bytes(8)) . "\n");
            ($id = watch::io::slurp($ip, 64) // '') =~ s/\s+\z//;
            die "report: install id\n" unless $id =~ /\A[0-9a-f]{16}\z/;
        }
    }
    return ($salt, $id);
}

# --- build --------------------------------------------------------------------

sub _canon { return watch::json::encode($_[0]) . "\n" }

sub _ts_date { my $t = shift; return defined $t ? watch::io::local_date($t) : undef }

# build(ctx, %o) -> {entries => [[name, bytes]], manifest, withheld, rows_n, sessions_n, from, to, truncated}
# %o: since (epoch), max_bytes, salt, install_id, identity (list), now; with --with-summaries
# also summaries (summary_files), with --with-handoffs handoffs (handoff_files), and with either
# identity_all (the list without the vocabulary exemption).
sub build {
    my ($ctx, %o) = @_;
    my $w = $ctx->{watch};
    my $brand = $ctx->{brand} // 'plugin';
    my $X = { hash => hasher($o{salt}, $ctx->{sha256}), dropped => {}, headings => heading_ids($ctx->{spec}) };
    for my $k (@watch::export_schema::CONTENT_KINDS) {
        $o{content}{$k} = _content_entries($k, $o{$k}, $X) if $o{$k};
    }
    my $S = -d $w ? sessions($w) : {};
    my (@all_raw, %per);
    my %cc;
    for my $sid (sort keys %$S) {
        my $rows = _rows_of_session($S->{$sid});
        push @all_raw, @$rows;
        my $h = $X->{hash}->($sid);
        for my $r (@$rows) {
            my $t = watch::io::parse_iso(ref $r->{ts} ? undef : $r->{ts});
            next if defined $o{since} && (!defined $t || $t < $o{since});
            my $x = transform_row($r, $X) or next;
            $cc{ $x->{cc_version} }++ if defined $x->{cc_version};
            push @{ $per{$h} }, [ $t // 0, $x ];
        }
    }
    my @flat = sort { $a->[1] <=> $b->[1] } map { my $h = $_; map { [ $h, $_->[0], $_->[1] ] } @{ $per{$h} } } keys %per;
    my $truncated = 0;
    my $res;
    my $cut = 0;
    while (1) {
        my @keep = @flat[$cut .. $#flat];
        $res = _assemble($ctx, \%o, $X, \@keep, \@all_raw, \%cc, $truncated, $brand);
        last if !defined $o{max_bytes} || length($res->{zip}) <= $o{max_bytes} || !@keep;
        $truncated = 1;
        my $step = int(@keep / 10) || 1;
        $cut += $step;
    }
    return $res;
}

sub _assemble {
    my ($ctx, $o, $X, $keep, $all_raw, $cc, $truncated, $brand) = @_;
    my %rows;
    my ($from, $to);
    for my $k (@$keep) {
        push @{ $rows{ $k->[0] } }, $k->[2];
        $from = $k->[1] if $k->[1] && (!defined $from || $k->[1] < $from);
        $to = $k->[1] if $k->[1] && (!defined $to || $k->[1] > $to);
    }
    my %with = map { ($_ => 1) } grep { $o->{content}{$_} } @watch::export_schema::CONTENT_KINDS;
    my @staged = (
        [ 'README.txt', _readme($brand, \%with) ],
        [ 'config.json', _canon(_config($ctx)) ],
        [ 'probes.json', _canon(_probes($ctx, $all_raw)) ],
        [ 'sizes.json', _canon(_sizes($ctx->{watch})) ],
        # 0.1.11: the keep-warm statistics, built from the rows this zip holds (watch::report::keep_warm)
        [ 'keep-warm.json', _canon(_keep_warm($keep)) ],
    );
    for my $h (sort keys %rows) {
        push @staged, [ "rows/$h.jsonl", join('', map { _canon($_) } @{ $rows{$h} }) ];
    }
    # Each summary and each handoff passes the same two scans; its identity scan uses
    # every identity string (identity_all), since it is free text. A file with any hit is withheld.
    for my $k (@watch::export_schema::CONTENT_KINDS) {
        push @staged, map { [ $_->[0], $_->[1] ] } @{ $o->{content}{$k} || [] };
    }
    my (@ok, @withheld);
    my $id_list = $o->{identity} || [];
    my $id_all = $o->{identity_all} || $id_list;
    for my $s (@staged) {
        my ($name, $data) = @$s;
        utf8::encode($data) if utf8::is_utf8($data);
        if (my $n = identity_hits($data, watch::export_schema::content_kind($name) ? $id_all : $id_list)) {
            push @withheld, { file => $name, reason => 'identity', count => $n };
            next;
        }
        my $sh = secret_hits($ctx, scan_text($name, $data));
        if (@$sh) {
            my %u;
            push @withheld, { file => $name, reason => 'secret', rules => [ grep { !$u{$_}++ } @$sh ] };
            next;
        }
        push @ok, [ $name, $data ];
    }
    my @u = POSIX::uname();
    (my $rel = $u[2] // '') =~ s/\A([0-9]+).*\z/$1/s;
    my %dropped = %{ $X->{dropped} };
    my $manifest = {
        schema => $brand . $SCHEMA_NAME_SUFFIX,
        plugin => $brand,
        plugin_version => $ctx->{plugin_version},
        created => _stamp($o->{now}),
        install_id => $o->{install_id},
        cc_versions_seen => [ sort keys %$cc ],
        os => { name => $u[0], release_major => $rel, arch => $u[4] },
        runtime => sprintf('perl %vd', $^V),
        window => { from => _ts_date($from), to => _ts_date($to), truncated => ($truncated ? \1 : \0),
                    since => (defined $o->{since} ? _ts_date($o->{since}) : undef) },
        notice_shown => (-e "$ctx->{watch}/notice/" . _notice_id($ctx) . ".shown" ? \1 : \0),
        watcher => $ctx->{settings}{watcher},
        files => [ map { { name => $_->[0], bytes => length($_->[1]), sha256 => _sha($ctx, $_->[1]) } } @ok ],
        withheld => \@withheld,
        dropped => \%dropped,
        scan => { secret_rules_version => (ref $ctx->{spec} eq 'HASH' ? $ctx->{spec}{spec_version} : undef),
                  identity_list_size => scalar(@$id_list) },
        export_schema => $watch::export_schema::VERSION,
        # the spec version the section ids follow (2 and up: fixed ids, heading_ids)
        spec_version => _spec_version($ctx->{spec}),
        ms => int((watch::io::mono() - ($o->{t0} // watch::io::mono())) * 1000),
        # only in a bundle the user added that kind to
        (map { my $k = $_;
               ($watch::export_schema::CONTENT{$k}{flag} => \1,
                "${k}_n" => scalar(grep { (watch::export_schema::content_kind($_->[0]) // '') eq $k } @ok),
                "${k}_withheld" => scalar(grep { (watch::export_schema::content_kind($_->{file}) // '') eq $k } @withheld))
             } grep { $with{$_} } @watch::export_schema::CONTENT_KINDS),
    };
    my $mtext = _canon($manifest);
    die "report: identity in the manifest\n" if identity_hits($mtext, $id_list);
    # U-06: the manifest is scanned last, so the user's secret rules get time of their own for it
    # (the files may have spent the budget); a rule that still could not finish fails the report
    # closed, under its own reason
    my $scan_m = sub { secret_hits($ctx, scan_text('manifest.json', $mtext)) };
    my $mh = defined &userre::reserve ? userre::reserve('manifest', $scan_m) : $scan_m->();
    my $tr = defined $secrets::TIMEOUT_RULE ? $secrets::TIMEOUT_RULE : 'regex-timeout';
    die "report: a secret_extra_rules pattern could not finish on the manifest (make the pattern simpler)\n"
        if @$mh && !grep { $_ ne $tr } @$mh;
    die "report: secret in the manifest\n" if @$mh;
    my @entries = grep { $_->[0] eq 'README.txt' } @ok;
    push @entries, [ 'manifest.json', $mtext ];
    push @entries, grep { $_->[0] ne 'README.txt' } @ok;
    my $zip = watch::bundle::zip(\@entries, $o->{now});
    return { zip => $zip, entries => \@entries, manifest => $manifest, withheld => \@withheld,
             rows_n => scalar(@$keep), sessions_n => scalar(keys %rows), from => $from, to => $to,
             truncated => $truncated, with => \%with,
             content_src => { map { ($_->[0] => $_->[2]) } map { @{ $o->{content}{$_} || [] } } @watch::export_schema::CONTENT_KINDS } };
}

# keep-warm.json: the keep-warm statistics of the exported rows (the transformed ones: counts,
# durations, enum reasons and versions only), by the same code as `watch report`'s section.
sub _keep_warm {
    my ($keep) = @_;
    my %s;
    push @{ $s{ $_->[0] } }, $_->[2] for @$keep;
    require watch::report;
    return watch::report::keep_warm(\%s);
}

# The spec's spec_version as a number, else undef (an older or missing spec).
sub _spec_version {
    my ($spec) = @_;
    my $v = ref $spec eq 'HASH' ? $spec->{spec_version} : undef;
    return (defined $v && !ref $v && $v =~ /\A[0-9]{1,4}\z/) ? 0 + $v : undef;
}

# The first-run notice marker id: the spec's `notice.id` (`watcher-1`), else that.
sub _notice_id {
    my ($ctx) = @_;
    my $n = ref $ctx->{spec} eq 'HASH' ? $ctx->{spec}{notice} : undef;
    my $id = ref $n eq 'HASH' ? $n->{id} : undef;
    return (defined $id && !ref $id && $id =~ /\A[a-z0-9-]{1,32}\z/) ? $id : 'watcher-1';
}

sub _sha {
    my ($ctx, $data) = @_;
    return watch::io::sha256_hex($data, $ctx);
}

sub _stamp {
    my ($t) = @_;
    my @l = localtime(int($t // time));
    return POSIX::strftime('%Y-%m-%d %H:%M', @l) . ' ' . _offset(int($t // time));
}

sub _offset {
    my ($t) = @_;
    my @l = localtime($t);
    my $off = watch::io::timegm(@l[0 .. 4], $l[5] + 1900) - $t;
    my $s = $off < 0 ? '-' : '+';
    $off = abs $off;
    return sprintf('%s%02d%02d', $s, int($off / 3600), int(($off % 3600) / 60));
}

# --- output folder (B.6) ---------------------------------------------------------

sub _in_git {
    my ($d) = @_;
    my $p = Cwd::abs_path($d) // $d;
    while (length $p) {
        return 1 if -e "$p/.git";
        last if $p eq '/';
        $p =~ s{/[^/]*\z}{};
        $p = '/' if $p eq '';
    }
    return 0;
}

sub out_dir {
    my ($ctx, $given) = @_;
    if (defined $given) {
        return (undef, 'not-writable') unless -d $given && -w $given;
        return (Cwd::abs_path($given) // $given);
    }
    my $dl = defined $ENV{HOME} ? "$ENV{HOME}/Downloads" : undef;
    return (Cwd::abs_path($dl) // $dl) if defined $dl && -d $dl && -w $dl && !-l $dl && !_in_git($dl);
    return ("$ctx->{watch}/reports", 'fallback');
}

# A path for the screen with the home folder as `~` ('?' when unknown).
sub util_abbrev {
    my ($p) = @_;
    return '?' unless defined $p;
    my $h = $ENV{HOME} // '';
    $h =~ s{/+\z}{};
    return $p if $h eq '';
    $p =~ s{\A\Q$h\E(?=/|\z)}{~};
    return $p;
}

sub _human {
    my ($n) = @_;
    return "$n B" if $n < 1024;
    return sprintf('%.1f KB', $n / 1024) if $n < 1024 * 1024;
    return sprintf('%.1f MB', $n / (1024 * 1024));
}

# --- the command ------------------------------------------------------------------

sub _usage {
    print STDERR "usage: report [--dry-run] [--since <N>d|<YYYY-MM-DD>] [--out DIR] [--max-mb N] [--with-summaries]\n"
               . "              [--with-handoffs]\n"
               . "       report verify --zip FILE\n";
    return 64;
}

# `summaries: <n> available (<KB>)` and `handoffs: <n> available (<KB>)`, the dry
# run's lines the report skill asks on (one yes per kind).
sub _available_line {
    my ($kind, $files) = @_;
    my $b = 0;
    $b += $_->{bytes} for @$files;
    return sprintf("%s: %d available (%d KB)\n", $kind, scalar @$files, int(($b + 1023) / 1024));
}

# The output word of one content file and its kind's closing line.
my %CONTENT_OUT = (summaries => [ 'SUMMARY', 'SUMMARIES' ], handoffs => [ 'HANDOFF', 'HANDOFFS' ]);

# cli(\@argv, \%ctx_seed) -> exit code; prints the B.7 lines.
sub cli {
    my ($argv, $seed) = @_;
    my @a = @$argv;
    return verify_cli(\@a, $seed) if @a && $a[0] eq 'verify';
    my %o = (max_mb => $MAX_MB_DEFAULT);
    while (@a) {
        my $x = shift @a;
        if ($x eq '--dry-run') { $o{dry} = 1 }
        elsif ($x eq '--since') { $o{since} = shift @a; return _usage() unless defined $o{since} }
        elsif ($x =~ /\A--since=(.+)\z/) { $o{since} = $1 }
        elsif ($x eq '--out') { $o{out} = shift @a; return _usage() unless defined $o{out} && length $o{out} }
        elsif ($x =~ /\A--out=(.+)\z/) { $o{out} = $1 }
        elsif ($x eq '--max-mb') { $o{max_mb} = shift @a; return _usage() unless defined $o{max_mb} && $o{max_mb} =~ /\A[1-9][0-9]{0,3}\z/ }
        elsif ($x =~ /\A--max-mb=([1-9][0-9]{0,3})\z/) { $o{max_mb} = $1 }
        # only on the command line, each after the user's own yes to that kind in this
        # run (the report skill); no setting turns either on
        elsif ($x eq '--with-summaries') { $o{summaries} = 1 }
        elsif ($x eq '--with-handoffs') { $o{handoffs} = 1 }
        else { return _usage() }
    }
    my $t0 = watch::io::mono();
    my $ctx = watch::ctx::init({ %{ $seed || {} }, sid => 'unknown' });
    my $since = _since($o{since}, $ctx->{now});
    return _usage() if defined $since && $since eq 'bad';
    # a real run writes the salt, the install id and report_withheld rows under the
    # watch dir; while it or the handoff root is refused, nothing runs (a dry run writes nothing)
    if (!$o{dry}) {
        if (my $refused = watch::ctx::refused($ctx)) { print "REFUSED: $refused\n"; return 3 }
    }
    my ($dir, $why) = out_dir($ctx, $o{out});
    if (!defined $dir) { print "REFUSED: output folder not writable\n"; return 73 }
    my ($salt, $iid) = keys_for($ctx->{watch}, $o{dry});
    my $rr = defined &settings::repo_roots ? eval { settings::repo_roots(settings::resolve({})) } : undef;
    $ctx->{settings}{repo_roots_list} = ref $rr eq 'HASH' ? $rr->{roots} : [];
    my $no_git = (($ENV{STORE_TEST_MODE} // '') eq '1' && ($ENV{STORE_TEST_NO_GIT} // '') eq '1');
    my $ids = identity_list($ctx, no_git => $no_git, extra => $seed->{identity_extra});
    my %avail = (summaries => summary_files($ctx->{root}, $since), handoffs => handoff_files($ctx->{root}, $since));
    my @kinds = grep { $o{$_} } @watch::export_schema::CONTENT_KINDS;
    my %with = map { ($_ => $avail{$_}) } @kinds;
    $with{identity_all} = identity_list($ctx, no_git => $no_git, extra => $seed->{identity_extra}, all => 1) if @kinds;
    my $res = build($ctx, since => $since, max_bytes => $o{max_mb} * 1024 * 1024, salt => $salt,
                    install_id => $iid, identity => $ids, now => $ctx->{now}, t0 => $t0, %with);
    my $stamp = POSIX::strftime('%Y-%m-%d_%H-%M-%S', localtime(int $ctx->{now}));
    my $name = sprintf('%s-report-%s-%s.zip', $ctx->{brand} // 'plugin', $stamp, substr($iid // 'dryrun00', 0, 8));
    my $path = "$dir/$name";
    unless ($o{dry}) {
        if (($why // '') eq 'fallback') { watch::io::mkdir_p($dir) or do { print "REFUSED: output folder not writable\n"; return 73 } }
        return 73 unless _write_new($path, $res->{zip});
        for my $wh (@{ $res->{withheld} }) {
            watch::ctx::log_row($ctx, 'report_withheld', { reason => $wh->{reason}, file_kind => _file_kind($wh->{file}) },
                                writer => 'helper', actor => 'unknown');
        }
    }
    my $n = scalar @{ $res->{entries} };
    my @rowfiles = grep { $_->[0] =~ m{\Arows/} } @{ $res->{entries} };
    my %cfiles;
    for my $e (@{ $res->{entries} }) {
        my $k = watch::export_schema::content_kind($e->[0]);
        push @{ $cfiles{$k} }, $e if defined $k;
    }
    my @fixed = grep { $_->[0] !~ m{\Arows/} && !defined watch::export_schema::content_kind($_->[0]) } @{ $res->{entries} };
    print 'REPORT ' . $path . ' ' . _human(length $res->{zip}) . ($o{dry} ? ' (dry run: nothing written)' : '') . "\n";
    printf "FILES %d: %s%s%s\n", $n, join(', ', map { $_->[0] } @fixed),
        (@rowfiles ? sprintf(', rows/ (%d sessions, %d rows, %s..%s)', scalar @rowfiles, $res->{rows_n},
                             _ts_date($res->{from}) // '?', _ts_date($res->{to}) // '?') : ''),
        join('', map { $cfiles{$_} ? sprintf(', %s/ (%d files)', $_, scalar @{ $cfiles{$_} }) : '' } @watch::export_schema::CONTENT_KINDS);
    print "TRUNCATED: over --max-mb, the newest rows are kept (from " . (_ts_date($res->{from}) // '?') . ")\n" if $res->{truncated};
    # The dry run says what could be added, per kind; a run with summaries or
    # handoffs lists each one (the source path is shown here, on your screen, never in the zip).
    if ($o{dry}) { print _available_line($_, $avail{$_}) for @watch::export_schema::CONTENT_KINDS }
    my $src = $res->{content_src} || {};
    for my $k (@watch::export_schema::CONTENT_KINDS) {
        for my $e (@{ $cfiles{$k} || [] }) {
            print "$CONTENT_OUT{$k}[0] $e->[0] " . _human(length $e->[1]) . ' from ' . util_abbrev($src->{ $e->[0] }) . "\n";
        }
    }
    for my $wh (@{ $res->{withheld} }) {
        my $s = defined watch::export_schema::content_kind($wh->{file});
        print "WITHHELD $wh->{file} ("
            . ($wh->{reason} eq 'identity' ? ($s ? 'identity: your names, paths or hosts' : 'identity; please tell the developer')
                                           : "secret: " . join(',', @{ $wh->{rules} || [] }))
            . ')' . ($s ? ' from ' . util_abbrev($src->{ $wh->{file} }) : '') . "\n";
    }
    my %w = %{ $res->{with} || {} };
    for my $k (grep { $w{$_} } @watch::export_schema::CONTENT_KINDS) {
        print "$CONTENT_OUT{$k}[1]: added at your request; secrets and your names, paths and hosts were scanned, but business content is not masked\n";
    }
    if (!$w{summaries} && !$w{handoffs}) {
        print "NOT INCLUDED: conversation text, summaries, handoffs, commands, file paths, repo and branch names, settings paths\n";
    } else {
        my @in = grep { $w{$_} } @watch::export_schema::CONTENT_KINDS;
        my @out = grep { !$w{$_} } @watch::export_schema::CONTENT_KINDS;
        print 'NOT INCLUDED: ' . join(', ', @out, 'settings paths') . '; outside ' . join(' and ', map { "$_/" } @in)
            . " also conversation text, commands, file paths, repo and branch names\n";
    }
    print "SEND: attach this file to a message to the developer. Nothing was uploaded.\n";
    unless ($o{dry}) {
        if (($^O // '') eq 'darwin') {
            print qq(REVEAL: ! open -R "$path"\n);
            print qq(COPY:   ! osascript -e 'set the clipboard to (POSIX file "$path")'\n);
        } else {
            print qq(REVEAL: ! xdg-open "$dir"\n);
        }
    }
    return 0;
}

sub _file_kind {
    my ($f) = @_;
    return 'rows' if $f =~ m{\Arows/};
    my $c = watch::export_schema::content_kind($f);
    return $c if defined $c;
    (my $k = $f) =~ s/\.[a-z]+\z//;
    return $k;
}

# _write_new(path, data [, clash => 1]) -> 1 when written; 0 when refused (the refusal printed).
# The name is taken by an exclusive create of the target itself (a name that exists, a dangling
# link too, is never written through or replaced), never by a check and then a write: two runs
# could pick one name. The data then goes to a temp file beside it, renamed over the claimed
# name, so a reader never sees part of the data; until the rename it sees an empty file there,
# and a run killed between the claim and the rename leaves that empty file. With clash => 1 a
# name that is taken gives -1 and prints nothing, so the caller can pick the next one; without it
# a taken name prints `REFUSED: output file exists` (the folder is fine, a file or link is already
# there), any other failure `REFUSED: output folder not writable`. On failure only this run's own
# files (the claimed name and the temp file, at their exact paths) are removed.
sub _write_new {
    my ($path, $data, %o) = @_;
    my $old = umask 077;
    my $claimed = sysopen(my $ch, $path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    my $taken = !$claimed && $!{EEXIST};
    umask $old;
    return -1 if $taken && $o{clash};
    if ($taken) { print "REFUSED: output file exists\n"; return 0 }
    unless ($claimed) { print "REFUSED: output folder not writable\n"; return 0 }
    close $ch;
    my $tmp = sprintf('%s.tmp-%d', $path, $$);
    $old = umask 077;
    my $ok = sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600);
    umask $old;
    if ($ok) {
        my $n = syswrite($fh, $data);
        my $closed = close $fh;
        if (defined $n && $n == length($data) && $closed && rename($tmp, $path)) { chmod 0600, $path; return 1 }
        unlink $tmp;
    }
    unlink $path;
    print "REFUSED: output folder not writable\n";
    return 0;
}

# --- verify --------------------------------------------------------------------------

our @PATTERN_CLASSES = (
    [ 'abs-path', qr{(?:/U[s]ers/|/h[o]me/|/private/|/var/folders/|[A-Za-z]:\\\\)} ],
    [ 'email', qr/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z0-9.-]+/ ],
    [ 'url', qr{[a-z][a-z0-9+.-]*://[^\s"/]+}i ],
);
my %NAME_OK = map { $_ => 1 } @FIXED;

# verify_zip(bytes, ctx) -> list of problems (empty: valid).
sub verify_zip {
    my ($z, $ctx) = @_;
    my @p;
    my $u = watch::bundle::unzip($z);
    return ("unreadable: $u->{error}") if $u->{error} && !$u->{entries};
    push @p, "unreadable: $u->{error}" if $u->{error};
    my %data;
    my %content;
    for my $e (@{ $u->{entries} || [] }) {
        my $n = $e->{name};
        my $k = watch::export_schema::content_kind($n);
        push @{ $content{$k} }, $n if defined $k;
        push @p, "name: $n" unless watch::bundle::safe_name($n) && ($NAME_OK{$n} || defined $k || $n =~ m{\Arows/[0-9a-f]{12}\.jsonl\z});
        push @p, "symlink: $n" if $e->{symlink};
        push @p, "encrypted: $n" if $e->{encrypted};
        push @p, "entry $n: $e->{error}" if $e->{error};
        push @p, "duplicate: $n" if exists $data{$n};
        $data{$n} = $e->{data} if defined $e->{data};
    }
    my $m = defined $data{'manifest.json'} ? eval { watch::json::decode($data{'manifest.json'}) } : undef;
    if (ref $m ne 'HASH') { push @p, 'manifest: missing or not JSON'; return @p }
    # summaries/ only with manifest with_summaries true, handoffs/ only with
    # with_handoffs true (each kind its own yes), and as many as <kind>_n says
    my %with;
    for my $k (@watch::export_schema::CONTENT_KINDS) {
        my $flag = $watch::export_schema::CONTENT{$k}{flag};
        my @have = @{ $content{$k} || [] };
        $with{$k} = watch::export_schema::content_allowed($m, $k);
        push @p, "$k without $flag: $_" for ($with{$k} ? () : @have);
        my $cnt = $m->{"${k}_n"};
        push @p, "manifest: ${k}_n" if $with{$k} && !(defined $cnt && !ref $cnt && $cnt =~ /\A[0-9]{1,6}\z/ && $cnt == @have);
    }
    push @p, _section_id_problems($m, \%data);
    push @p, 'manifest: schema' unless defined $m->{schema} && !ref $m->{schema} && $m->{schema} =~ /\A[a-z0-9][a-z0-9-]{0,40}-report\/1\z/
        && defined $m->{plugin} && $m->{schema} eq $m->{plugin} . $SCHEMA_NAME_SUFFIX;
    my %listed;
    for my $f (@{ ref $m->{files} eq 'ARRAY' ? $m->{files} : [] }) {
        next unless ref $f eq 'HASH' && defined $f->{name};
        $listed{ $f->{name} } = 1;
        if (!defined $data{ $f->{name} }) { push @p, "missing: $f->{name}"; next }
        my $sha = watch::io::sha256_hex($data{ $f->{name} }, $ctx);
        push @p, "sha256: $f->{name}" unless defined $sha && defined $f->{sha256} && $sha eq $f->{sha256};
        push @p, "bytes: $f->{name}" unless ($f->{bytes} // -1) == length $data{ $f->{name} };
    }
    for my $n (sort keys %data) {
        next if $n eq 'manifest.json' || $n eq 'README.txt';
        push @p, "not in manifest: $n" unless $listed{$n};
    }
    for my $n (sort keys %data) {
        my $d = $data{$n};
        # A summary or handoff the user added holds session text (URLs, paths); the secret scan
        # still applies.
        my $opted = $with{ watch::export_schema::content_kind($n) // '' };
        for my $c ($opted ? () : @PATTERN_CLASSES) { push @p, "pattern $c->[0]: $n" if $d =~ $c->[1] }
        my $sh = secret_hits($ctx, scan_text($n, $d));
        push @p, 'secret ' . join(',', @$sh) . ": $n" if @$sh;
    }
    return @p;
}

# The section ids in a bundle's rows follow its manifest's spec_version: none or 1,
# ids by position (`main:3`) or the older slugs, never a fixed id; 2 and up, fixed ids
# (`main:next-steps`) only. `preamble` and `other` are fine in both. A bundle never mixes the two.
sub _section_id_problems {
    my ($m, $data) = @_;
    my $sv = $m->{spec_version};
    my $fixed = !defined $sv ? 0
              : (!ref $sv && $sv =~ /\A[0-9]{1,4}\z/ && $sv >= 1) ? ($sv >= 2 ? 1 : 0) : undef;
    return ('manifest: spec_version') unless defined $fixed;
    my $hf = watch::export_schema::heading_fields();
    my %keep = map { $_ => 1 } @watch::export_schema::SECTION_KEEP;
    my @p;
    for my $n (sort grep { m{\Arows/} } keys %$data) {
        my $bad = 0;
        for my $line (split /\n/, $data->{$n}) {
            next unless $line =~ /\S/;
            my $r = eval { watch::json::decode($line) };
            next unless ref $r eq 'HASH' && defined $r->{ev} && !ref $r->{ev};
            for my $f (@{ $hf->{ $r->{ev} } || [] }) {
                my ($field, $how) = @$f;
                my $v = $r->{$field};
                my @ids = $how eq 'key' ? (ref $v eq 'HASH' ? keys %$v : ())
                        : ref $v eq 'ARRAY' ? @$v : (defined $v && !ref $v) ? ($v) : ();
                for my $id (grep { defined && !ref && !$keep{$_} } @ids) {
                    $bad = 1 if ($id =~ $watch::export_schema::SECTION_ID_RE ? 1 : 0) != $fixed;
                }
            }
        }
        push @p, "section ids: $n " . ($fixed ? 'holds an id that is not a fixed section id' : 'holds a fixed section id')
            . ' (manifest spec_version ' . ($sv // 'none') . ')' if $bad;
    }
    return @p;
}

sub verify_cli {
    my ($a, $seed) = @_;
    shift @$a;
    my $zip;
    while (@$a) {
        my $x = shift @$a;
        if ($x eq '--zip') { $zip = shift @$a }
        elsif ($x =~ /\A--zip=(.+)\z/) { $zip = $1 }
        else { return _usage() }
    }
    return _usage() unless defined $zip && length $zip;
    my $ctx = watch::ctx::init({ %{ $seed || {} }, sid => 'unknown' });
    my $z = -f $zip && !-l $zip ? watch::io::slurp($zip, 256 << 20) : undef;
    unless (defined $z) { print "VERIFY FAIL unreadable\n"; return 1 }
    my @p = verify_zip($z, $ctx);
    if (@p) { print "VERIFY FAIL $_\n" for @p; return 1 }
    print "VERIFY OK\n";
    return 0;
}

1;
