# AT-WB-04b (0.1.12): the report's own secret scan, used when the core rule set is not loaded
# (watch::export::secret_hits without secrets.pm, as in this driver), applies the shipped spec's
# rules as the core scan does: min_entropy and skip_paths. With the shipped secret_rules, file
# paths (a macOS temp folder, a Windows temp folder and its Git Bash form, long project paths,
# relative in-repo paths with an extension or word-like parts) hit neither cloud-key-bare nor
# high-entropy, while base64 values that start with `/`, hold two `/`, sit as one path part, or
# read as words with a part over the entropy bound still hit. Values are joined at run time.
use Cwd ();
use File::Basename ();
my $plugin = Cwd::abs_path(File::Basename::dirname(__FILE__) . '/../../../../../plugin');
my @paths = (
    '- Volatile: /var/folders/k7/m2xq9vbn4w1c8rt5yz3hp0d6s0000gn/T/x4-build.Q7RkP2/out.log',
    '- the Windows run wrote C:/Users/Name/AppData/Local/Temp/tmpab12cd/out.log',
    '- Git Bash shows it as /c/Users/Name/AppData/Local/Temp/tmp1a2b3c/out.log',
    '- the client tree: /Volumes/Work2/ClientProjects/AcmePayments/src/Ledger/Reconcile4/Batch.kt',
    '- the plugin file: /Users/Name/Projects/afk-compact/plugin/helper/lib/Skills3/Export.pm',
    '- the job: ~/Projects/AcmeCorp9/Payments-Gateway/src/main/Kotlin/Reconcile7/Job.kt',
    '- the export job: `src/main/Kotlin/LedgerReconciliation7/ExportJob.kt`',
    '- templates: app/Services/Billing2/InvoiceRenderer/Templates',
);
my %secrets = (
    'starts with /'      => '/Hnkmd5KeYxJ9qlUCS1k2m' . 'UlB+Q8HOuF+o5CEzZv',
    'two / inside'       => 'BoRNm5PS36xO/WbsBlcGb' . '+Ehe+G/W3Rj9x2LsD34',
    'one path part'      => '/srv/cache/hVnYiKY6ILC' . 'Sr2sRF63IPiqcgf3wjUz' . 'hiu02YAtZygXt/blob',
    'word-like, high H'  => 'YfQzgKSJesCQi62/Iq/' . 'jVcMvYPXEHZAmQhsGjdRC',
);
my %got;
{
    steps => [
        { call => 'code', code => sub {
              require watch::export;
              $got{core} = defined &secrets::scan ? 1 : 0;
              my $spec = watch::io::read_json_file("$plugin/assets/handoff-spec.json") || {};
              my $ctx = { spec => $spec };
              $got{rules} = join ',', map { $_->{id} } grep { $_->{skip_paths} } @{ $spec->{secret_rules} || [] };
              $got{paths}{$_} = join ',', grep { /\A(?:cloud-key-bare|high-entropy)\z/ } @{ watch::export::secret_hits($ctx, "$_\n") } for @paths;
              $got{secrets}{$_} = join ',', @{ watch::export::secret_hits($ctx, "- the value: $secrets{$_}\n") } for sort keys %secrets;
          } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->is($got{core}, 0, 'the core rule set is not loaded: the fallback runs');
        $E->is($got{rules}, 'cloud-key-bare,high-entropy', 'the shipped spec marks both rules skip_paths');
        $E->is($got{paths}{$_}, '', "no base64 rule hit: $_") for @paths;
        $E->ok(($got{secrets}{$_} =~ /(?:\A|,)high-entropy(?:,|\z)/ ? 1 : 0), "high-entropy hit: $_ ($got{secrets}{$_})") for sort keys %secrets;
    },
};
