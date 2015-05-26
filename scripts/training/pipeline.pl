#!/usr/bin/perl

# This script implements the Joshua pipeline.  It can run a complete
# pipeline --- from raw training corpora to bleu scores on a test set
# --- and it allows jumping into arbitrary points of the pipeline. 

my $JOSHUA;

BEGIN {
  if (! exists $ENV{JOSHUA} || $ENV{JOSHUA} eq "" ||
      ! exists $ENV{JAVA_HOME} || $ENV{JAVA_HOME} eq "") {
                print "Several environment variables must be set before running the pipeline.  Please set:\n";
                print "* \$JOSHUA to the root of the Joshua source code.\n"
                                if (! exists $ENV{JOSHUA} || $ENV{JOSHUA} eq "");
                print "* \$JAVA_HOME to the directory of your local java installation. \n"
                                if (! exists $ENV{JAVA_HOME} || $ENV{JAVA_HOME} eq "");
                exit;
  }
  $JOSHUA = $ENV{JOSHUA};
  unshift(@INC,"$JOSHUA/scripts/training/cachepipe");
  unshift(@INC,"$JOSHUA/lib");
}

use strict;
use warnings;
use Getopt::Long;
use File::Basename;
use Cwd qw[abs_path getcwd];
use POSIX qw[ceil];
use List::Util qw[max min sum];
use File::Temp qw[:mktemp];
use CachePipe;
# use Thread::Pool;

# Hadoop uses a stupid hacker trick to change directories, but (per Lane Schwartz) if CDPATH
# contains ".", it triggers the printing of the directory, which kills the stupid hacker trick.
# Thus we undefine CDPATH to ensure this doesn't happen.
delete $ENV{CDPATH};

my $HADOOP = $ENV{HADOOP};
my $MOSES = $ENV{MOSES};
delete $ENV{GREP_OPTIONS};

my $THRAX = "$JOSHUA/thrax";

die not_defined("JAVA_HOME") unless exists $ENV{JAVA_HOME};

my (@CORPORA,$TUNE,$TEST,$ALIGNMENT,$SOURCE,$TARGET,@LMFILES,$GRAMMAR_FILE,$GLUE_GRAMMAR_FILE,$_TUNE_GRAMMAR_FILE,$_TEST_GRAMMAR_FILE,$THRAX_CONF_FILE, $_JOSHUA_CONFIG, $_JOSHUA_ARGS);
my $FIRST_STEP = "FIRST";
my $LAST_STEP  = "LAST";
my $LMFILTER = "$ENV{HOME}/code/filter/filter";

# The maximum length of training sentences (--maxlen). The threshold is applied to both sides.
my $MAXLEN = 50;

# The maximum span rules in the main grammar can be applied to
my $MAXSPAN = 20;

# The maximum length of tuning and testing sentences (--maxlen-tune and --maxlen-test).
my $MAXLEN_TUNE = 0;
my $MAXLEN_TEST = 0;

# when doing phrase-based decoding, the maximum length of a phrase (source side)
my $MAX_PHRASE_LEN = 5;

my $DO_FILTER_TM = 1;
my $DO_SUBSAMPLE = 0;
my $DO_PACK_GRAMMARS = 1;
my $SCRIPTDIR = "$JOSHUA/scripts";
my $TOKENIZER_SOURCE = "$SCRIPTDIR/training/penn-treebank-tokenizer.perl";
my $TOKENIZER_TARGET = "$SCRIPTDIR/training/penn-treebank-tokenizer.perl";
my $NORMALIZER = "$SCRIPTDIR/training/normalize-punctuation.pl";
my $GIZA_TRAINER = "$SCRIPTDIR/training/run-giza.pl";
my $TUNECONFDIR = "$SCRIPTDIR/training/templates/tune";
my $SRILM = ($ENV{SRILM}||"")."/bin/i686-m64/ngram-count";
my $COPY_CONFIG = "$SCRIPTDIR/copy-config.pl";
my $BUNDLER = "$JOSHUA/scripts/support/run_bundler.py";
my $STARTDIR;
my $RUNDIR = $STARTDIR = getcwd();
my $GRAMMAR_TYPE = "hiero";  # or "itg" or "samt" or "ghkm" or "phrase"
my $SEARCH_ALGORITHM = "cky"; # or "stack" (for phrase-based)

# Which GHKM extractor to use ("galley" or "moses")
my $GHKM_EXTRACTOR = "moses";
my $EXTRACT_OPTIONS = "";

my $WITTEN_BELL = 0;

# Run description.
my $README = undef;

# gzip-aware cat
my $CAT = "$SCRIPTDIR/training/scat";

# where processed data files are stored
my $DATA_DIR = "data";

# this file should exist in the Joshua mert templates file; it contains
# the Joshua command invoked by MERT
my %TUNEFILES = (
  'mert.config'     => "$TUNECONFDIR/mert.config",
  'pro.config'      => "$TUNECONFDIR/pro.config",
  'params.txt'      => "$TUNECONFDIR/params.txt",
);

# Whether to do MBR decoding on the n-best list (for test data).
my $DO_MBR = 0;

# Which aligner to use. The options are "giza" or "berkeley".
my $ALIGNER = "giza"; # "berkeley" or "giza" or "jacana"

# Filter rules to the following maximum scope (Hopkins & Langmead, 2011).
my $SCOPE = 3;

# What kind of filtering to use ("fast" or "exact").
my $FILTERING = "fast";

# This is the amount of memory made available to Joshua.  You'll need
# a lot more than this for SAMT decoding (though really it depends
# mostly on your grammar size)
my $JOSHUA_MEM = "3100m";

# the amount of memory available for hadoop processes (passed to
# Hadoop via -Dmapred.child.java.opts
my $HADOOP_MEM = "2g";

# The location of a custom core-site.xml file, if desired (optional).
my $HADOOP_CONF = undef;

# memory available to the parser
my $PARSER_MEM = "2g";

# memory available for building the language model
my $BUILDLM_MEM = "2G";

# Memory available for packing the grammar.
my $PACKER_MEM = "8g";

# Memory available for MERT/PRO.
my $TUNER_MEM = "8g";

# When qsub is called for decoding, these arguments should be passed to it.
my $QSUB_ARGS  = "";

# When qsub is called for aligning, these arguments should be passed to it.
my $QSUB_ALIGN_ARGS  = "-l h_rt=168:00:00,h_vmem=15g,mem_free=10g,num_proc=1";

# Amount of memory for the Berkeley aligner.
my $ALIGNER_MEM = "10g";

# Align corpus files a million lines at a time.
my $ALIGNER_BLOCKSIZE = 1000000;

# The number of machines to decode on.  If you set this higher than 1,
# you need to have qsub configured for your environment.
my $NUM_JOBS = 1;

# The number of threads to use at different pieces in the pipeline
# (giza, decoding)
my $NUM_THREADS = 1;

# which LM to use (kenlm or berkeleylm)
my $LM_TYPE = "kenlm";

# n-gram order
my $LM_ORDER = 5;

# Whether to build and include an LM from the target-side of the
# corpus when manually-specified LM files are passed with --lmfile.
my $DO_BUILD_LM_FROM_CORPUS = 1;

# Whether to build and include an LM from the target-side of the
# corpus when manually-specified LM files are passed with --lmfile.
my $DO_BUILD_CLASS_LM = 0;
my $CLASS_LM_CORPUS = undef;
my $CLASS_MAP = undef;
my $CLASS_LM_ORDER = 9;

# whether to tokenize and lowercase training, tuning, and test data
my $DO_PREPARE_CORPORA = 1;

# how many optimizer runs to perform
my $OPTIMIZER_RUNS = 1;

# what to use to create language models ("berkeleylm" or "srilm")
my $LM_GEN = "kenlm";
my $LM_OPTIONS = "";

my @STEPS = qw[FIRST SUBSAMPLE ALIGN PARSE THRAX GRAMMAR PHRASE TUNE MERT PRO TEST LAST];
my %STEPS = map { $STEPS[$_] => $_ + 1 } (0..$#STEPS);

# Methods to use for merging alignments (see Koehn et al., 2003).
# Options are union, {intersect, grow, srctotgt, tgttosrc}-{diag,final,final-and,diag-final,diag-final-and}
my $GIZA_MERGE = "grow-diag-final";

# Whether to merge all the --lmfile LMs into a single LM using weights based on the development corpus
my $MERGE_LMS = 0;

# Which tuner to use by default
my $TUNER = "mert";  # or "pro" or "mira"

# The number of iterations of the mira to run
my $MIRA_ITERATIONS = 15;

# location of already-parsed corpus
my $PARSED_CORPUS = undef;

# location of the ner tagger wrapper script for annotation
my $NER_TAGGER = undef;

# Allows the user to set a temp dir for various tasks
my $TMPDIR = "/tmp";

# Enable forest rescoring
my $LM_STATE_MINIMIZATION = 1;

my $NBEST = 300;

my $REORDERING_LIMIT = 6;
my $NUM_TRANSLATION_OPTIONS = 20;

my $retval = GetOptions(
  "readme=s"    => \$README,
  "corpus=s"        => \@CORPORA,
  "parsed-corpus=s"   => \$PARSED_CORPUS,
  "tune=s"          => \$TUNE,
  "test=s"            => \$TEST,
  "prepare!"          => \$DO_PREPARE_CORPORA,
  "aligner=s"         => \$ALIGNER,
  "alignment=s"      => \$ALIGNMENT,
  "aligner-mem=s"     => \$ALIGNER_MEM,
  "giza-merge=s"      => \$GIZA_MERGE,
  "source=s"          => \$SOURCE,
  "target=s"         => \$TARGET,
  "rundir=s"        => \$RUNDIR,
  "filter-tm!"        => \$DO_FILTER_TM,
  "scope=i"           => \$SCOPE,
  "filtering=s"       => \$FILTERING,
  "lm=s"              => \$LM_TYPE,
  "lmfile=s"        => \@LMFILES,
  "merge-lms!"        => \$MERGE_LMS,
  "lm-gen=s"          => \$LM_GEN,
  "lm-gen-options=s"          => \$LM_OPTIONS,
  "lm-order=i"        => \$LM_ORDER,
  "corpus-lm!"        => \$DO_BUILD_LM_FROM_CORPUS,
  "witten-bell!"     => \$WITTEN_BELL,
  "tune-grammar=s"    => \$_TUNE_GRAMMAR_FILE,
  "test-grammar=s"    => \$_TEST_GRAMMAR_FILE,
  "grammar=s"        => \$GRAMMAR_FILE,
  "glue-grammar=s"     => \$GLUE_GRAMMAR_FILE,
  "maxspan=i"         => \$MAXSPAN,
  "mbr!"              => \$DO_MBR,
  "type=s"           => \$GRAMMAR_TYPE,
  "ghkm-extractor=s"  => \$GHKM_EXTRACTOR,
  "extract-options=s" => \$EXTRACT_OPTIONS,
  "maxlen=i"        => \$MAXLEN,
  "maxlen-tune=i"        => \$MAXLEN_TUNE,
  "maxlen-test=i"        => \$MAXLEN_TEST,
  "tokenizer-source=s"      => \$TOKENIZER_SOURCE,
  "tokenizer-target=s"      => \$TOKENIZER_TARGET,
  "joshua-config=s"   => \$_JOSHUA_CONFIG,
  "pro-config=s"   => \$TUNEFILES{'pro.config'},
  "params-txt=s"   => \$TUNEFILES{'params.txt'},
  "joshua-args=s"      => \$_JOSHUA_ARGS,
  "joshua-mem=s"      => \$JOSHUA_MEM,
  "hadoop-mem=s"      => \$HADOOP_MEM,
  "parser-mem=s"      => \$PARSER_MEM,
  "buildlm-mem=s"     => \$BUILDLM_MEM,
  "packer-mem=s"      => \$PACKER_MEM,
  "pack!"             => \$DO_PACK_GRAMMARS,
  "decoder-command=s" => \$TUNEFILES{'decoder_command'},
  "tuner=s"           => \$TUNER,
  "tuner-mem=s"       => \$TUNER_MEM,
  "mira-iterations=i" => \$MIRA_ITERATIONS,
  "thrax=s"           => \$THRAX,
  "thrax-conf=s"      => \$THRAX_CONF_FILE,
  "jobs=i"            => \$NUM_JOBS,
  "threads=i"         => \$NUM_THREADS,
  "subsample!"       => \$DO_SUBSAMPLE,
  "qsub-args=s"      => \$QSUB_ARGS,
  "qsub-align-args=s"      => \$QSUB_ALIGN_ARGS,
  "first-step=s"     => \$FIRST_STEP,
  "last-step=s"      => \$LAST_STEP,
  "aligner-chunk-size=s" => \$ALIGNER_BLOCKSIZE,
  "hadoop=s"          => \$HADOOP,
  "hadoop-conf=s"          => \$HADOOP_CONF,
  "tmp=s"             => \$TMPDIR,
  "nbest=i"           => \$NBEST,
  "reordering-limit=i" => \$REORDERING_LIMIT,
  "num-translation-options=i" => \$NUM_TRANSLATION_OPTIONS,
  "ner-tagger=s"   => \$NER_TAGGER,
  "class-lm!"     => \$DO_BUILD_CLASS_LM,
  "class-lm-corpus=s"   => \$CLASS_LM_CORPUS,
  "class-map"     => \$CLASS_MAP,
);

if (! $retval) {
  print "Invalid usage, quitting\n";
  exit 1;
}

# Joshua config
my $JOSHUA_CONFIG = $_JOSHUA_CONFIG || "$TUNECONFDIR/joshua.config";

$RUNDIR = get_absolute_path($RUNDIR);

$TUNER = lc $TUNER;

my $DOING_LATTICES = 0;

# Prepend a space to the arguments list if it's non-empty and doesn't already have the space.
my $JOSHUA_ARGS = $_JOSHUA_ARGS || "";
if ($JOSHUA_ARGS ne "" and $JOSHUA_ARGS !~ /^\s/) {
  $JOSHUA_ARGS = " $JOSHUA_ARGS";
}

$TUNEFILES{'pro.config'} = get_absolute_path($TUNEFILES{'pro.config'});
$TUNEFILES{'params.txt'} = get_absolute_path($TUNEFILES{'params.txt'});
$TUNEFILES{'decoder_command'} = get_absolute_path($TUNEFILES{'decoder_command'});

my %DATA_DIRS = (
  train => get_absolute_path("$RUNDIR/$DATA_DIR/train"),
  tune  => get_absolute_path("$RUNDIR/$DATA_DIR/tune"),
  test  => get_absolute_path("$RUNDIR/$DATA_DIR/test"),
);

# capitalize these to offset a common error:
$FIRST_STEP = uc($FIRST_STEP);
$LAST_STEP  = uc($LAST_STEP);

$| = 1;

my $cachepipe = new CachePipe();

# This tells cachepipe not to include the command signature when determining to run a command.  Note
# that this is not backwards compatible!
$cachepipe->omit_cmd();

$SIG{INT} = sub { 
  print "* Got C-c, quitting\n";
  $cachepipe->cleanup();
  exit 1; 
};

# if no LMs were specified, we need to build one from the target side of the corpus
if (scalar @LMFILES == 0) {
  $DO_BUILD_LM_FROM_CORPUS = 1;
}

## Sanity Checking ###################################################

# If a language model was specified and no corpus was given to build another one from the target
# side of the training data (which could happen, for example, when starting at the tuning step with
# an existing LM), turn off building an LM from the corpus.  The user could have done this
# explicitly with --no-corpus-lm, but might have forgotten to, and we con't want to pester them with
# an error about easily-inferrable intentions.
if (scalar @LMFILES && ! scalar(@CORPORA)) {
  $DO_BUILD_LM_FROM_CORPUS = 0;
}


# if merging LMs, make sure there are at least 2 LMs to merge.
# first, pin $DO_BUILD_LM_FROM_CORPUS to 0 or 1 so that the subsequent check works.
if ($MERGE_LMS) {
  if ($DO_BUILD_LM_FROM_CORPUS != 0) {
    $DO_BUILD_LM_FROM_CORPUS = 1
  }

  if (@LMFILES + $DO_BUILD_LM_FROM_CORPUS < 2) {
    print "* FATAL: I need 2 or more language models to merge (including the corpus target-side LM).";
    exit 2;
  }
}

# absolutize LM file paths
map {
  $LMFILES[$_] = get_absolute_path($LMFILES[$_]);
} 0..$#LMFILES;

# make sure the LMs exist
foreach my $lmfile (@LMFILES) {
  if (! -e $lmfile) {
    print "* FATAL: couldn't find language model file '$lmfile'\n";
    exit 1;
  }
}

# case-normalize this
$GRAMMAR_TYPE = lc $GRAMMAR_TYPE;

if ($GRAMMAR_TYPE eq "phrase") {
  $SEARCH_ALGORITHM = "stack";
  $MAXSPAN = 0;
}

# make sure source and target were specified
if (! defined $SOURCE or $SOURCE eq "") {
  print "* FATAL: I need a source language extension (--source)\n";
  exit 1;
}
if (! defined $TARGET or $TARGET eq "") {
  print "* FATAL: I need a target language extension (--target)\n";
  exit 1;
}

# make sure a corpus was provided if we're doing any step before tuning
if (@CORPORA == 0 and $STEPS{$FIRST_STEP} < $STEPS{TUNE}) {
  print "* FATAL: need at least one training corpus (--corpus)\n";
  exit 1;
}

# make sure a tuning corpus was provided if we're doing tuning
if (! defined $TUNE and ($STEPS{$FIRST_STEP} <= $STEPS{TUNE}
                         and $STEPS{$LAST_STEP} >= $STEPS{TUNE})) { 
  print "* FATAL: need a tuning set (--tune)\n";
  exit 1;
}

# make sure a test corpus was provided if we're decoding a test set
if (! defined $TEST and ($STEPS{$FIRST_STEP} <= $STEPS{TEST}
                         and $STEPS{$LAST_STEP} >= $STEPS{TEST})) {
  print "* FATAL: need a test set (--test)\n";
  exit 1;
}

# make sure a grammar file was given if we're skipping training
if (! defined $GRAMMAR_FILE) {
  if ($STEPS{$FIRST_STEP} >= $STEPS{TEST}) {
    if (! defined $_TEST_GRAMMAR_FILE) {
      print "* FATAL: need a grammar (--grammar or --test-grammar) if you're skipping to testing\n";
			exit 1;
		}
  } elsif ($STEPS{$FIRST_STEP} >= $STEPS{TUNE}) {
		if (! defined $_TUNE_GRAMMAR_FILE) {
			print "* FATAL: need a grammar (--grammar or --tune-grammar) if you're skipping grammar learning\n";
			exit 1;
		}
  }
}

# make sure SRILM is defined if we're building a language model
if ($LM_GEN eq "srilm" && (scalar @LMFILES == 0) && $STEPS{$FIRST_STEP} <= $STEPS{TUNE} && $STEPS{$LAST_STEP} >= $STEPS{TUNE}) {
  not_defined("SRILM") unless exists $ENV{SRILM} and -d $ENV{SRILM};
}

# check for file presence
if (defined $GRAMMAR_FILE and ! -e $GRAMMAR_FILE) {
  print "* FATAL: couldn't find grammar file '$GRAMMAR_FILE'\n";
  exit 1;
}
if (defined $_TUNE_GRAMMAR_FILE and ! -e $_TUNE_GRAMMAR_FILE) {
  print "* FATAL: couldn't find tuning grammar file '$_TUNE_GRAMMAR_FILE'\n";
  exit 1;
}
if (defined $_TEST_GRAMMAR_FILE and ! -e $_TEST_GRAMMAR_FILE) {
  print "* FATAL: couldn't find test grammar file '$_TEST_GRAMMAR_FILE'\n";
  exit 1;
}
if (defined $ALIGNMENT and ! -e $ALIGNMENT) {
  print "* FATAL: couldn't find alignment file '$ALIGNMENT'\n";
  exit 1;
}

# If $CORPUS was a relative path, prepend the starting directory (under the assumption it was
# relative to there).  This makes sure that everything will still work if we change the run
# directory.
map {
  $CORPORA[$_] = get_absolute_path("$CORPORA[$_]");
} (0..$#CORPORA);

# Do the same for tuning and test data, and other files
$TUNE = get_absolute_path($TUNE);
$TEST = get_absolute_path($TEST);

$GRAMMAR_FILE = get_absolute_path($GRAMMAR_FILE);
$GLUE_GRAMMAR_FILE = get_absolute_path($GLUE_GRAMMAR_FILE);
$_TUNE_GRAMMAR_FILE = get_absolute_path($_TUNE_GRAMMAR_FILE);
$_TEST_GRAMMAR_FILE = get_absolute_path($_TEST_GRAMMAR_FILE);
$THRAX_CONF_FILE = get_absolute_path($THRAX_CONF_FILE);
$ALIGNMENT = get_absolute_path($ALIGNMENT);
$HADOOP_CONF = get_absolute_path($HADOOP_CONF);

foreach my $corpus (@CORPORA) {
  foreach my $ext ($TARGET,$SOURCE) {
    if (! -e "$corpus.$ext") {
      print "* FATAL: can't find '$corpus.$ext'";
      exit 1;
    } 
  }
}

if ($ALIGNER ne "giza" and $ALIGNER ne "berkeley" and $ALIGNER ne "jacana") {
  print "* FATAL: aligner must be one of 'giza', 'berkeley' or 'jacana' (only French-English)\n";
  exit 1;
}

if ($LM_TYPE ne "kenlm" and $LM_TYPE ne "berkeleylm") {
  print "* FATAL: lm type (--lm) must be one of 'kenlm' or 'berkeleylm'\n";
  exit 1;
}

if ($LM_TYPE ne "kenlm") {
  $LM_STATE_MINIMIZATION = 0;
}

if ($LM_GEN ne "berkeleylm" and $LM_GEN ne "srilm" and $LM_GEN ne "kenlm") {
  print "* FATAL: lm generating code (--lm-gen) must be one of 'kenlm' (default), 'berkeleylm', or 'srilm'\n";
  exit 1;
}

if ($TUNER eq "mira") {
  if (! defined $MOSES) {
    print "* FATAL: using MIRA for tuning requires setting the MOSES environment variable\n";
    exit 1;
  }
}

if ($TUNER ne "mert" and $TUNER ne "mira" and $TUNER ne "pro") {
  print "* FATAL: --tuner must be one of 'mert', 'pro', or 'mira'.\n";
  exit 1;
}

$FILTERING = lc $FILTERING;
if ($FILTERING eq "fast") {
  $FILTERING = "-f"
} elsif ($FILTERING eq "exact") {
  $FILTERING = "-e";
} elsif ($FILTERING eq "loose") {
  $FILTERING = "-l";
} else {
  print "* FATAL: --filtering must be one of 'fast' (default) or 'exact' or 'loose'\n";
  exit 1;
}

if (defined $HADOOP_CONF && ! -e $HADOOP_CONF) {
  print STDERR "* FATAL: Couldn't find \$HADOOP_CONF file '$HADOOP_CONF'\n";
  exit 1;
}

## END SANITY CHECKS

####################################################################################################
## Dependent variable setting ######################################################################
####################################################################################################

my $OOV = ($GRAMMAR_TYPE eq "hiero" or $GRAMMAR_TYPE eq "itg" or $GRAMMAR_TYPE eq "phrase") ? "X" : "OOV";

# The phrasal system should use the ITG grammar, allowing for limited distortion
if ($GRAMMAR_TYPE eq "phrasal") {
  $GLUE_GRAMMAR_FILE = get_absolute_path("$JOSHUA/scripts/training/templates/glue-grammar.itg");
}

# use this default unless it's already been defined by a command-line argument
$THRAX_CONF_FILE = "$JOSHUA/scripts/training/templates/thrax-$GRAMMAR_TYPE.conf" unless defined $THRAX_CONF_FILE;

mkdir $RUNDIR unless -d $RUNDIR;
chdir($RUNDIR);

if (defined $README) {
  open DESC, ">README" or die "can't write README file";
  print DESC $README;
  print DESC $/;
  close DESC;
}

# default values -- these are overridden if the full script is run
# (after tokenization and normalization)
my (%TRAIN,%TUNE,%TEST);
if (@CORPORA) {
  $TRAIN{prefix} = $CORPORA[0];
  $TRAIN{source} = "$CORPORA[0].$SOURCE";
  $TRAIN{target} = "$CORPORA[0].$TARGET";
}

# set the location of the parsed corpus if that was defined
if (defined $PARSED_CORPUS) {
  $TRAIN{parsed} = get_absolute_path($PARSED_CORPUS);
}

if ($TUNE) {
  $TUNE{source} = "$TUNE.$SOURCE";
  $TUNE{target} = "$TUNE.$TARGET";

  if (! -e "$TUNE{source}") {
    print "* FATAL: couldn't find tune source file at '$TUNE{source}'\n";
    exit;
  }
}

if ($TEST) {
  $TEST{source} = "$TEST.$SOURCE";
  $TEST{target} = "$TEST.$TARGET";

  if (! -e "$TEST{source}") {
    print "* FATAL: couldn't find test source file at '$TEST{source}'\n";
    exit;
  }
}

if ($FIRST_STEP ne "FIRST") {
  if (@CORPORA > 1) {
		print "* FATAL: you can't skip steps if you specify more than one --corpus\n";
		exit(1);
  }

  if (eval { goto $FIRST_STEP }) {
		print "* Skipping to step $FIRST_STEP\n";
		goto $FIRST_STEP;
  } else {
		print "* No such step $FIRST_STEP\n";
		exit 1;
  }
}

## STEP 1: filter and preprocess corpora #############################
FIRST:
    ;

if (defined $ALIGNMENT) {
  print "* FATAL: it doesn't make sense to provide an alignment and then do\n";
  print "  tokenization.  Either remove --alignment or specify a first step\n";
  print "  of Thrax (--first-step THRAX)\n";
  exit 1;
}

if (@CORPORA == 0) {
  print "* FATAL: need at least one training corpus (--corpus)\n";
  exit 1;
}

# prepare the training data
my %PREPPED = (
  TRAIN => 0,
  TUNE => 0,
  TEST => 0
		);


if ($DO_PREPARE_CORPORA) {
  my $prefixes = prepare_data("train",\@CORPORA,$MAXLEN);

  # used for parsing
  $TRAIN{mixedcase} = "$DATA_DIRS{train}/$prefixes->{shortened}.$TARGET.gz";

  $TRAIN{prefix} = "$DATA_DIRS{train}/corpus";
  $TRAIN{source} = "$DATA_DIRS{train}/corpus.$SOURCE";
  $TRAIN{target} = "$DATA_DIRS{train}/corpus.$TARGET";
  $PREPPED{TRAIN} = 1;
}

# prepare the tuning and development data
if (defined $TUNE and $DO_PREPARE_CORPORA) {
  my $prefixes = prepare_data("tune",[$TUNE],$MAXLEN_TUNE);
  $TUNE{source} = "$DATA_DIRS{tune}/corpus.$SOURCE";
  $TUNE{target} = "$DATA_DIRS{tune}/corpus.$TARGET";
  my $ner_return = ner_annotate("$TUNE{source}", "$TUNE{source}.ner", $SOURCE);
  if ($ner_return == 2) {
    $TUNE{source} = "$TUNE{source}.ner";
  }
  $PREPPED{TUNE} = 1;
}

if (defined $TEST and $DO_PREPARE_CORPORA) {
  my $prefixes = prepare_data("test",[$TEST],$MAXLEN_TEST);
  $TEST{source} = "$DATA_DIRS{test}/corpus.$SOURCE";
  $TEST{target} = "$DATA_DIRS{test}/corpus.$TARGET";
  my $ner_return = ner_annotate("$TEST{source}", "$TEST{source}.ner", $SOURCE);
  if ($ner_return == 2) {
    $TEST{source} = "$TEST{source}.ner";
  }
  $PREPPED{TEST} = 1;
}

maybe_quit("FIRST");

## SUBSAMPLE #########################################################

SUBSAMPLE:
    ;

# subsample
		if ($DO_SUBSAMPLE) {
			mkdir("$DATA_DIRS{train}/subsampled") unless -d "$DATA_DIRS{train}/subsampled";

			$cachepipe->cmd("subsample-manifest",
											"echo corpus > $DATA_DIRS{train}/subsampled/manifest",
											"$DATA_DIRS{train}/subsampled/manifest");

			$cachepipe->cmd("subsample-testdata",
											"cat $TUNE{source} $TEST{source} > $DATA_DIRS{train}/subsampled/test-data",
											$TUNE{source},
											$TEST{source},
											"$DATA_DIRS{train}/subsampled/test-data");

			$cachepipe->cmd("subsample",
											"java -Xmx4g -Dfile.encoding=utf8 -cp $JOSHUA/bin:$JOSHUA/lib/commons-cli-2.0-SNAPSHOT.jar joshua.subsample.Subsampler -e $TARGET -f $SOURCE -epath $DATA_DIRS{train}/ -fpath $DATA_DIRS{train}/ -output $DATA_DIRS{train}/subsampled/subsampled.$MAXLEN -ratio 1.04 -test $DATA_DIRS{train}/subsampled/test-data -training $DATA_DIRS{train}/subsampled/manifest",
											"$DATA_DIRS{train}/subsampled/manifest",
											"$DATA_DIRS{train}/subsampled/test-data",
											$TRAIN{source},
											$TRAIN{target},
											"$DATA_DIRS{train}/subsampled/subsampled.$MAXLEN.$TARGET",
											"$DATA_DIRS{train}/subsampled/subsampled.$MAXLEN.$SOURCE");

			# rewrite the symlinks to point to the subsampled corpus
			foreach my $lang ($TARGET,$SOURCE) {
				system("ln -sf subsampled/subsampled.$MAXLEN.$lang $DATA_DIRS{train}/corpus.$lang");
			}
}

maybe_quit("SUBSAMPLE");


## ALIGN #############################################################

ALIGN:
    ;

# This basically means that we've skipped tokenization, in which case
# we still want to move the input files into the canonical place
if ($FIRST_STEP eq "ALIGN") {
  if (defined $ALIGNMENT) {
    print "* FATAL: It doesn't make sense to provide an alignment\n";
    print "  but not to skip the tokenization and subsampling steps\n";
    exit 1;
  }

  # TODO: copy the files into the canonical place 

  # Jumping straight to alignment is probably the same thing as
  # skipping tokenization, and might also be implemented by a
  # --no-tokenization flag
}

# skip this step if an alignment was provided
if (! defined $ALIGNMENT) {

  # We process the data in chunks which by default are 1,000,000 sentence pairs.  So first split up
  # the data into those chunks.
  system("mkdir","-p","$DATA_DIRS{train}/splits") unless -d "$DATA_DIRS{train}/splits";

  $cachepipe->cmd("source-numlines",
									"cat $TRAIN{source} | wc -l",
									$TRAIN{source});
  my $numlines = $cachepipe->stdout();
  my $numchunks = ceil($numlines / $ALIGNER_BLOCKSIZE);

  open TARGET, $TRAIN{target} or die "can't read $TRAIN{target}";
  open SOURCE, $TRAIN{source} or die "can't read $TRAIN{source}";

  my $lastchunk = -1;
  while (my $target = <TARGET>) {
		my $source = <SOURCE>;

		# We want to prevent a very small last chunk, which we accomplish
		# by folding the last chunk into the penultimate chunk.
		my $chunk = ($numchunks <= 2)
				? 0 
				: min($numchunks - 2,
							int( (${.} - 1) / $ALIGNER_BLOCKSIZE ));
		
		if ($chunk != $lastchunk) {
			close CHUNK_SOURCE;
			close CHUNK_TARGET;
			open CHUNK_SOURCE, ">", "$DATA_DIRS{train}/splits/corpus.$SOURCE.$chunk" or die;
			open CHUNK_TARGET, ">", "$DATA_DIRS{train}/splits/corpus.$TARGET.$chunk" or die;

			$lastchunk = $chunk;
		}

		print CHUNK_SOURCE $source;
		print CHUNK_TARGET $target;
  }
  close CHUNK_SOURCE;
  close CHUNK_TARGET;

  close SOURCE;
  close TARGET;

  # my $max_aligner_threads = $NUM_THREADS;
  # if ($ALIGNER eq "giza" and $max_aligner_threads > 1) {
  #   $max_aligner_threads /= 2;
  # }

  # # With multi-threading, we can use a pool to set up concurrent GIZA jobs on the chunks.
  #
  # TODO: implement this.  There appears to be a problem with calling system() in threads.
  #
  # my $pool = new Thread::Pool(Min => 1, Max => $max_aligner_threads);

  system("mkdir alignments") unless -d "alignments";

  # Run the parallel aligner
  system("seq 0 $lastchunk | $SCRIPTDIR/training/paralign.pl -aligner $ALIGNER -num_threads $NUM_THREADS -giza_merge $GIZA_MERGE -aligner_mem $ALIGNER_MEM -source $SOURCE -target $TARGET -giza_trainer \"$GIZA_TRAINER\" -train_dir \"$DATA_DIRS{train}\" > alignments/run.log");

  my @aligned_files;
  if ($ALIGNER eq "giza") {
    @aligned_files = map { "alignments/$_/model/aligned.$GIZA_MERGE" } (0..$lastchunk);
  } elsif ($ALIGNER eq "berkeley") {
    @aligned_files = map { "alignments/$_/training.align" } (0..$lastchunk);
  } elsif ($ALIGNER eq "jacana") {
    @aligned_files = map { "alignments/$_/training.align" } (0..$lastchunk);
  }
	my $aligned_file_list = join(" ", @aligned_files);

  # wait for all the threads to finish
  # $pool->join();

	# combine the alignments
	$cachepipe->cmd("aligner-combine",
									"cat $aligned_file_list > alignments/training.align",
									$aligned_files[-1],
									"alignments/training.align");

  # at the end, all the files are concatenated into a single alignment file parallel to the input
  # corpora
  $ALIGNMENT = "alignments/training.align";
}

maybe_quit("ALIGN");


## PARSE #############################################################

PARSE:
    ;

# Parsing only happens for SAMT grammars.

if ($FIRST_STEP eq "PARSE" and ($GRAMMAR_TYPE eq "hiero" or $GRAMMAR_TYPE eq "phrasal" or $GRAMMAR_TYPE eq "phrase")) {
  print STDERR "* FATAL: parsing doesn't apply to hiero grammars; You need to add '--type samt|ghkm'\n";
  exit;
}

if ($GRAMMAR_TYPE eq "samt" || $GRAMMAR_TYPE eq "ghkm") {

  # If the user passed in the already-parsed corpus, use that (after copying it into place)
  if (defined $TRAIN{parsed} && -e $TRAIN{parsed}) {
    # copy and adjust the location of the file to its canonical location
    system("cp $TRAIN{parsed} $DATA_DIRS{train}/corpus.parsed.$TARGET");
    $TRAIN{parsed} = "$DATA_DIRS{train}/corpus.parsed.$TARGET";
  } else {

    system("mkdir -p $DATA_DIRS{train}") unless -e $DATA_DIRS{train};

    $cachepipe->cmd("build-vocab",
                    "cat $TRAIN{target} | $SCRIPTDIR/training/build-vocab.pl > $DATA_DIRS{train}/vocab.$TARGET",
                    $TRAIN{target},
                    "$DATA_DIRS{train}/vocab.$TARGET");

    my $file_to_parse = (exists $TRAIN{mixedcase}) ? $TRAIN{mixedcase} : $TRAIN{target};

    if ($NUM_JOBS > 1) {
      # the black-box parallelizer model doesn't work with multiple
      # threads, so we're always spawning single-threaded instances here

      # open PARSE, ">parse.sh" or die;
      # print PARSE "cat $TRAIN{target} | $JOSHUA/scripts/training/parallelize/parallelize.pl --jobs $NUM_JOBS --qsub-args \"$QSUB_ARGS\" -- java -d64 -Xmx${PARSER_MEM} -jar $JOSHUA/lib/BerkeleyParser.jar -gr $JOSHUA/lib/eng_sm6.gr -nThreads 1 | sed 's/^\(/\(TOP/' | tee $DATA_DIRS{train}/corpus.$TARGET.parsed.mc | perl -pi -e 's/(\\S+)\\)/lc(\$1).\")\"/ge' | tee $DATA_DIRS{train}/corpus.$TARGET.parsed | perl $SCRIPTDIR/training/add-OOVs.pl $DATA_DIRS{train}/vocab.$TARGET > $DATA_DIRS{train}/corpus.parsed.$TARGET\n";
      # close PARSE;
      # chmod 0755, "parse.sh";
      # $cachepipe->cmd("parse",
      #         "setsid ./parse.sh",
      #         "$TRAIN{target}",
      #         "$DATA_DIRS{train}/corpus.parsed.$TARGET");

      $cachepipe->cmd("parse",
                      "$CAT $file_to_parse | $JOSHUA/scripts/training/parallelize/parallelize.pl --jobs $NUM_JOBS --qsub-args \"$QSUB_ARGS\" -p 8g -- java -d64 -Xmx${PARSER_MEM} -jar $JOSHUA/lib/BerkeleyParser.jar -gr $JOSHUA/lib/eng_sm6.gr -nThreads 1 | sed 's/^(())\$//; s/^(/(TOP/' | perl $SCRIPTDIR/training/add-OOVs.pl $DATA_DIRS{train}/vocab.$TARGET | tee $DATA_DIRS{train}/corpus.$TARGET.Parsed | $SCRIPTDIR/training/lowercase-leaves.pl > $DATA_DIRS{train}/corpus.parsed.$TARGET",
                      "$TRAIN{target}",
                      "$DATA_DIRS{train}/corpus.parsed.$TARGET");
    } else {
      # Multi-threading in the Berkeley parser is broken, so we use a black-box parallelizer on top
      # of it.
      $cachepipe->cmd("parse",
                      "$CAT $file_to_parse | $JOSHUA/scripts/training/parallelize/parallelize.pl --jobs $NUM_THREADS --use-fork -- java -d64 -Xmx${PARSER_MEM} -jar $JOSHUA/lib/BerkeleyParser.jar -gr $JOSHUA/lib/eng_sm6.gr -nThreads 1 | sed 's/^(())\$//; s/^(/(TOP/' | perl $SCRIPTDIR/training/add-OOVs.pl $DATA_DIRS{train}/vocab.$TARGET | tee $DATA_DIRS{train}/corpus.$TARGET.Parsed | $SCRIPTDIR/training/lowercase-leaves.pl > $DATA_DIRS{train}/corpus.parsed.$TARGET",
                      "$TRAIN{target}",
                      "$DATA_DIRS{train}/corpus.parsed.$TARGET");
    }

    $TRAIN{parsed} = "$DATA_DIRS{train}/corpus.parsed.$TARGET";
  }
}

maybe_quit("PARSE");

## THRAX #############################################################

GRAMMAR:
    ;
THRAX:
    ;
PHRASE:
    ;

system("mkdir -p $DATA_DIRS{train}") unless -d $DATA_DIRS{train};

if ($GRAMMAR_TYPE eq "samt" || $GRAMMAR_TYPE eq "ghkm") {

  # if we jumped right here, $TRAIN{target} should be parsed
  if (exists $TRAIN{parsed}) {
		# parsing step happened in-script or a parsed corpus was passed in explicitly, all is well

  } elsif (already_parsed($TRAIN{target})) {
		# skipped straight to this step, passing a parsed corpus

		$TRAIN{parsed} = "$DATA_DIRS{train}/corpus.parsed.$TARGET";
		
		$cachepipe->cmd("cp-train-$TARGET",
										"cp $TRAIN{target} $TRAIN{parsed}",
										$TRAIN{target}, 
										$TRAIN{parsed});

		$TRAIN{target} = "$DATA_DIRS{train}/corpus.$TARGET";

		# now extract the leaves of the parsed corpus
		$cachepipe->cmd("extract-leaves",
										"cat $TRAIN{parsed} | perl -pe 's/\\(.*?(\\S\+)\\)\+?/\$1/g' | perl -pe 's/\\)//g' > $TRAIN{target}",
										$TRAIN{parsed},
										$TRAIN{target});

		if ($TRAIN{source} ne "$DATA_DIRS{train}/corpus.$SOURCE") {
			$cachepipe->cmd("cp-train-$SOURCE",
											"cp $TRAIN{source} $DATA_DIRS{train}/corpus.$SOURCE",
											$TRAIN{source}, "$DATA_DIRS{train}/corpus.$SOURCE");
			$TRAIN{source} = "$DATA_DIRS{train}/corpus.$SOURCE";
		}

  } else {
		print "* FATAL: You requested to build an SAMT grammar, but provided an\n";
		print "  unparsed corpus.  Please re-run the pipeline and begin no later\n";
		print "  than the PARSE step (--first-step PARSE), or pass in a parsed corpus\n";
		print "  using --parsed-corpus CORPUS.\n";
		exit 1;
  }
	
}

# we may have skipped directly to this step, in which case we need to
# ensure an alignment was provided
if (! defined $ALIGNMENT) {
  print "* FATAL: no alignment file specified\n";
  exit(1);
}

# Look for a pre-existing grammar, since building it is expensive, and something we want to
# avoid if this is a rerun
if (-e "grammar.gz" && ! -z "grammar.gz") {
  chomp(my $is_empty = `gzip -cd grammar.gz | head | wc -l`);
  $GRAMMAR_FILE = "grammar.gz" unless ($is_empty == 0);
}

# If the grammar file wasn't specified
if (! defined $GRAMMAR_FILE) {

  my $target_file = ($GRAMMAR_TYPE eq "hiero" or $GRAMMAR_TYPE eq "phrasal" or $GRAMMAR_TYPE eq "phrase") ? $TRAIN{target} : $TRAIN{parsed};

  if ($GRAMMAR_TYPE eq "ghkm") {
    if ($GHKM_EXTRACTOR eq "galley") {
      $cachepipe->cmd("ghkm-extract",
                      "java -Xmx4g -Xms4g -cp $JOSHUA/lib/ghkm-modified.jar:$JOSHUA/lib/fastutil.jar -XX:+UseCompressedOops edu.stanford.nlp.mt.syntax.ghkm.RuleExtractor -fCorpus $TRAIN{source} -eParsedCorpus $target_file -align $ALIGNMENT -threads $NUM_THREADS -joshuaFormat true -maxCompositions 1 -reversedAlignment false | $SCRIPTDIR/support/splittabs.pl ghkm-mapping.gz grammar.gz",
                      $ALIGNMENT,
                      "grammar.gz");
    } elsif ($GHKM_EXTRACTOR eq "moses") {
      # XML-ize, also replacing unary chains with OOV at the bottom by removing their unary parents
      $cachepipe->cmd("ghkm-moses-xmlize",
                      "cat $target_file | perl -pe 's/\\(\\S+ \\(OOV (.*?)\\)\\)/(OOV \$1)/g' | $MOSES/scripts/training/wrappers/berkeleyparsed2mosesxml.perl > $DATA_DIRS{train}/corpus.xml",
                      # "cat $target_file | perl -pe 's/\\(\\S+ \\(OOV (.*?)\\)\\)/(OOV \$1)/g' > $DATA_DIRS{train}/corpus.ptb",
                      $target_file,
                      "$DATA_DIRS{train}/corpus.xml");

      if (! -e "$DATA_DIRS{train}/corpus.$SOURCE") {
        system("ln -sf $TRAIN{source} $DATA_DIRS{train}/corpus.$SOURCE");
      }

      if ($ALIGNMENT ne "alignments/training.align") {
        system("mkdir alignments") unless -d "alignments";
        system("ln -sf $ALIGNMENT alignments/training.align");
        $ALIGNMENT = "alignments/training.align";
      }

      system("mkdir model");
      $cachepipe->cmd("ghkm-moses-extract",
                      "$MOSES/scripts/training/train-model.perl --first-step 4 --last-step 6 --corpus $DATA_DIRS{train}/corpus --ghkm --f $SOURCE --e xml --alignment-file alignments/training --alignment align --target-syntax --cores $NUM_THREADS --pcfg --alt-direct-rule-score-1 --ghkm-tree-fragments --glue-grammar --glue-grammar-file glue-grammar.ghkm --extract-options \"$EXTRACT_OPTIONS --UnknownWordLabel oov-labels.txt\"",
                      "$DATA_DIRS{train}/corpus.xml",
                      "glue-grammar.ghkm",
                      "model/rule-table.gz");

      open LABELS, "oov-labels.txt";
      chomp(my @labels = <LABELS>);
      close LABELS;
      my $oov_list = "\"" . join(" ", @labels) . "\"";
      $JOSHUA_ARGS .= " -oov-list $oov_list";

      $cachepipe->cmd("ghkm-moses-convert",
                      "gzip -cd model/rule-table.gz | /home/hltcoe/mpost/code/joshua/scripts/support/moses2joshua_grammar.pl -m rule-fragment-map.txt | gzip -9n > grammar.gz",
                      "model/rule-table.gz",
                      "grammar.gz");

    } else {
      print STDERR "* FATAL: no such GHKM extractor '$GHKM_EXTRACTOR'\n";
      exit(1);
    }

    $GRAMMAR_FILE = "grammar.gz";

  } elsif ($GRAMMAR_TYPE eq "phrase") {

    mkdir("model") unless -d "model";

    if ($ALIGNMENT ne "alignments/training.align") {
      system("mkdir alignments") unless -d "alignments";
      system("ln -sf $ALIGNMENT alignments/training.align");
      $ALIGNMENT = "alignments/training.align";
    }

    # Compute lexical probabilities
    $cachepipe->cmd("build-lex-trans",
                    "$MOSES/scripts/training/train-model.perl -mgiza -mgiza-cpus $NUM_THREADS -dont-zip -first-step 4 -last-step 4 -external-bin-dir $MOSES/bin -f $SOURCE -e $TARGET -max-phrase-length $MAX_PHRASE_LEN -score-options '--GoodTuring' -parallel -lexical-file model/lex -alignment-file alignments/training -alignment align -corpus $TRAIN{prefix}",
                    $TRAIN{source},
                    $TRAIN{target},
                    $ALIGNMENT,
                    "model/lex.e2f",
                    "model/lex.f2e"
        );

    # Extract the phrases
    $cachepipe->cmd("extract-phrases",
                    "$MOSES/scripts/training/train-model.perl -mgiza -mgiza-cpus $NUM_THREADS -dont-zip -first-step 5 -last-step 5 -external-bin-dir $MOSES/bin -f $SOURCE -e $TARGET -max-phrase-length $MAX_PHRASE_LEN -score-options '--GoodTuring' -parallel -alignment-file alignments/training -alignment align -extract-file model/extract -corpus $TRAIN{prefix}",
                    $TRAIN{source},
                    $TRAIN{target},
                    $ALIGNMENT,
                    "model/extract.sorted.gz",
                    "model/extract.inv.sorted.gz"
        );

    # Build the phrase table
    $cachepipe->cmd("build-ttable",
                    "$MOSES/scripts/training/train-model.perl -mgiza -mgiza-cpus $NUM_THREADS -dont-zip -first-step 6 -last-step 6 -external-bin-dir $MOSES/bin -f $SOURCE -e $TARGET -alignment grow-diag-final-and -max-phrase-length $MAX_PHRASE_LEN -score-options '--GoodTuring' -parallel -extract-file model/extract -lexical-file model/lex -phrase-translation-table model/phrase-table",
                    "model/lex.e2f",
                    "model/extract.sorted.gz"
        );

    $GRAMMAR_FILE = "model/phrase-table.gz";

  } elsif ($GRAMMAR_TYPE eq "samt" or $GRAMMAR_TYPE eq "hiero") {

    # Since this is an expensive step, we short-circuit it if the grammar file is present.  I'm not
    # sure that this is the right behavior.

    # create the input file
    $cachepipe->cmd("thrax-input-file",
                    "paste $TRAIN{source} $target_file $ALIGNMENT | perl -pe 's/\\t/ ||| /g' | grep -v '()' | grep -v '||| \\+\$' > $DATA_DIRS{train}/thrax-input-file",
                    $TRAIN{source}, $target_file, $ALIGNMENT,
                    "$DATA_DIRS{train}/thrax-input-file");


    # Rollout the hadoop cluster if needed.  This causes $HADOOP to be defined (pointing to the
    # unrolled directory).
    start_hadoop_cluster() unless defined $HADOOP;

    # put the hadoop files in place
    my $THRAXDIR;
    my $thrax_input;
    if ($HADOOP eq "hadoop") {
      $THRAXDIR = "thrax";

      $thrax_input = "$DATA_DIRS{train}/thrax-input-file"

    } else {
      $THRAXDIR = "pipeline-$SOURCE-$TARGET-$GRAMMAR_TYPE-$RUNDIR";
      $THRAXDIR =~ s#/#_#g;

      $cachepipe->cmd("thrax-prep",
                      "$HADOOP/bin/hadoop fs -rmr $THRAXDIR; $HADOOP/bin/hadoop fs -mkdir $THRAXDIR; $HADOOP/bin/hadoop fs -put $DATA_DIRS{train}/thrax-input-file $THRAXDIR/input-file",
                      "$DATA_DIRS{train}/thrax-input-file", 
                      "grammar.gz");

      $thrax_input = "$THRAXDIR/input-file";
    }

    # copy the thrax config file
    my $thrax_file = "thrax-$GRAMMAR_TYPE.conf";
    system("grep -v ^input-file $THRAX_CONF_FILE > $thrax_file.tmp");
    system("echo input-file $thrax_input >> $thrax_file.tmp");
    system("mv $thrax_file.tmp $thrax_file");

    $cachepipe->cmd("thrax-run",
                    "$HADOOP/bin/hadoop jar $THRAX/bin/thrax.jar -D mapred.child.java.opts='-Xmx$HADOOP_MEM' $thrax_file $THRAXDIR > thrax.log 2>&1; rm -f grammar grammar.gz; $HADOOP/bin/hadoop fs -getmerge $THRAXDIR/final/ grammar.gz",
#                    "$HADOOP/bin/hadoop jar $THRAX/bin/thrax.jar -D mapred.child.java.opts='-Xmx$HADOOP_MEM' $thrax_file $THRAXDIR > thrax.log 2>&1; rm -f grammar grammar.gz; $HADOOP/bin/hadoop fs -getmerge $THRAXDIR/final/ grammar.gz; $HADOOP/bin/hadoop fs -rmr $THRAXDIR",
                    "$DATA_DIRS{train}/thrax-input-file",
                    $thrax_file,
                    "grammar.gz");
#perl -pi -e 's/\.?0+\b//g' grammar; 

    stop_hadoop_cluster() if $HADOOP eq "hadoop";

    # cache the thrax-prep step, which depends on grammar.gz
    if ($HADOOP ne "hadoop") {
      $cachepipe->cmd("thrax-prep", "--cache-only");
    }

    # clean up
    # TODO: clean up real hadoop clusters too
    # if ($HADOOP eq "hadoop") {
    #   system("rm -rf $THRAXDIR hadoop hadoop-0.20.2");
    # }

    $GRAMMAR_FILE = "grammar.gz";
  } else {

    print STDERR "* FATAL: There was no way to build a grammar, and none was passed in\n";
    print STDERR "*        Please try one of the following:\n";
    print STDERR "*        - Specify a grammar with --grammar /path/to/grammar\n";
    print STDERR "*        - Delete any existing grammar named 'grammar.gz'\n";

    exit 1;
  }
}

maybe_quit("THRAX");
maybe_quit("GRAMMAR");

## TUNING ##############################################################
TUNE:
    ;

# prep the tuning data, unless already prepped
if (! $PREPPED{TUNE} and $DO_PREPARE_CORPORA) {
  my $prefixes = prepare_data("tune",[$TUNE],$MAXLEN_TUNE);
  $TUNE{source} = "$DATA_DIRS{tune}/$prefixes->{lowercased}.$SOURCE";
  $TUNE{target} = "$DATA_DIRS{tune}/$prefixes->{lowercased}.$TARGET";
  $PREPPED{TUNE} = 1;
}

sub compile_lm($) {
  my $lmfile = shift;
  if ($LM_TYPE eq "kenlm") {
    my $kenlm_file = basename($lmfile, ".gz") . ".kenlm";
    $cachepipe->cmd("compile-kenlm",
                    "$JOSHUA/src/joshua/decoder/ff/lm/kenlm/build_binary $lmfile $kenlm_file",
                    $lmfile, $kenlm_file);
    return $kenlm_file;

  } elsif ($LM_TYPE eq "berkeleylm") {
    my $berkeleylm_file = basename($lmfile, ".gz") . ".berkeleylm";
    $cachepipe->cmd("compile-berkeleylm",
                    "java -cp $JOSHUA/lib/berkeleylm.jar -server -mx$BUILDLM_MEM edu.berkeley.nlp.lm.io.MakeLmBinaryFromArpa $lmfile $berkeleylm_file",
                    $lmfile, $berkeleylm_file);
    return $berkeleylm_file;

  } else {
    print "* FATAL: trying to compile an LM to neither kenlm nor berkeleylm.";
    exit 2;
  }
}

# Build the language model if needed
if ($DO_BUILD_LM_FROM_CORPUS) {

  # make sure the training data is prepped
  if (! $PREPPED{TRAIN} and $DO_PREPARE_CORPORA) {
		my $prefixes = prepare_data("train",\@CORPORA,$MAXLEN);

		$TRAIN{prefix} = "$DATA_DIRS{train}/corpus";
		foreach my $lang ($SOURCE,$TARGET) {
			system("ln -sf $prefixes->{lowercased}.$lang $DATA_DIRS{train}/corpus.$lang");
		}
		$TRAIN{source} = "$DATA_DIRS{train}/corpus.$SOURCE";
		$TRAIN{target} = "$DATA_DIRS{train}/corpus.$TARGET";
		$PREPPED{TRAIN} = 1;
  }

  if (! -e $TRAIN{target}) {
		print "* FATAL: I need a training corpus to build the language model from (--corpus)\n";
		exit(1);
  }

  my $lmfile = "lm.gz";

  # sort and uniq the training data
  $cachepipe->cmd("lm-sort-uniq",
                  "$CAT $TRAIN{target} | sort -u -T $TMPDIR -S $BUILDLM_MEM | gzip -9n > $TRAIN{target}.uniq",
                  $TRAIN{target},
                  "$TRAIN{target}.uniq");

  # If an NER Tagger is specified, use that to annotate the corpus before 
  # sending it off to the LM
  my $ner_return = ner_annotate("$TRAIN{target}.uniq", "$TRAIN{target}.uniq.ner", $TARGET);
  if ($ner_return == 2) {
    $TRAIN{ner_lm} = 1;
  }

  my $lm_input = "$TRAIN{target}.uniq";
  # Choose LM input based on whether an annotated corpus was created
  if (defined $TRAIN{ner_lm}) {
    $lm_input = replace_tokens_with_types("$TRAIN{target}.uniq.ner");
  }

  if ($LM_GEN eq "srilm") {
		my $smoothing = ($WITTEN_BELL) ? "-wbdiscount" : "-kndiscount";
		$cachepipe->cmd("srilm",
										"$SRILM -order $LM_ORDER -interpolate $smoothing -unk -gt3min 1 -gt4min 1 -gt5min 1 -text $TRAIN{target}.uniq $LM_OPTIONS -lm lm.gz",
                    "$lm_input",
										$lmfile);
  } elsif ($LM_GEN eq "berkeleylm") {
		$cachepipe->cmd("berkeleylm",
										"java -ea -mx$BUILDLM_MEM -server -cp $JOSHUA/lib/berkeleylm.jar edu.berkeley.nlp.lm.io.MakeKneserNeyArpaFromText $LM_ORDER lm.gz $TRAIN{target}.uniq",
                    "$lm_input",
										$lmfile);
  } else {
    # Make sure it exists
    if (! -e "$JOSHUA/bin/lmplz") {
      print "* FATAL: $JOSHUA/bin/lmplz (for building LMs) does not exist.\n";
      print "  This is often a problem with the boost libraries (particularly threaded\n";
      print "  versus unthreaded).\n";
      exit 1;
    }

    # Needs to be capitalized
    my $mem = uc $BUILDLM_MEM;
    $cachepipe->cmd("kenlm",
                    "$JOSHUA/bin/lmplz -o $LM_ORDER -T $TMPDIR -S $mem --verbose_header --text $TRAIN{target}.uniq $LM_OPTIONS | gzip -9n > lm.gz",
                    "$TRAIN{target}.uniq",
                    $lmfile);
  }

  if ((! $MERGE_LMS) && ($LM_TYPE eq "kenlm" || $LM_TYPE eq "berkeleylm")) {
    push (@LMFILES, get_absolute_path(compile_lm $lmfile, $RUNDIR));
  } else {
    push (@LMFILES, get_absolute_path($lmfile, $RUNDIR));
  }
}

if ($DO_BUILD_CLASS_LM) {
  # Build a Class LM
  # First check to see if an class map and class corpus are defined
  if (! defined $CLASS_LM_CORPUS or ! defined $CLASS_MAP) {
    print "* FATAL: A class LM corpus (--class-lm-corpus) and a class map (--class-map) are required with the --class-lm switch";
    exit 1;
  }
  if (! -e $CLASS_LM_CORPUS or ! -e $CLASS_MAP) {
    print "* FATAL: Could not find the Class LM corpus or map";
    exit 1;
  }
  if (! -e "$JOSHUA/bin/lmplz") {
    print "* FATAL: $JOSHUA/bin/lmplz (for building LMs) does not exist.\n";
    print "  This is often a problem with the boost libraries (particularly threaded\n";
    print "  versus unthreaded).\n";
    exit 1;
  }

  # Needs to be capitalized
  my $mem = uc $BUILDLM_MEM;
  my $class_lmfile = "class_lm.gz";
  $cachepipe->cmd("kenlm",
                  "$JOSHUA/bin/lmplz -o $LM_ORDER -T $TMPDIR -S $mem --discount_fallback=0.5 1 1.5 --verbose_header --text $CLASS_LM_CORPUS $LM_OPTIONS | gzip -9n > lm.gz",
                  "$CLASS_LM_CORPUS",
                  $class_lmfile);
}

if ($MERGE_LMS) {
  # Merge @LMFILES.
  my $merged_lm = "lm-merged.gz";
  print "@LMFILES";
  $cachepipe->cmd("merge-lms",
                  "$JOSHUA/scripts/support/merge_lms.py "
                    . "@LMFILES "
                    . "$TUNE{target} "
                    . "lm-merged.gz "
                    . "--temp-dir data/merge_lms ",
                  @LMFILES,
                  $merged_lm);

  # Empty out @LMFILES.
  @LMFILES = ();

  # Compile merged LM
  if ($LM_TYPE eq "kenlm" || $LM_TYPE eq "berkeleylm") {
    push (@LMFILES, get_absolute_path(compile_lm $merged_lm, $RUNDIR));

  } else {
    push (@LMFILES, get_absolute_path($merged_lm, $RUNDIR));
  }
}

system("mkdir -p $DATA_DIRS{tune}") unless -d $DATA_DIRS{tune};

# figure out how many references there are
my $numrefs = get_numrefs($TUNE{target});

# make sure the dev source exist
if (! -e $TUNE{source}) {
  print STDERR "* FATAL: couldn't fine tuning source file '$TUNE{source}'\n";
  exit 1;
}
if ($numrefs > 1) {
  for my $i (0..$numrefs-1) {
		if (! -e "$TUNE{target}.$i") {
			print STDERR "* FATAL: couldn't find tuning reference file '$TUNE{target}.$i'\n";
			exit 1;
		}
  }
} else {
  if (! -e $TUNE{target}) {
		print STDERR "* FATAL: couldn't find tuning reference file '$TUNE{target}'\n";
		exit 1;
  }
}

# Set $TUNE_GRAMMAR to a specifically-passed tuning grammar or the
# main default grammar. Then update it if filtering was requested and
# is possible.
my $TUNE_GRAMMAR = $_TUNE_GRAMMAR_FILE || $GRAMMAR_FILE;
if ($DO_FILTER_TM and ! $DOING_LATTICES and ! defined $_TUNE_GRAMMAR_FILE) {
  $TUNE_GRAMMAR = "$DATA_DIRS{tune}/grammar.filtered.gz";

  $cachepipe->cmd("filter-tune",
									"$SCRIPTDIR/support/filter_grammar.sh -g $GRAMMAR_FILE $FILTERING -v $TUNE{source} | $SCRIPTDIR/training/filter-rules.pl -bus$SCOPE | gzip -9n > $TUNE_GRAMMAR",
									$GRAMMAR_FILE,
									$TUNE{source},
									$TUNE_GRAMMAR);
}

# Create the glue grammars. This is done by looking at all the symbols in the grammar file and
# creating all the needed rules.
if (! defined $GLUE_GRAMMAR_FILE) {
  $cachepipe->cmd("glue-tune",
                  "java -Xmx2g -cp $JOSHUA/lib/*:$THRAX/bin/thrax.jar edu.jhu.thrax.util.CreateGlueGrammar $TUNE_GRAMMAR > $DATA_DIRS{tune}/grammar.glue",
                  $TUNE_GRAMMAR,
                  "$DATA_DIRS{tune}/grammar.glue");
  $GLUE_GRAMMAR_FILE = "$DATA_DIRS{tune}/grammar.glue";
} else {
  # just create a symlink to it
  my $filename = $DATA_DIRS{tune} . "/" . basename($GLUE_GRAMMAR_FILE);
  system("ln -sf $GLUE_GRAMMAR_FILE $filename");
}

# Add in feature functions
my $weightstr = "";
my @feature_functions;
for my $i (0..$#LMFILES) {
  if ($LM_STATE_MINIMIZATION) {
    push(@feature_functions, "StateMinimizingLanguageModel -lm_order $LM_ORDER -lm_file $LMFILES[$i]");
  } else {
    push(@feature_functions, "LanguageModel -lm_type $LM_TYPE -lm_order $LM_ORDER -lm_file $LMFILES[$i]");
  }

  $weightstr .= "lm_$i 1 ";
}

if ($DOING_LATTICES) {
  push(@feature_functions, "SourcePath");
}
if ($GRAMMAR_TYPE eq "phrase") {
  push(@feature_functions, "Distortion");
  push(@feature_functions, "PhrasePenalty");
}
my $feature_functions = join(" ", map { "-feature-function \"$_\"" } @feature_functions);

# Build out the weight string
my $TM_OWNER = "pt";
my $GLUE_OWNER = "glue";
{
  my @tm_features = get_features($TUNE_GRAMMAR);
  foreach my $feature (@tm_features) {
    # Only assign initial weights to dense features
    $weightstr .= "tm_${TM_OWNER}_$feature 1 " if ($feature =~ /^\d+$/);
  }
  # Glue grammar
  $weightstr .= "tm_${GLUE_OWNER}_0 1 ";
}

my $tm_type = $GRAMMAR_TYPE;
if ($GRAMMAR_TYPE eq "phrase") {
  $tm_type = "moses";
}

sub get_file_from_grammar {
  # Cachepipe doesn't work on directories, so we need to make sure we
  # have a representative file to use to cache grammars.
  my ($grammar_file) = @_;
  my $file = (-d $grammar_file) ? "$grammar_file/slice_00000.source" : $grammar_file;
  return $file;
}

# Build the filtered tuning model
my $tm_switch = ($DO_PACK_GRAMMARS) ? "--pack-tm" : "--tm";
$cachepipe->cmd("tune-bundle",
                "$BUNDLER --force --verbose $JOSHUA_CONFIG tune/model --copy-config-options '-top-n $NBEST -mark-oovs false -tm0/type $tm_type -tm0/owner ${TM_OWNER} -tm0/maxspan $MAXSPAN -tm1/owner ${GLUE_OWNER} -search $SEARCH_ALGORITHM -weights \"$weightstr\" $feature_functions' ${tm_switch} $TUNE_GRAMMAR --tm $GLUE_GRAMMAR_FILE",
                $JOSHUA_CONFIG,
                get_file_from_grammar($TUNE_GRAMMAR),  # in case it's packed
                "tune/model/joshua.config");
{
  # Now update the tuning grammar
  my $basename = basename($TUNE_GRAMMAR);
  if (-e "tune/model/$basename") {
    $TUNE_GRAMMAR = "tune/model/$basename";
  } elsif (-e "tune/model/$basename.packed") {
    $TUNE_GRAMMAR = "tune/model/$basename.packed";
  } else {
    print STDERR "* FATAL: tune model bundling didn't produce a grammar?";
    exit 1;
  }
}

my $tunedir = "$RUNDIR/tune";
system("mkdir -p $tunedir") unless -d $tunedir;

# Write the decoder run command
open DEC_CMD, ">$tunedir/decoder_command";
print DEC_CMD "cat $TUNE{source} | $tunedir/model/run-joshua.sh -m $JOSHUA_MEM -threads $NUM_THREADS $JOSHUA_ARGS > $tunedir/tune.output.nbest 2> $tunedir/joshua.log\n";
close(DEC_CMD);
chmod(0755,"$tunedir/decoder_command");

# tune
if ($TUNER eq "mert") {
  $cachepipe->cmd("mert",
                  "java -d64 -Xmx$TUNER_MEM -cp $JOSHUA/class joshua.zmert.ZMERT -maxMem 4000 $tunedir/mert.config > $tunedir/mert.log 2>&1",
                  get_file_from_grammar($TUNE_GRAMMAR),
                  "$tunedir/joshua.config.ZMERT.final",
                  "$tunedir/decoder_command",
                  "$tunedir/mert.config",
                  "$tunedir/params.txt");
  system("ln -sf joshua.config.ZMERT.final $tunedir/joshua.config.final");
} elsif ($TUNER eq "pro") {
  $cachepipe->cmd("pro",
                  "java -d64 -Xmx$TUNER_MEM -cp $JOSHUA/class joshua.pro.PRO -maxMem 4000 $tunedir/pro.config > $tunedir/pro.log 2>&1",
                  get_file_from_grammar($TUNE_GRAMMAR),
                  "$tunedir/joshua.config.PRO.final",
                  "$tunedir/decoder_command",
                  "$tunedir/pro.config",
                  "$tunedir/params.txt");
  system("ln -sf joshua.config.PRO.final $tunedir/joshua.config.final");
} elsif ($TUNER eq "mira") {
  my $refs_path = $TUNE{target};
  $refs_path .= "." if (get_numrefs($TUNE{target}) > 1);

  my $extra_args = $JOSHUA_ARGS;
  $extra_args =~ s/"/\\"/g;
  $cachepipe->cmd("mira",
                  "$SCRIPTDIR/training/mira/run-mira.pl --mertdir $MOSES/bin --rootdir $MOSES/scripts --batch-mira --working-dir $tunedir --maximum-iterations $MIRA_ITERATIONS --nbest $NBEST --no-filter-phrase-table --decoder-flags \"-m $JOSHUA_MEM -threads $NUM_THREADS -moses $extra_args\" $TUNE{source} $refs_path $tunedir/model/run-joshua.sh $tunedir/model/joshua.config > $tunedir/mira.log 2>&1",
                  get_file_from_grammar($TUNE_GRAMMAR),
                  $TUNE{source},
                  "$tunedir/joshua.config.final");
}

$JOSHUA_CONFIG = "$tunedir/joshua.config.final";

# Go to the next tuning run if tuning is the last step.
if ($LAST_STEP eq "TUNE") {
  next;
}


#################################################################
## TESTING ######################################################
#################################################################

TEST:
    ;

# prepare the testing data
if (! $PREPPED{TEST} and $DO_PREPARE_CORPORA) {
  my $prefixes = prepare_data("test",[$TEST],$MAXLEN_TEST);
  $TEST{source} = "$DATA_DIRS{test}/$prefixes->{lowercased}.$SOURCE";
  $TEST{target} = "$DATA_DIRS{test}/$prefixes->{lowercased}.$TARGET";
  $PREPPED{TEST} = 1;
}

# filter the test grammar
system("mkdir -p $DATA_DIRS{test}") unless -d $DATA_DIRS{test};
my $TEST_GRAMMAR = $_TEST_GRAMMAR_FILE || $GRAMMAR_FILE;
if ($DO_FILTER_TM and ! $DOING_LATTICES and ! defined $_TEST_GRAMMAR_FILE) {
  $TEST_GRAMMAR = "$DATA_DIRS{test}/grammar.filtered.gz";
  
  $cachepipe->cmd("filter-test",
                  "$SCRIPTDIR/support/filter_grammar.sh -g $GRAMMAR_FILE $FILTERING -v $TEST{source} | $SCRIPTDIR/training/filter-rules.pl -bus$SCOPE | gzip -9n > $TEST_GRAMMAR",
                  $GRAMMAR_FILE,
                  $TEST{source},
                  $TEST_GRAMMAR);
}

my $testdir = "$RUNDIR/test";

# Create the glue file.
if (! defined $GLUE_GRAMMAR_FILE) {
  $cachepipe->cmd("glue-test",
                  "java -Xmx1g -cp $JOSHUA/lib/*:$THRAX/bin/thrax.jar edu.jhu.thrax.util.CreateGlueGrammar $TEST_GRAMMAR > $DATA_DIRS{test}/grammar.glue",
                  $TEST_GRAMMAR,
                  "$DATA_DIRS{test}/grammar.glue");
  $GLUE_GRAMMAR_FILE = "$DATA_DIRS{test}/grammar.glue";
  
} else {
  # just create a symlink to it
  my $filename = $DATA_DIRS{test} . "/" . basename($GLUE_GRAMMAR_FILE);
  if ($GLUE_GRAMMAR_FILE =~ /^\//) {
    system("ln -sf $GLUE_GRAMMAR_FILE $filename");
  } else {
    system("ln -sf $STARTDIR/$GLUE_GRAMMAR_FILE $filename");
  }
}

# Build the filtered testing model
$cachepipe->cmd("test-bundle",
                "$BUNDLER --force --verbose $JOSHUA_CONFIG test/model --copy-config-options '-top-n $NBEST -output-format \"%i ||| %s ||| %f ||| %c\" -mark-oovs false' ${tm_switch} $TEST_GRAMMAR --tm $GLUE_GRAMMAR_FILE",
                $JOSHUA_CONFIG,
                get_file_from_grammar($TEST_GRAMMAR),
                "$testdir/model/joshua.config");

{
  # Update some variables. $TEST_GRAMMAR_FILE, which previously held
  # an optional command-line argument of a pre-filtered tuning
  # grammar, is now used to record the text-based grammar, which is
  # needed later for different things.
  my $basename = basename($TEST_GRAMMAR);
  if (-e "$testdir/model/$basename") {
    $TEST_GRAMMAR = "$testdir/model/$basename";
  } elsif (-e "$testdir/model/$basename.packed") {
    $TEST_GRAMMAR = "$testdir/model/$basename.packed";
  } else {
    print STDERR "* FATAL: test model bundling didn't produce a grammar?";
    exit 1;
  }
}

my $testrun = get_absolute_path("test", $RUNDIR);
my $bestoutput = "$testrun/output";
my $nbestoutput = "$testrun/output.nbest";
my $output;

# If we're decoding a lattice, also output the source side path we chose
$JOSHUA_ARGS = $_JOSHUA_ARGS;
if ($DOING_LATTICES) {
  $JOSHUA_ARGS .= " -maxlen 0 -output-format \"%i ||| %s ||| %e ||| %f ||| %c\"";
}

if ($DO_MBR) {
  $JOSHUA_ARGS .= " -top-n $NBEST -output-format \"%i ||| %s ||| %f ||| %c\"";
  $output = $nbestoutput;
} else {
  $JOSHUA_ARGS .= " -top-n 0 -output-format %s";
  $output = $bestoutput;
}

# Write the decoder run command
open DEC_CMD, ">$testrun/decoder_command";
print DEC_CMD "cat $TEST{source} | $testrun/model/run-joshua.sh -m $JOSHUA_MEM -threads $NUM_THREADS $JOSHUA_ARGS > $output 2> $testrun/joshua.log\n";
close(DEC_CMD);
chmod(0755,"$testrun/decoder_command");

# Decode. $output here is either $nbestoutput (if doing MBR decoding, in which case we'll
# need the n-best output) or $bestoutput (which only outputs the hypothesis but is tons faster)
$cachepipe->cmd("test-decode",
                "$testrun/decoder_command",
                "$testrun/decoder_command",
                $TEST{source},
                "$testrun/model/joshua.config",
                get_file_from_grammar($TEST_GRAMMAR),
                $output);

# $cachepipe->cmd("remove-oov",
#                 "cat $testoutput | perl -pe 's/_OOV//g' > $testoutput.noOOV",
#                 $testoutput,
#                 "$testoutput.noOOV");

# Extract the 1-best output from the n-best file if the n-best file alone was output
if ($DO_MBR) {
  $cachepipe->cmd("test-extract-onebest",
                  "java -Xmx500m -cp $JOSHUA/class -Dfile.encoding=utf8 joshua.util.ExtractTopCand $nbestoutput $bestoutput",
                  $nbestoutput,
                  $bestoutput);
}  

# Now compute the BLEU score on the 1-best output
$cachepipe->cmd("test-bleu",
                "$JOSHUA/bin/bleu $output $TEST{target} > $testrun/bleu",
                $bestoutput,
                "$testrun/bleu");

# Update the BLEU summary.
compute_bleu_summary("$testrun/bleu", "$testrun/final-bleu");

if ($DO_MBR) {
  my $numlines = `cat $TEST{source} | wc -l`;
  $numlines--;
  my $mbr_output = "$testrun/output.mbr";

  $cachepipe->cmd("test-onebest-parmbr", 
                  "cat $nbestoutput | java -Xmx1700m -cp $JOSHUA/class -Dfile.encoding=utf8 joshua.decoder.NbestMinRiskReranker false 1 $NUM_THREADS > $mbr_output",
                  $nbestoutput,
                  $mbr_output);

  $cachepipe->cmd("test-bleu-mbr",
                  "$JOSHUA/bin/bleu output $TEST{target} $numrefs > $testrun/bleu.mbr",
                  $mbr_output,
                  "$testrun/bleu.mbr");

  compute_bleu_summary("$testrun/bleu.mbr", "$testrun/final-bleu-mbr");
}

compute_time_summary("$testrun/joshua.log", "$testrun/final-times");

# Now do the analysis
if ($DOING_LATTICES) {
  # extract the source
  my $source = "$testrun/test.lattice-path.txt";
  $cachepipe->cmd("test-lattice-extract-source",
                  "$JOSHUA/bin/extract-1best $nbestoutput 2 | perl -pe 's/<s> //' > $source",
                  $nbestoutput, $source);

  analyze_testrun($bestoutput,$source,$TEST{target});
} else {
  analyze_testrun($bestoutput,$TEST{source},$TEST{target});
}


######################################################################
## SUBROUTINES #######################################################
######################################################################
LAST:
		1;

# Does tokenization and normalization of training, tuning, and test data.
# $label: one of train, tune, or test
# $corpora: arrayref of files (multiple allowed for training data)
# $maxlen: maximum length (only applicable to training)
sub prepare_data {
  my ($label,$corpora,$maxlen) = @_;
  $maxlen = 0 unless defined $maxlen;

  system("mkdir -p $DATA_DIR") unless -d $DATA_DIR;
  system("mkdir -p $DATA_DIRS{$label}") unless -d $DATA_DIRS{$label};

  # records the pieces that are produced
  my %prefixes;

  # copy the data from its original location to our location
	my $numlines = -1;
  foreach my $ext ($TARGET,$SOURCE,"$TARGET.0","$TARGET.1","$TARGET.2","$TARGET.3") {
    # append each extension to the corpora prefixes
    my @files = map { "$_.$ext" } @$corpora;

		# This block makes sure that the files have a nonzero file size
		map {
			if (-z $_) {
				print STDERR "* FATAL: $label file '$_' is empty";
				exit 1;
			}
		} @files;

    # a list of all the files (in case of multiple corpora prefixes)
    my $files = join(" ",@files);
    if (-e $files[0]) {
      $cachepipe->cmd("$label-copy-$ext",
                      "cat $files | gzip -9n > $DATA_DIRS{$label}/$label.$ext.gz",
                      @files, "$DATA_DIRS{$label}/$label.$ext.gz");

			chomp(my $lines = `$CAT $DATA_DIRS{$label}/$label.$ext.gz | wc -l`);
			$numlines = $lines if ($numlines == -1);
			if ($lines != $numlines) {
				print STDERR "* FATAL: $DATA_DIRS{$label}/$label.$ext.gz has a different number of lines ($lines) than a 'parallel' file that preceded it ($numlines)\n";
				exit(1);
			}
		}
  }

  my $prefix = "$label";

  # tokenize the data
  foreach my $lang ($TARGET,$SOURCE,"$TARGET.0","$TARGET.1","$TARGET.2","$TARGET.3") {
		if (-e "$DATA_DIRS{$label}/$prefix.$lang.gz") {
			if (is_lattice("$DATA_DIRS{$label}/$prefix.$lang.gz")) { 
				system("cp $DATA_DIRS{$label}/$prefix.$lang.gz $DATA_DIRS{$label}/$prefix.tok.$lang.gz");
			} else {
        my $TOKENIZER = ($lang eq $SOURCE) ? $TOKENIZER_SOURCE : $TOKENIZER_TARGET;
	my $ext = $lang; $ext =~ s/\.\d//;
				$cachepipe->cmd("$label-tokenize-$lang",
												"$CAT $DATA_DIRS{$label}/$prefix.$lang.gz | $NORMALIZER $ext | $TOKENIZER -l $ext 2> /dev/null | gzip -9n > $DATA_DIRS{$label}/$prefix.tok.$lang.gz",
												"$DATA_DIRS{$label}/$prefix.$lang.gz", "$DATA_DIRS{$label}/$prefix.tok.$lang.gz");
			}

		}
  }
  # extend the prefix
  $prefix .= ".tok";
  $prefixes{tokenized} = $prefix;

  if ($maxlen > 0) {
    my (@infiles, @outfiles);
    foreach my $ext ($TARGET, $SOURCE, "$TARGET.0", "$TARGET.1", "$TARGET.2", "$TARGET.3") {
      my $infile = "$DATA_DIRS{$label}/$prefix.$ext.gz";
      my $outfile = "$DATA_DIRS{$label}/$prefix.$maxlen.$ext.gz";
      if (-e $infile) {
        push(@infiles, $infile);
        push(@outfiles, $outfile);
      }
    }

    my $infilelist = join(" ", map { "<(gzip -cd $_)" } @infiles);
    my $outfilelist = join(" ", @outfiles);

		# trim training data
		$cachepipe->cmd("$label-trim",
										"paste $infilelist | $SCRIPTDIR/training/trim_parallel_corpus.pl $maxlen | $SCRIPTDIR/training/split2files.pl $outfilelist",
                    @infiles,
                    @outfiles);
		$prefix .= ".$maxlen";
  }
  # record this whether we shortened or not
  $prefixes{shortened} = $prefix;

  # lowercase
  foreach my $lang ($TARGET,$SOURCE,"$TARGET.0","$TARGET.1","$TARGET.2","$TARGET.3") {
		if (-e "$DATA_DIRS{$label}/$prefix.$lang.gz") {
			if (is_lattice("$DATA_DIRS{$label}/$prefix.$lang.gz")) { 
				system("gzip -cd $DATA_DIRS{$label}/$prefix.$lang.gz > $DATA_DIRS{$label}/$prefix.lc.$lang");
			} else { 
				$cachepipe->cmd("$label-lowercase-$lang",
												"gzip -cd $DATA_DIRS{$label}/$prefix.$lang.gz | $SCRIPTDIR/lowercase.perl > $DATA_DIRS{$label}/$prefix.lc.$lang",
												"$DATA_DIRS{$label}/$prefix.$lang.gz",
												"$DATA_DIRS{$label}/$prefix.lc.$lang");
			}
		}
  }
  $prefix .= ".lc";
  $prefixes{lowercased} = $prefix;

  foreach my $lang ($TARGET,$SOURCE,"$TARGET.0","$TARGET.1","$TARGET.2","$TARGET.3") {
		if (-e "$DATA_DIRS{$label}/$prefixes{lowercased}.$lang") {
      system("ln -sf $prefixes{lowercased}.$lang $DATA_DIRS{$label}/corpus.$lang");
    }
  }

  if ($label eq "train") {
    foreach my $lang ($TARGET, $SOURCE) {
      $cachepipe->cmd("$label-vocab-$lang",
                      "cat $DATA_DIRS{$label}/corpus.$lang | $SCRIPTDIR/training/build-vocab.pl > $DATA_DIRS{$label}/vocab.$lang",
                      "$DATA_DIRS{$label}/corpus.$lang",
                      "$DATA_DIRS{$label}/vocab.$lang");
    }
  }

  return \%prefixes;
}

sub maybe_quit {
  my ($current_step) = @_;

  if (defined $LAST_STEP and $current_step eq $LAST_STEP) {
		print "* Quitting at this step\n";
		exit(0);
  }
}

## returns 1 if every sentence in the corpus begins with an open paren,
## false otherwise
sub already_parsed {
  my ($corpus) = @_;

  open(CORPUS, $corpus) or die "can't read corpus file '$corpus'\n";
  while (<CORPUS>) {
		# if we see a line not beginning with an open paren, we consider
		# the file not to be parsed
		return 0 unless /^\(/;
  }
  close(CORPUS);

  return 1;
}

sub not_defined {
  my ($var) = @_;

  print "* FATAL: environment variable \$$var is not defined.\n";
  exit;
}

# Takes a prefix.  If that prefix exists, then all the references are
# assumed to be in that file.  Otherwise, we successively append an
# index, looking for parallel references.
sub get_numrefs {
  my ($prefix) = @_;

  if (-e "$prefix.0") {
		my $index = 0;
		while (-e "$prefix.$index") {
			$index++;
		}
		return $index;
  } else {
		return 1;
  }
}

sub start_hadoop_cluster {
  rollout_hadoop_cluster();

  # start the cluster
  # system("./hadoop/bin/start-all.sh");
  # sleep(120);
}

sub rollout_hadoop_cluster {
  # if it's not already unpacked, unpack it
  if (! -d "hadoop") {

		system("tar xzf $JOSHUA/lib/hadoop-0.20.2.tar.gz");
		system("ln -sf hadoop-0.20.2 hadoop");
    if (defined $HADOOP_CONF) {
      print STDERR "Copying HADOOP_CONF($HADOOP_CONF) to hadoop/conf/core-site.xml\n";
      system("cp $HADOOP_CONF hadoop/conf/core-site.xml");
    }
  }
  
  $ENV{HADOOP} = $HADOOP = "hadoop";
  $ENV{HADOOP_CONF_DIR} = "";
}

sub stop_hadoop_cluster {
  if ($HADOOP ne "hadoop") {
		system("hadoop/bin/stop-all.sh");
  }
}

sub teardown_hadoop_cluster {
  stop_hadoop_cluster();
  system("rm -rf hadoop-0.20.2 hadoop");
}

sub is_lattice {
  my $file = shift;
  open READ, "$CAT $file|" or die "can't read from potential lattice '$file'";
  my $line = <READ>;
  close(READ);
  if ($line =~ /^\(\(\(/) {
		$DOING_LATTICES = 1;
		$FILTERING = "-l";
		return 1;
  } else {
		return 0;
  }
}

# This function retrieves the names of all the features in the grammar. Dense features
# are named with consecutive integers starting at 0, while sparse features can have any name.
# To get the feature names from an unpacked grammar, we have to read through the whole grammar,
# since sparse features can be anywhere. For packed grammars, this can be read directly from
# the encoding.
sub get_features {
  my ($grammar) = @_;

  if (-d $grammar) {
    chomp(my @features = `java -cp $JOSHUA/class joshua.util.encoding.EncoderConfiguration $grammar | grep ^feature: | awk '{print \$NF}'`);
    return @features;

  } elsif (-e $grammar) {
    my %features;
    open GRAMMAR, "$CAT $grammar|" or die "FATAL: can't read $grammar";
    while (my $line = <GRAMMAR>) {
      chomp($line);
      my @tokens = split(/ \|\|\| /, $line);
      # field 4 for regular grammars, field 3 for phrase tables
      my $feature_str = ($line =~ /^\[/) ? $tokens[3] : $tokens[2];
      my @features = split(' ', $feature_str);
      my $feature_no = 0;
      foreach my $feature (@features) {
        if ($feature =~ /=/) {
          my ($name) = split(/=/, $feature);
          $features{$name} = 1;
        } else {
          $features{$feature_no++} = 1;
        }
      } 
    }
    close(GRAMMAR);
    return keys(%features);
  }
}

# File names reflecting relative paths need to be absolute-ized for --rundir to work.
# Does not work with paths that do not exist!
sub get_absolute_path {
  my ($file,$basedir) = @_;
  $basedir = $STARTDIR unless defined $basedir;

  if (defined $file) {
    $file = "$basedir/$file" unless $file =~ /^\//;

    # prepend startdir (which is absolute) unless the path is absolute.
    my $abs_path = abs_path($file);
    if (defined $abs_path) {
      $file = $abs_path;
    }
  }

  return $file;
}

sub analyze_testrun {
  my ($output,$source,$reference) = @_;
  my $dir = dirname($output);

  mkdir("$dir/analysis") unless -d "$dir/analysis";

  my @references;
  if (-e "$reference.0") {
    my $num = 0;
    while (-e "$reference.$num") {
      push(@references, "$reference.$num");
      $num++;
    }
  } else {
    push(@references, $reference);
  }

  my $references = join(" -r ", @references);

  $cachepipe->cmd("analyze-test",
                  "$SCRIPTDIR/analysis/sentence-by-sentence.pl -s $source -r $references $output > $dir/analysis/sentence-by-sentence.html",
                  $output,
                  "$dir/analysis/sentence-by-sentence.html");
}

sub compute_bleu_summary {
  my ($filepattern, $outputfile) = @_;

  # Now average the runs, report BLEU
  my @bleus;
  my $numrecs = 0;
  open CMD, "grep ' BLEU = ' $filepattern |";
  while (<CMD>) {
    my @F = split;
    push(@bleus, 1.0 * $F[-1]);
  }
  close(CMD);

  if (scalar @bleus) {
    my $final_bleu = sum(@bleus) / (scalar @bleus);

    open BLEU, ">$outputfile" or die "Can't write to $outputfile";
    printf(BLEU "%s / %d = %.4f\n", join(" + ", @bleus), scalar @bleus, $final_bleu);
    close(BLEU);
  }
}

sub compute_time_summary {
  my ($filepattern, $outputfile) = @_;

  # Now average the runs, report BLEU
  my @times;
  foreach my $file (glob($filepattern)) {
    open FILE, $file;
    my $time = 0.0;
    my $numrecs = 0;
    while (<FILE>) {
      next unless /^Input \d+: Translation took/;
      my @F = split;
      $time += $F[4];
      $numrecs++;
    }
    close(FILE);

    push(@times, $time);
  }

  if (scalar @times) {
    open TIMES, ">$outputfile" or die "Can't write to $outputfile";
    printf(TIMES "%s / %d = %s\n", join(" + ", @times), scalar(@times), 1.0 * sum(@times) / scalar(@times));
    close(TIMES);
  }
}

sub is_packed {
  my ($grammar) = @_;

  if (-d $grammar && -e "$grammar/encoding") {
    return 1;
  }

  return 0;
}

sub ner_annotate {
  my ($inputfile, $outputfile, $lang) = @_;
  if (defined $NER_TAGGER) {
    # Check if NER tagger exists
    if (! -e $NER_TAGGER) {
      print "* FATAL: The specified NER tagger was not found";
      exit(1);
    }
    $cachepipe->cmd("ner-annotate", "$NER_TAGGER $inputfile $outputfile $lang");
    # Check if annotated file exists
    if (! -e "$outputfile") {
      print "* FATAL : The NER tagger did not create the required annotated file : $outputfile";
      exit(1);
    }
    return 2;
  }
  return 0;
}

sub replace_tokens_with_types {
  # Replace the tokens with types
  my ($inputfile) = @_;
  qx{sed -ir 's:\$([A-Za-z0-9]+)_\([^)]+\):\1:g' $inputfile}
}
