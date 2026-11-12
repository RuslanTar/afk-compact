package skills::export;
# lib/skills/export.pm: the portable export of a published handoff into the repository
# (repo mode only). Used by `publish` (last step, after the private
# handoff is written and read back) and by `project copy --from private`.
#   target   <toplevel>/<decl.root>/<topic>/<stem>.md: same stem and nonce as the private
#            file, <topic> = the private bucket's folder name
#   front    the spec's frontmatter_keys_export, in that order: bucket becomes <topic>;
#            previous_handoff the decl.root-relative path of the previous handoff's export
#            when one with the same nonce exists (else omitted); gsd repo-relative when it
#            lies under the toplevel (else omitted); export: repo. Machine-only and
#            private-chain keys are not in the list, so they never leave the machine.
#   body     the draft with @self@ = the export's toplevel-relative path, then the rewrite:
#            <toplevel real>/ and <toplevel given>/ -> relative, the toplevel alone -> `.`,
#            $HOME/ -> ~/. Marker and sentinel unchanged.
#   scan     the whole text again with every rule: a HARD hit refuses (`secret <ids>`),
#            and so does any WARN hit (`secret-warn`), because the text would reach git.
#   write    dirs 0700, file 0600, `.<stem>.md.tmp-<pid>` in the target dir, then a
#            no-replace link; an existing target with the same sha is `exists`, with
#            another sha `export-exists`; nothing is ever overwritten.
# The plugin never runs git add, commit or push: the export stays untracked.
use strict;
use warnings;
use utf8;
use File::Basename ();
use skills::util;
use skills::core;
use skills::spec;
use skills::store;

# plan(mode record, private handoff path) -> {dir, path, rel (to the toplevel), rel_root
# (to decl.root), topic, stem}
sub plan {
    my ($m, $private) = @_;
    my $topic = File::Basename::basename(skills::store::bucket_of($private));
    my $stem = skills::store::stem_of($private);
    my $dir = "$m->{root_path}/$topic";
    return { dir => $dir, path => "$dir/$stem.md", rel => "$m->{root_rel}/$topic/$stem.md",
             rel_root => "$topic/$stem.md", topic => $topic, stem => $stem };
}

# rewrite(text, mode record) -> text with toplevel paths relative and the home as ~/
sub rewrite {
    my ($t, $m) = @_;
    my %seen;
    my @tops = sort { length $b <=> length $a }
               grep { defined && $_ ne '' && !$seen{$_}++ } ($m->{toplevel}, skills::util::abs_path($m->{toplevel}));
    for my $top (@tops) {
        $t =~ s/(?<![\w.\/~-])\Q$top\E\///g;
        $t =~ s/(?<![\w.\/~-])\Q$top\E(?![\w.\/-])/./g;
    }
    my $home = skills::util::env('HOME') // '';
    $t =~ s/(?<![\w.\/~-])\Q$home\E\//~\//g if $home ne '';
    return $t;
}

# body(draft body without marker and sentinel, mode record, plan) -> the export body
sub body {
    my ($btxt, $m, $plan) = @_;
    (my $b = $btxt) =~ s/\@self\@/$plan->{rel}/g;
    return rewrite($b, $m);
}

# front(private frontmatter hash, mode record, plan) -> frontmatter text (with the --- lines)
sub front {
    my ($fm, $m, $plan) = @_;
    my $keys = skills::spec::frontmatter_keys('export');
    die "spec-missing frontmatter_keys_export\n" unless @$keys;
    my %x = %$fm;
    $x{bucket} = $plan->{topic};
    $x{previous_handoff} = previous_export($m, $fm->{previous_handoff});
    my $top = $m->{toplevel};
    $x{gsd} = (defined $fm->{gsd} && defined $top && index($fm->{gsd}, "$top/") == 0) ? substr($fm->{gsd}, length($top) + 1) : undef;
    $x{export} = skills::spec::get('export_value') // 'repo';
    return "---\n" . join('', map { "$_: $x{$_}\n" } grep { defined $x{$_} && $x{$_} ne '' } @$keys) . "---\n";
}

# The decl.root-relative path of the export of a private handoff, when that export exists
# and has the same nonce; else undef.
sub previous_export {
    my ($m, $prev) = @_;
    return undef unless defined $prev && $prev ne '' && -f $prev;
    my $pd = skills::store::read_doc($prev) or return undef;
    my $pp = plan($m, $prev);
    return undef unless -f $pp->{path} && !-l $pp->{path};
    my $xd = skills::store::read_doc($pp->{path}) or return undef;
    return (defined $pd->{fm}{nonce} && ($xd->{fm}{nonce} // '') eq $pd->{fm}{nonce}) ? $pp->{rel_root} : undef;
}

# scan(text) -> (undef) clean | ('secret', [ids]) | ('secret-warn', [ids])
sub scan {
    my ($text) = @_;
    my $hits = skills::core::secrets_scan($text);
    my %hard = map { $_->{rule} => 1 } grep { $_->{class} eq 'HARD' } @$hits;
    return ('secret', [ sort keys %hard ]) if %hard;
    my %warn = map { $_->{rule} => 1 } @$hits;
    return ('secret-warn', [ sort keys %warn ]) if %warn;
    return (undef, []);
}

# write(plan, text) -> exported | exists | export-exists | repo-root-symlink
sub write_export {
    my ($plan, $text) = @_;
    my $root = File::Basename::dirname($plan->{dir});
    return 'repo-root-symlink' if -l $plan->{dir} || -l $root;
    if (-e $plan->{path} || -l $plan->{path}) {
        return 'export-exists' if -l $plan->{path};
        my $old = skills::util::sha256_file($plan->{path}) // '';
        return $old eq skills::util::sha256_hex($text) ? 'exists' : 'export-exists';
    }
    skills::util::mkdir_p($plan->{dir});
    return 'repo-root-symlink' if -l $plan->{dir};
    my $tmp = "$plan->{dir}/.$plan->{stem}.md.tmp-$$";
    skills::util::write_excl($tmp, $text, 0600) or die "export tmp exists: $tmp\n";
    my $ok = link($tmp, $plan->{path});
    my $err = $!;
    unlink $tmp;
    if (!$ok) {
        die "export link $plan->{path}: $err\n" unless -e $plan->{path};
        my $old = skills::util::sha256_file($plan->{path}) // '';
        return $old eq skills::util::sha256_hex($text) ? 'exists' : 'export-exists';
    }
    chmod 0600, $plan->{path};
    return 'exported';
}

# export_one(mode => m, private => path, fm => {..}, body => draft body (no marker or
# sentinel, @self@ unfilled), marker, sentinel, dry => 1)
#   -> {result => exported|exists|would-export|refused, reason, rules, bytes, rel, path}
sub export_one {
    my (%a) = @_;
    my $m = $a{mode};
    my $plan = plan($m, $a{private});
    my %r = (rel => $plan->{rel}, path => $plan->{path}, rules => [], bytes => 0);
    my $text = front($a{fm}, $m, $plan) . $a{marker} . "\n" . body($a{body}, $m, $plan) . "\n" . $a{sentinel} . "\n";
    $r{bytes} = skills::util::blen($text);
    my ($why, $rules) = scan($text);
    if ($why) { @r{qw(result reason rules)} = ('refused', $why, $rules); return \%r }
    if ($a{dry}) {
        if (-e $plan->{path}) {
            my $same = (skills::util::sha256_file($plan->{path}) // '') eq skills::util::sha256_hex($text);
            @r{qw(result reason)} = $same ? ('exists', undef) : ('refused', 'export-exists');
        } else {
            $r{result} = 'would-export';
        }
        return \%r;
    }
    my $w = write_export($plan, $text);
    if ($w eq 'exported' || $w eq 'exists') { $r{result} = $w } else { @r{qw(result reason)} = ('refused', $w) }
    return \%r;
}

# split_doc(text of a published handoff) -> (frontmatter hash, body, marker, sentinel) or ()
sub split_doc {
    my ($text) = @_;
    my $d = skills::store::parse($text);
    return () unless $d->{ok};
    my @l = split /\n/, $d->{body}, -1;
    pop @l while @l && $l[-1] eq '';
    return () unless @l >= 2;
    my ($mre, $sre) = (skills::spec::marker_re(), skills::spec::sentinel_re());
    return () unless $mre && $sre && $l[0] =~ $mre && $l[-1] =~ $sre;
    my ($marker, $sentinel) = (shift @l, pop @l);
    return ($d->{fm}, join("\n", @l), $marker, $sentinel);
}

1;
