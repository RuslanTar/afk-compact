package skills::project_cmd;
# lib/skills/project_cmd.pm: `project status|init|copy`. The consent mod command is
# not built, so these are
# helper commands only, and none of them writes consent: acceptance (repo_roots) stays a
# person's gesture through /config or a hand edit of the settings file.
#   status --cwd D [--json]   the mode line (+ how to accept, ignored, drift, exports);
#                             --json {mode, reason, toplevel, main_checkout,
#                             decl {present, valid, root}, accepted, ignored, exports}
#   init --cwd D              the declaration, <root>/README.md and <root>/.gitignore, each
#                             by exclusive create and only under a root that passes
#                             repo_check; prints created|exists <path> per file; an existing
#                             file is never rewritten (drift is reported, not fixed); row
#                             project_init. Nothing is committed.
#   copy --from private|repo (--ticket T | --all) [--apply] [--cwd D]
#                             copy, never move (repo mode only). Default: a read-only dry
#                             run that writes nothing, not even a row. private:
#                             each private handoff of this repository's buckets through the
#                             publish export pipeline (rewrite, scan, no-replace write).
#                             repo: each export with no private twin into the private
#                             bucket, frontmatter `imported_from: repo:<rel path>` (read as
#                             foreign, never the carry base). Per file would-export |
#                             exported | would-import | imported | exists | skip <reason>,
#                             then TOTAL; row project_copy (with --apply).
# Paths printed are relative to the worktree's toplevel for repository files.
use strict;
use warnings;
use utf8;
use File::Basename ();
use Cwd ();
use skills::util;
use skills::cli;
use skills::ctx;
use skills::core;
use skills::store;
use skills::export;
use skills::gitfacts;

my $README = <<'EOT';
# Handoff exports

This folder holds portable exports of published session handoffs. The handoff plugin
writes one here when this repository is in repo mode: it is declared in
`.claude/handoffs.json` and accepted by the person in their own settings.

- Only reviewed, secret-scanned handoffs belong here. The plugin writes each export
  once, never overwrites one and never commits: review an export, then commit it
  yourself.
- Drafts, compaction copies, evidence, restart recipes, logs and locks stay in each
  person's private store and are never written here.
- Each person's own resume reads their private copy; an export read here is treated as
  another person's handoff: its approvals do not carry and its pids are not probed.
EOT

sub run {
    my ($argv) = @_;
    my $sub = shift @$argv // '';
    return status($argv) if $sub eq 'status';
    return init($argv) if $sub eq 'init';
    return copy($argv) if $sub eq 'copy';
    die skills::cli::usage('project status|init|copy');
}

sub _cwd {
    my ($o) = @_;
    my $c = (defined $o->{cwd} && $o->{cwd} ne '') ? $o->{cwd} : skills::util::cwd();
    die skills::cli::usage("--cwd $c is not a directory") unless -d $c;
    return skills::util::abs_path($c);
}

sub _accept_line {
    my ($m) = @_;
    my $mc = $m->{main_checkout} // $m->{toplevel} // 'this repository';
    return "accept: add $mc to repo_roots in /config (nothing here writes it)";
}

# The handoff-root mode lines of /status.
sub mode_lines {
    my ($m) = @_;
    my @l = ("handoff mode: $m->{mode} ($m->{reason})");
    push @l, _accept_line($m) if ($m->{reason} // '') eq 'not-accepted';
    push @l, 'exports here are git-ignored; they will not be committed' if $m->{ignored};
    push @l, "repo_gitignore_drift: $m->{root_rel}/.gitignore lacks generated lines; it is never edited" if $m->{gitignore_drift};
    push @l, "exports: $m->{exports} under $m->{root_rel}" if defined $m->{root_rel};
    return @l;
}

sub status {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'cwd=s', 'json');
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    my $cwd = _cwd($o);
    skills::ctx::new({});    # the run context: the settings repo_roots is read from
    my $m = skills::core::mode($cwd);
    if ($o->{json}) {
        my $d = $m->{decl} || { present => 0 };
        my $b = sub { $_[0] ? skills::util::json_true() : skills::util::json_false() };
        skills::cli::say(skills::util::json_encode({
            mode => $m->{mode}, reason => $m->{reason}, toplevel => $m->{toplevel}, main_checkout => $m->{main_checkout},
            decl => { present => $b->($d->{present}), valid => $b->($d->{valid}), root => $d->{root} },
            accepted => $b->($m->{accepted}), ignored => $b->($m->{ignored}), exports => 0 + ($m->{exports} // 0),
        }));
        return 0;
    }
    skills::cli::say($_) for mode_lines($m);
    return 0;
}

sub init {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'cwd=s');
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    my $cwd = _cwd($o);
    my $ctx = skills::ctx::new({});
    my $row = { result => undef, created => [], exists => [] };
    my $refuse = sub { $row->{result} = "REFUSED:$_[0]"; $ctx->log('project_init', $row); die skills::cli::refuse($_[0]) };
    my $w = skills::gitfacts::where($cwd);
    $refuse->('not-in-git') unless $w->{in_git} && defined $w->{worktree};
    my $top = $w->{worktree};
    my $d = skills::core::declaration($top);
    $refuse->('repo-decl-invalid') if $d->{present} && !$d->{valid};
    my $root = $d->{present} ? $d->{root} : skills::core::default_root();
    $row->{root} = $root;
    my $c = skills::core::repo_check($top, $root);
    $refuse->($c->{reason} // 'repo-root-unchecked') unless $c->{ok};
    my $decl = skills::core::decl_name();
    # The declaration as written (valid_root: no character needs escaping).
    my $dtext = qq({"version": 1, "mode": "repo", "root": "$root"}\n);
    for my $f ([$decl, $dtext], ["$root/README.md", $README], ["$root/.gitignore", skills::core::gitignore_text()]) {
        my ($rel, $text) = @$f;
        my $abs = "$top/$rel";
        skills::util::mkdir_p(File::Basename::dirname($abs));
        my $made = (-e $abs || -l $abs) ? 0 : skills::util::write_excl($abs, $text, 0600);
        push @{ $row->{ $made ? 'created' : 'exists' } }, $rel;
        skills::cli::say(($made ? 'created ' : 'exists ') . $rel);
    }
    $row->{result} = @{ $row->{created} } ? 'created' : 'exists';
    $ctx->log('project_init', $row);
    my $m = skills::core::mode($cwd);
    skills::cli::say($_) for mode_lines($m);
    skills::cli::say("nothing is committed: review and commit $decl, $root/README.md and $root/.gitignore yourself");
    return 0;
}

sub copy {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'from=s', 'ticket=s', 'all', 'apply', 'cwd=s');
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    die skills::cli::usage('--from private|repo') unless defined $o->{from} && $o->{from} =~ /\A(?:private|repo)\z/;
    die skills::cli::usage('--ticket T or --all, not both') if !!$o->{all} == !!(defined $o->{ticket});
    die skills::cli::usage('--ticket T') if defined $o->{ticket} && $o->{ticket} !~ /\A[A-Za-z0-9._-]{1,64}\z/;
    my $cwd = _cwd($o);
    my $ctx = skills::ctx::new({});
    my $m = skills::core::mode($cwd);
    die skills::cli::refuse("not-repo-mode $m->{reason}") unless $m->{mode} eq 'repo' && defined $m->{root_path};
    my $w = skills::gitfacts::where($cwd);
    my $apply = $o->{apply} ? 1 : 0;
    my $want = sub {
        my ($d) = @_;
        return 1 if $o->{all};
        my $topic = File::Basename::basename(skills::store::bucket_of($d->{path}));
        return (($d->{fm}{ticket} // '') eq $o->{ticket} || $topic eq $o->{ticket}) ? 1 : 0;
    };
    # Handoffs of this repository's private buckets; an imported copy keeps the export's
    # frontmatter (export: repo) and is a twin, but never exported again.
    my @all = grep { skills::store::is_handoff($_) && !$_->{is_copy} }
              map { @{ skills::store::docs_in($_) } } @{ skills::store::buckets($ctx->{root}, $w->{repo}) };
    my @private = grep { !skills::store::is_export($_) } @all;
    my %n;
    my $out = sub { my ($what, @rest) = @_; (my $k = $what) =~ s/\s.*//; $n{$k}++; skills::cli::say(join ' ', $what, @rest) };
    if ($o->{from} eq 'private') {
        for my $d (sort { $a->{path} cmp $b->{path} } grep { $want->($_) } @private) {
            if (skills::store::imported($d)) { $out->('skip imported', $d->{path}); next }
            my ($fm, $body, $marker, $sentinel) = skills::export::split_doc($d->{text});
            if (!defined $fm) { $out->('skip unshaped', $d->{path}); next }
            # The published body holds its own path for @self@; the export gets its rel path.
            $body =~ s/\Q$d->{path}\E/\@self\@/g;
            my $x = skills::export::export_one(mode => $m, private => $d->{path}, fm => $fm, body => $body,
                                               marker => $marker, sentinel => $sentinel, dry => !$apply);
            if ($x->{result} eq 'refused') {
                my $why = $x->{reason} // 'unknown';
                $out->("skip $why", $d->{path}, ($why =~ /\Asecret/ && @{ $x->{rules} || [] } ? '(rules ' . join(',', @{ $x->{rules} }) . ')' : ()));
            } else {
                $out->($x->{result}, $d->{path}, '->', $x->{rel});
            }
        }
    } else {
        my %twin = map { (join("\t", $_->{fm}{nonce} // '', $_->{fm}{session_id} // '') => $_) } grep { $_->{fm}{nonce} } @all;
        my $top = $m->{toplevel};
        for my $x (sort { $a->{path} cmp $b->{path} } grep { $want->($_) } @{ skills::store::export_docs($top, $m->{root_rel}, '') }) {
            my $rel = substr($x->{path}, length($top) + 1);
            if ($twin{ join("\t", $x->{fm}{nonce} // '', $x->{fm}{session_id} // '') }) { $out->('exists', $rel, '(private twin)'); next }
            my $topic = File::Basename::basename(skills::store::bucket_of($x->{path}));
            my $dest = "$ctx->{root}/$w->{repo}/$topic/" . File::Basename::basename($x->{path});
            my $text = _imported_text($x->{text}, "repo:$rel");
            if (!defined $text) { $out->('skip unshaped', $rel); next }
            # Repository text is untrusted; a HARD secret hit is never
            # copied into the private store (as publish refuses one). WARN hits import.
            my ($why, $rules) = skills::export::scan($text);
            if (($why // '') eq 'secret') { $out->('skip secret', $rel, '(rules ' . join(',', @$rules) . ')'); next }
            if (-e $dest || -l $dest) {
                my $same = !-l $dest && (skills::util::sha256_file($dest) // '') eq skills::util::sha256_hex($text);
                $out->($same ? ('exists', $rel, '->', $dest) : ('skip private-exists', $rel, '->', $dest));
                next;
            }
            if (!$apply) { $out->('would-import', $rel, '->', $dest); next }
            skills::util::mkdir_p(File::Basename::dirname($dest));
            my $made = skills::util::write_excl($dest, $text, 0600);
            $out->($made ? 'imported' : 'skip private-exists', $rel, '->', $dest);
        }
    }
    my @order = qw(would-export exported would-import imported exists skip);
    my $total = 0;
    $total += $_ for values %n;
    skills::cli::say("TOTAL $total" . join('', map { " · $_ $n{$_}" } grep { $n{$_} } @order) . ($apply ? '' : ' (dry run; nothing written)'));
    $ctx->log('project_copy', { from => $o->{from}, ticket => $o->{ticket}, apply => \1, counts => { map { $_ => 0 + ($n{$_} // 0) } @order } })
        if $apply;
    return 0;
}

# The export's text with `imported_from: <src>` added at the end of its frontmatter, or
# undef when it has none.
sub _imported_text {
    my ($t, $src) = @_;
    return undef unless $t =~ /\A---\n(.*?\n)?---\n/s;
    my $fm = $1 // '';
    return undef if $fm =~ /^imported_from:/m;
    my $len = length("---\n" . $fm);
    return substr($t, 0, $len) . "imported_from: $src\n" . substr($t, $len);
}

1;
