#!/usr/bin/env perl
# See usage

use strict;
use Getopt::Std;
use FileHandle;

use mismatch;

use vars qw($opt_h $opt_b $opt_m $opt_p $opt_o $opt_e $opt_g);

$opt_e=  '^cbc=([ACTGN]+)';

my $Usage="Usage:

   samtools view bigfile.bam | $0 -b barcodes.txt [ -g barcodegroups.txt ] [ -e $opt_e ] [-m mismatches] [ -p outputprefix ] [ -o outputdir ] 

Given a barcode file, demultiplexes a SAM file (on stdin) where the
barcode is expected in the QNAME (first field), and extracted from it
using a parenthesized regular expression indicated by the -e option.
As with the original demultiplex script, mismatches can be allowed
using the -m option.

Output files are written in bam format, with all the original headers. 

For format of the barcode file, see testdata/testbarcodes.txt.

To test, do e.g. 

  (see demultiplex.pl \@FIX)


NOTE: the script does *not* check if mismatched barcodes are unambiguous!
Use edit-distance.pl and/or edit-distance-matrix.pl for that.

Original copied from demultiplex.pl, 3bc1490195 (2016-10-19 17:40:41)
written by <plijnzaad\@gmail.com>
";

if ( !getopts("b:p:o:m:g:h") || ! $opt_b ||  $opt_h ) {
    die $Usage; 
}

my  $allowed_mismatches = 1;
$allowed_mismatches = $opt_m if defined($opt_m);  # 0 also possible, meaning no mismatched allowed

my $barcodes_mixedcase = mismatch::readbarcodes_mixedcase($opt_b); ## eg. $h->{'AGCGtT') => 'M3'
my $barcodes = mismatch::mixedcase2upper($barcodes_mixedcase);     ## e.g. $h->{'AGCGTT') => 'M3'
my $mismatch_REs = mismatch::convert2mismatchREs(barcodes=>$barcodes_mixedcase, 
                                                 allowed_mismatches =>$allowed_mismatches);# eg. $h->{'AGCGTT') =>  REGEXP(0x25a7788)
$barcodes_mixedcase=undef;

my $groups=undef;
$groups=read_groups($opt_g) if $opt_g;

my @files=();


if ($groups) { 
  my $occur; map {  $occur->{$_}++ } values %$groups;
  @files= (keys %$occur, 'UNKNOWN');
}else { 
  @files= (values %$barcodes, 'UNKNOWN');
}

my $filehandles=open_outfiles(@files);      # opens M3.fastq.gz, ambiguous.fastq.gz etc.

my $nexact=0;
my $nmismatched=0;                         # having at most $mismatch mismatches
my $nunknown=0;

my $barcode_re = qr/$opt_e/;


## lastly, process the actual input:
RECORD:
while(1) { 
  my $record=<>;

  if ($record =~ /^@/) {                # header line, needed by all files
    for my $lib (keys %$filehandles) { 
      $filehandles->{$lib}->print($record);
    }
    next RECORD;
  }

## e.g. ^NS500413:188:H3M3WBGXY:1:11101:10124:1906:cbc=TACCTGTC:umi=TTCGAC \t 0 \t GLUL__chr1 \t 3255 \t 25 \t 76M \t 
  my($qname,$flag, $rname, $pos, $mapq, $cigar, $rnext, $pnext, $tlen,
     $seq, $qual, @optionals)=split("\t", $record);

  my(@parts)=
      my $foundcode;
  for my $part (split(":", $qname)) {
    $foundcode=$1 if $part =~ $barcode_re;
  }
  die "could not find barcode in QNAME '$qname', expected /$barcode_re/, line $." unless $foundcode;
  my $lib;
 CASE:
  while(1) {
    $lib=$barcodes->{$foundcode};       # majority of cases
    if ($lib) {
      $nexact++;
      last CASE;
    }
    if (! $allowed_mismatches) {
      $nunknown++;
      $lib='UNKNOWN';
      last CASE;
    }
    my $correction = mismatch::rescue($foundcode, $mismatch_REs);
    if($correction) {
      $lib=$barcodes->{$correction};
      $nmismatched++;
      last CASE;
    } else { 
      $nunknown++;
      $lib='UNKNOWN';
      last CASE;
    }
    die "should not reach this point";
  }                                     # CASE
  $lib= $groups->{$lib} if $groups;
  $lib = 'UNKNOWN' unless $lib;

  $filehandles->{$lib}->print($record);
  last RECORD if (eof(STDIN) || !$record);
}                                       # RECORD
close_outfiles($filehandles);

sub commafy {
  # insert comma's to separate powers of 1000
  my($i)=@_;
  my $r = join('',reverse(split('',$i)));
  $r =~ s/(\d{3})/$1,/g;
  $r =~ s/,$//;
  join('',reverse(split('',$r)));
}

warn sprintf("exact: %s\nmismatched: %s\nunknown: %s\n", 
             map { commafy $_ } ($nexact, $nmismatched, $nunknown ));

sub open_infile {
  die "not used nor tested";
  my($file)=@_;
  my $fh=FileHandle->new();
  if ($file =~ /\.gz/) { 
    $fh->open("zcat $file | ", "r")  or die "'$file': $!";
  } else { 
    $fh->open("< $file")  or die "'$file': $!";
  }
  $fh;
}

sub open_outfiles { 
  my(@libs)=@_;
  my $fhs={};

  for my $lib (@libs) { 
    my $name=sprintf("%s.bam", $lib);
    $name="$opt_p$name" if $opt_p;
    $name="$opt_o/$name" if $opt_o;
    my $fh = FileHandle->new(" | samtools view - -h -b > $name") or die "library $lib, file $name: $! (did you create the output directory?)";
    warn "Creating/overwriting file $name ...\n";
    $fhs->{$lib}=$fh;
  }
  $fhs;
}                                       # open_outfiles

sub close_outfiles {
  my($fhs)=@_;
  for my $lib (keys %$fhs) {
    $fhs->{$lib}->close() or die "could not close (or open?) demultiplexed bam file for library $lib; investigate";
  }
}

sub read_groups { 
  #return hash mapping barcode to group
  my($file)=@_;
  open(FILE, $file) || die "$0: $file: $!";
  my $groups={};

  while(<FILE>) { 
    s/#.*//;
    s/[\r\n]*$//;
    next unless /\S+\s+\S+/;
    my($barcode,$group)=split(' ',$_);
    die "barcode $barcode not unique in group file $file, line $.," if $groups->{$barcode};
    $groups->{$barcode}=$group;
  }
  close(FILE);
  $groups;
}
