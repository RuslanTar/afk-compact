# AT-WB-01, watcher half: every event type of the watcher's event list
# (the list below, as folded on 2026-10-22; `bg` is a sidecar file, never exported) and
# every `ev` the shipped code writes (found in the plugin source: rc::emit, log_row,
# log_event/ctx::log, the mod's log()) has an export-schema entry, and every class in the
# schema is one the transform knows. An `ev` not in the schema drops the whole row (counted). Every
# verdict of the spec is in the export enum, and the watcher's ok sets are the spec's ok_verdicts (0.1.3; read from
# the spec at run time since 0.1.4).
use Cwd ();
use File::Basename ();
my $plugin = Cwd::abs_path(File::Basename::dirname(__FILE__) . '/../../../../../plugin');
my @SPEC = qw(dispatch precompact compacted postcompact copy copy_attributed copy_attribution_ambiguous
              copy_attribution_failed stash_dropped stash_kept orphan_finished compaction_boundary resume_inject nudge
              continue compact_rejected session sweep stop_failure permission_denied handoff_publish config_note
              handoff_turn_open handoff_skipped handoff_turn_start handoff_turn_end handoff_limit handoff_race
              handoff_user_interjected handoff_mode idle_mismatch resume_remeasured resume_remeasure_failed submit_dropped
              queue_contract handoff_export relaunch_unmatched jobs_caller_refused queue_add resume_receipt heal alert
              watch_error compaction report_withheld);
my %CLASS = map { $_ => 1 } qw(num int bool nonce id6 hex8 hex12 stamp ts version model word rule window wsrc hash actor slot tool heading drop);
my %KIND = map { $_ => 1 } qw(enum pre list counts obj or);
sub _check {
    my ($c, $where, $bad) = @_;
    if (ref $c eq 'ARRAY') {
        my ($k, @a) = @$c;
        push @$bad, "$where: kind $k" unless $KIND{$k};
        if ($k eq 'list' || $k eq 'counts') { _check($a[0] // 'word', "$where\[]", $bad) }
        if ($k eq 'or') { _check($a[0], "$where|", $bad); push @$bad, "$where: or without words" unless @a > 1 }
        if ($k eq 'obj') { _check($a[0]{$_}, "$where.$_", $bad) for sort keys %{ $a[0] || {} } }
        return;
    }
    push @$bad, "$where: class $c" unless defined $c && $CLASS{$c};
}
{
    steps => [],
    expect => sub {
        my ($E) = @_;
        require watch::export_schema;
        my $s = watch::export_schema::schema();
        $E->ok((exists $s->{$_} ? 1 : 0), "event list ev $_ has a schema entry") for @SPEC;
        my %code;
        my @q = ("$plugin/helper", "$plugin/hooks");
        while (@q) {
            my $d = shift @q;
            for my $e (watch::io::list_dir($d)) {
                next if $e eq 'node_modules' || $e eq 'tests';
                my $p = "$d/$e";
                if (-d $p) { push @q, $p; next }
                next unless $e =~ /\.(?:pm|pl|ts)\z/ && $e !~ /\.gen\.ts\z/;
                my $src = watch::io::slurp($p) // '';
                $code{$1} = $p while $src =~ /rc::emit\(\s*'([a-z][a-z0-9_]+)'/g;
                $code{$1} = $p while $src =~ /log_row\(\s*\$[a-z]+,\s*'([a-z][a-z0-9_]+)'/g;
                $code{$1} = $p while $src =~ /(?:ctx::log|log_event)\(\s*\$[a-z]+,\s*'([a-z][a-z0-9_]+)'/g;
                $code{$1} = $p while $src =~ /\blog\(\s*[a-z]+,\s*[a-zA-Z.()]+,\s*'([a-z][a-z0-9_]+)'/g;
            }
        }
        $E->ok((keys(%code) > 60 ? 1 : 0), 'found ' . scalar(keys %code) . ' event names in the code');
        for my $ev (sort keys %code) {
            $E->ok((exists $s->{$ev} ? 1 : 0), "code ev $ev ($code{$ev}) has a schema entry");
        }
        my @bad;
        for my $ev (sort keys %$s) { _check($s->{$ev}{$_}, "$ev.$_", \@bad) for sort keys %{ $s->{$ev} } }
        _check(watch::export_schema::envelope()->{$_}, "envelope.$_", \@bad) for sort keys %{ watch::export_schema::envelope() };
        $E->ok(0, "unknown class: $_") for @bad;
        # An unknown ev drops the whole row and counts it.
        require watch::export;
        my $X = { hash => sub { 'h' x 12 }, dropped => {}, headings => {} };
        my $r = watch::export::transform_row({ ev => 'not_a_known_event', ts => '2026-10-21T14:00:00.000+03:00', x => 1 }, $X);
        $E->ok((!defined $r ? 1 : 0), 'an unknown ev drops the row');
        $E->is($X->{dropped}{not_a_known_event}, 1, 'and counts it');
        # 0.1.3 (ok-unclosed): every verdict of the spec is in the export enum (an unlisted one exports
        # as `other`), and the watcher's ok sets (rules.pm, report.pm) are the spec's ok_verdicts
        require JSON::PP;
        my $spec = eval { JSON::PP::decode_json(watch::io::slurp("$plugin/assets/handoff-spec.json") // '') } || {};
        my @sv = @{ $spec->{verdicts} || [] };
        $E->ok((@sv >= 7 ? 1 : 0), 'the spec lists ' . scalar(@sv) . ' verdicts');
        my (undef, @enum) = @{ $s->{verdict}{verdict} || [] };
        my %en = map { $_ => 1 } @enum;
        $E->ok(($en{$_} ? 1 : 0), "spec verdict $_ is in the export enum") for @sv;
        my $okv = join ' ', sort @{ $spec->{ok_verdicts} || [] };
        # 0.1.4 (T-7): rules.pm and report.pm read the ok set from the spec at run time
        # (watch::spec::ok_verdicts); its fallback list is the spec's too, and neither hard-codes one
        require watch::spec;
        $E->is(join(' ', sort keys %{ watch::spec::ok_verdicts($spec) }), $okv, "watch::spec::ok_verdicts reads the spec's ok_verdicts");
        $E->is(join(' ', sort @watch::spec::OK_VERDICTS), $okv, "watch::spec's fallback list is the spec's ok_verdicts");
        $E->is(join(' ', sort keys %{ watch::spec::ok_verdicts({}) }), $okv, 'a spec without the list falls back to it');
        $E->is(join(' ', sort keys %{ watch::spec::ok_verdicts({ ok_verdicts => ['ok'] }) }), 'ok', "another spec's list is the one read");
        for my $m (qw(rules report)) {
            my $src = watch::io::slurp("$plugin/helper/lib/watch/$m.pm") // '';
            $E->ok(($src !~ /%OKV\b/ && $src =~ /watch::spec::ok_verdicts\(/ ? 1 : 0), "watch/$m.pm reads the ok set from the spec");
        }
    },
};
