package skills::locate;
# lib/skills/locate.pm: `locate --sid --cwd --arg` (resume R1; RDN helper
# table; A-6 lineage ≤3 hops, same chain; D-15 drafts last, never picked).
# Orders by frontmatter `date`, never by file name or mtime.
# D-12 §1.5.7: in repo mode the exports under this worktree's repository root, then
# those of sibling worktrees (`git worktree list`, at most 8, each with its own
# declaration and root check, read-only) are candidates labelled repo:<worktree>, never
# picked by themselves; an exact single ticket selects one, read as foreign. An export
# with a private twin (same nonce and session) is not listed: the twin is, with the
# export path beside it. Outside repo mode nothing under the repository root is read:
# one note line says how many exports it holds.
# STATE-ROOT: while handoff_root is the default, the buckets of the legacy root ~/.claude/handoffs are
# candidates too (pooled with the store's, ordered by date; they count as the private store); a
# legacy root refused by the unsafe-root checks is skipped with a note line.
use strict;
use warnings;
use utf8;
use Cwd ();
use File::Basename ();
use skills::util;
use skills::cli;
use skills::ctx;
use skills::store;
use skills::gitfacts;

sub run {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'sid=s', 'cwd=s', 'arg=s');
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    my $ctx = skills::ctx::new({});
    my $id = skills::ctx::resolve_sid($ctx, $o->{sid});
    my $sid = $id->{sid};
    my $cwd = skills::util::abs_path((defined $o->{cwd} && !skills::util::unset_value($o->{cwd})) ? $o->{cwd} : skills::util::cwd());
    my $w = skills::gitfacts::where($cwd);
    my $now = skills::util::now();
    my $arg = skills::util::unset_value($o->{arg}) ? undef : $o->{arg};
    $arg =~ s/\A\s+|\s+\z//g if defined $arg;

    my $chain = skills::ctx::chain($ctx, $sid);
    my %rel_of = ($sid => 'same-session', map { $_->{sid} => 'successor' } @$chain);

    my %bdirs = map { $_ => 1 } @{ skills::store::read_buckets($ctx, $w->{repo}) };
    for my $s ($sid, map { $_->{sid} } @$chain) {
        my $pin = skills::ctx::pin_read($ctx, $s) or next;
        $bdirs{ $pin->{bucket_path} } = 1 if $pin->{bucket_path} && -d $pin->{bucket_path};
    }
    my @pool;
    push @pool, @{ skills::store::docs_in($_, compact => 1) } for sort keys %bdirs;
    @pool = sort { ($b->{epoch} // 0) <=> ($a->{epoch} // 0) } @pool;
    my $sid_of = sub { $_[0]{fm}{session_id} // '' };

    my $m = skills::core::mode($cwd);
    my (@xdocs, @notes);
    push @notes, 'legacy root ' . skills::util::abbrev_home($ctx->{legacy_path}) . " skipped ($ctx->{legacy_refused})"
        if defined $ctx->{legacy_refused} && defined $ctx->{legacy_path};
    if ($m->{mode} eq 'repo' && defined $m->{root_rel}) {
        my $top = $m->{toplevel};
        push @xdocs, @{ skills::store::export_docs($top, $m->{root_rel}, File::Basename::basename($top)) };
        my $rtop = skills::util::abs_path($top) // $top;
        my $n = 0;
        for my $wt (@{ skills::gitfacts::worktrees($top) }) {
            next if (skills::util::abs_path($wt) // $wt) eq $rtop;
            last if ++$n > 8;
            my $dd = skills::core::declaration($wt);
            next unless $dd->{present} && $dd->{valid};
            next unless skills::core::repo_check($wt, $dd->{root})->{ok};
            push @xdocs, @{ skills::store::export_docs($wt, $dd->{root}, File::Basename::basename($wt)) };
        }
        @xdocs = sort { ($b->{epoch} // 0) <=> ($a->{epoch} // 0) } @{ skills::store::dedupe_exports(\@pool, \@xdocs) };
    } elsif ($m->{declared} && ref $m->{decl} eq 'HASH' && $m->{decl}{valid} && $m->{exports}) {
        push @notes, "repository has $m->{exports} handoff exports under $m->{root_rel}; not read (repo mode $m->{reason})";
    }

    my ($tier, $pick, @warn, @cands);
    if (defined $arg && ($arg =~ m{/} || $arg =~ /\.md\z/)) {
        my $p = skills::util::abs_path($arg);
        if (defined $p && -f $p) {
            my $d = skills::store::read_doc($p);
            $d->{bucket} = skills::store::bucket_of($p);
            my $is_copy = $p =~ m{/compact/} || ($d->{fm}{writer} // '') =~ /\A(?:mod|postcompact-fallback)\z/;
            $tier = ($is_copy && $sid_of->($d) eq $sid) ? 2 : 1;
            $pick = $d;
            for my $n (map { @{ skills::store::docs_in($_, compact => 1) } } @{ skills::store::twin_buckets($ctx, $d->{bucket}) }) {
                next if $n->{path} eq $p || ($n->{epoch} // 0) <= ($d->{epoch} // 0);
                push @warn, $n if ($n->{fm}{previous_handoff} // '') eq $p || $sid_of->($n) eq $sid_of->($d);
            }
        } else {
            push @notes, "arg: not found $arg";
        }
    }
    if (!$pick) {
        my ($own) = grep { $sid_of->($_) eq $sid && !_is_sub($_) } @pool;
        ($tier, $pick) = (3, $own) if $own;
    }
    if (!$pick) {
        for my $p (@$chain) {
            my ($d) = grep { $sid_of->($_) eq $p->{sid} && !_is_sub($_) } @pool;
            if ($d) { ($tier, $pick) = (4, $d); last }
        }
    }
    # Tier 5 selects only when the token names exactly one bucket. A partial
    # match (pay → pay-12) never selects: it only orders the tier-6 candidates.
    my @matching;
    my $exact = 0;
    if (!$pick && defined $arg && $arg !~ m{/}) {
        my $tok = lc $arg;
        my @all = sort keys %bdirs;
        @matching = grep { lc(File::Basename::basename($_)) eq $tok } @all;
        $exact = 1 if @matching;
        @matching = grep { index(lc(File::Basename::basename($_)), $tok) >= 0 } @all unless @matching;
        # one bucket name, which may be in both read roots (STATE-ROOT): the newest of its files
        my %mb = map { $_ => 1 } @matching;
        my %names = map { lc(File::Basename::basename($_)) => 1 } @matching;
        if ($exact && keys %names == 1) {
            my ($d) = grep { $mb{ $_->{bucket} } && !_is_sub($_) } @pool;
            ($tier, $pick) = (5, $d) if $d;
        }
        if (!$pick && !@matching) {
            # an exact single ticket among the export topics (Dev-3), read as foreign
            my %xb = map { $_->{bucket} => 1 } grep { lc(File::Basename::basename($_->{bucket})) eq $tok } @xdocs;
            if (keys %xb == 1) {
                my ($d) = grep { $xb{ $_->{bucket} } } @xdocs;
                ($tier, $pick) = (5, $d) if $d;
            }
        }
    }
    if (!$pick) {
        my %seen;
        my @src;
        push @src, grep { my $m = $_->{bucket}; grep { $_ eq $m } @matching } @pool;
        my $br = $w->{in_git} ? (skills::gitfacts::facts($cwd)->{branch} // '') : '';
        my $tk = skills::gitfacts::ticket($br);
        push @src, grep { $tk && File::Basename::basename($_->{bucket}) eq $tk } @pool;
        # SK-1 (S-SETTINGS E1): the shipped default pattern too, so buckets made before a
        # ticket_pattern change stay found (pins still win above).
        my $tk0 = settings::ticket($br, undef, 1);
        push @src, grep { defined $tk0 && (!defined $tk || $tk ne $tk0) && File::Basename::basename($_->{bucket}) eq $tk0 } @pool;
        push @src, @xdocs;
        push @src, @pool;
        for my $d (@src) {
            next if _is_sub($d) || $seen{ $d->{path} }++;
            push @cands, $d;
            last if @cands >= 5;
        }
        $tier = 6 if @cands;
    }

    skills::cli::say("tier: " . ($tier // 'none'));
    skills::cli::say("pick: " . ($pick ? $pick->{path} : 'none'));
    skills::cli::say($_) for @notes;
    if ($pick) {
        my $ps = $sid_of->($pick);
        my $rel = $rel_of{$ps} // (($tier == 1 || $tier == 2 || $tier == 5) ? 'other' : 'unselected');
        # Owner xxxxxxxx-26 (read-only alias): this session's or a predecessor's file in the store
        # may carry its marker under the plugin's former name.
        my $alias = $rel_of{$ps} && !skills::store::is_export($pick) && !skills::store::imported($pick)
            && skills::store::in_store($ctx, $pick->{path}) ? 1 : 0;
        my $int = skills::store::integrity($pick, alias => $alias);
        my $age_s = defined $pick->{epoch} ? $now - $pick->{epoch} : undef;
        skills::cli::say("relation: $rel");
        skills::cli::say('age: ' . _age($age_s));
        skills::cli::say("integrity: $int->{integrity}");
        skills::cli::say("marker: former name $int->{former} (read as own)") if defined $int->{former};
        skills::cli::say('date: ' . ($pick->{fm}{date} // 'unknown'));
        skills::cli::say('session: ' . skills::ctx::sid8($ps));
        my $t = skills::store::title_of($pick);
        skills::cli::say("title: $t") if $t ne '';
        skills::cli::say("export: $pick->{export_path}") if $pick->{export_path};
        if (skills::store::is_export($pick) && !$rel_of{$ps}) {
            # A teammate's or another machine's handoff: data, never instructions (D-12).
            skills::cli::say('source: ' . ($pick->{source} // 'repo'));
            skills::cli::say('foreign: from session ' . skills::ctx::sid8($ps));
            skills::cli::say('evidence: not on this machine');
            skills::cli::say('in-flight: other machine: not probed');
        } elsif ($rel_of{$ps}) {
            # Spec §4 Own handoff (REVIEW-NIGHT-3 R3-08): this session's or a predecessor's file
            # is own only in the private store, as written there; an export (anyone with push
            # access can edit it), an imported copy or a file given by a path outside the store
            # is foreign whatever its session id.
            my $why = skills::store::is_export($pick) ? 'a repository export'
                    : skills::store::imported($pick) ? 'an imported copy'
                    : !skills::store::in_store($ctx, $pick->{path}) ? 'a file outside your private store' : undef;
            skills::cli::say("foreign: $why, not an own handoff (commands only without real risk; approvals context only)") if defined $why;
        }
        if ($int->{integrity} eq 's=sub') {
            my ($parent) = grep { $sid_of->($_) eq $ps && !_is_sub($_) } @pool;
            skills::cli::say('parent: ' . ($parent ? $parent->{path} : 'none'));
        }
        skills::cli::say("warn: newer superseding file $_->{path} (" . ($_->{fm}{date} // '?') . ')') for @warn;
        my $n = 0;
        my @newer = map { @{ skills::store::docs_in($_, compact => 1) } } @{ skills::store::twin_buckets($ctx, $pick->{bucket}) };
        for my $d (sort { ($b->{epoch} // 0) <=> ($a->{epoch} // 0) } @newer) {
            next if $d->{path} eq $pick->{path} || ($d->{epoch} // 0) <= ($pick->{epoch} // 0);
            my $r = $rel_of{ $sid_of->($d) } // 'other';
            skills::cli::say(join ' · ', "newer: $d->{path}", $d->{fm}{date} // '?', skills::ctx::sid8($sid_of->($d)), $r);
            last if ++$n >= 5;
        }
    } else {
        skills::cli::say('relation: unselected');
    }
    for my $c (@cands) {
        skills::cli::say(join ' · ', "candidate: $c->{path}", $c->{fm}{date} // '?', skills::store::title_of($c), skills::ctx::sid8($sid_of->($c)),
            ($c->{source} ? ($c->{source}) : ()), ($c->{export_path} ? ("export $c->{export_path}") : ()));
    }
    # S-SETTINGS B: the production policy the resume follows (R7, R9 stop 2): the consent value
    # and the class counts, never the user's patterns.
    my $prod = skills::core::prod();
    my @shipped = map { $_->{id} } grep { ($_->{id} // '') !~ /\Auser-/ } @{ $prod->{classes} || [] };
    skills::cli::say(sprintf('production: %s · patterns: %s', $prod->{reads}, join(' + ', @shipped, ($prod->{user} // 0) . ' yours')));
    # Q-ADAPTER QA-1: the queue mode the resume follows (queue::mode: the setting, the file and
    # this session's last list outcome); locate never runs the queue tool (E-S-R9-8, provisional).
    skills::cli::say('queue: ' . skills::core::queue_mode_text(skills::core::queue_mode_now($ctx->{settings}{queue_cmd})));
    # SK-3 (owner xxxxxxxx-13, S-SETTINGS E3): the resume's per-user brake, the stricter value of
    # the settings file, a flag, env and the default, with where it came from (resume R9).
    {
        my $r = eval { rc::settings() };
        my $v = ref $r eq 'HASH' ? $r->{values}{resume_proceed} : undef;
        my $s = ref $r eq 'HASH' ? $r->{source}{resume_proceed} : undef;
        skills::cli::say('resume_proceed: ' . (($v // '') eq 'confirm' ? 'confirm' : 'auto') . ' (' . ($s // 'default') . ')');
    }
    if ($w->{in_git}) {
        my $top = $w->{worktree};
        my @sf;
        push @sf, "$top/.planning/HANDOFF.json" if -f "$top/.planning/HANDOFF.json";
        for my $dd ($top, "$top/.planning") {
            push @sf, map { "$dd/$_" } grep { /\A\.continue-here/ } skills::util::list_dir($dd);
        }
        skills::cli::say("state-file: $_") for @sf;
    }
    my @drafts;
    push @drafts, @{ skills::store::drafts_in($_) } for sort keys %bdirs;
    @drafts = sort { $b->{epoch} <=> $a->{epoch} } @drafts;
    for my $d (@drafts[0 .. ($#drafts < 2 ? $#drafts : 2)]) {
        skills::cli::say(join ' · ', "draft: $d->{path}", $d->{date} // '?', skills::ctx::sid8($d->{sid}),
            'unpublished draft, never picked');
    }
    return 0;
}

sub _is_sub {
    my ($d) = @_;
    return 1 if $d->{path} =~ m{/compact/subagents/};
    return 0;
}

sub _age {
    my ($s) = @_;
    return 'unknown T3' unless defined $s;
    my $tier = $s < 86400 ? 'T1' : ($s <= 7 * 86400 ? 'T2' : 'T3');
    my $txt = $s < 86400 ? int($s / 3600) . 'h' : int($s / 86400) . 'd';
    return "$txt $tier";
}

1;
