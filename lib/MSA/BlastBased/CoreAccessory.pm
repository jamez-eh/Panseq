#!/usr/bin/perl

package MSA::BlastBased::CoreAccessory;

#includes
use strict;
use warnings;
use diagnostics;
use FindBin;
use lib "$FindBin::Bin";
use IO::File;
use FileInteraction::Fasta::SequenceName;
use Parallel::ForkManager;
use File::Path qw{make_path remove_tree};
use Blast::FormatBlastDB;
use Blast::BlastIO;
use Blast::BlastParallel;
use Carp;
use FileInteraction::Fasta::FastaFileSplitter;
use FileInteraction::FileManipulation;
use NovelRegion::NovelRegionFinder;
use MSA::BlastBased::CoreAccessoryProcessor;
use TreeBuilding::PhylogenyFileCreator;
use FileInteraction::Fasta::SequenceRetriever;

use parent 'Pipeline::PanseqShared';

sub new{
	my $class = shift;
	my $self= $class->SUPER::new(@_); #this calls PanseqShared::_initialize, so need to call the SUPER::_initialize
	return $self;
}

sub _percentIdentityCutoff{
	my $self=shift;
	$self->{'_CoreAccessory_percentIdentityCutoff'}=shift // return $self->{'_CoreAccessory_percentIdentityCutoff'};
}

sub _coreGenomeThreshold{
	my $self=shift;
	$self->{'_CoreAccessory_coreGenomeThreshold'}=shift // return $self->{'_CoreAccessory_coreGenomeThreshold'};
}

sub _accessoryType{
	my $self=shift;
	$self->{'_CoreAccessory_accessoryType'}=shift // return $self->{'_CoreAccessory_accessoryType'};
}

sub _queryNameOrderHash{
	my $self=shift;
	$self->{'_CoreAccessory_queryNameOrderHash'}=shift // return $self->{'_CoreAccessory_queryNameOrderHash'};
}

sub _snpType{
	my $self=shift;
	$self->{'_CoreAccessory_snpType'}=shift // return $self->{'_CoreAccessory_snpType'};
}

sub _coreInputType{
	my $self=shift;
	$self->{'_CoreAccessory_coreInputType'}=shift // return $self->{'_CoreAccessory_coreInputType'};
}

sub _coreComparisonType{
	my $self=shift;
	$self->{'_CoreAccessory_coreComparisonType'}=shift // return $self->{'_CoreAccessory_coreComparisonType'};
}

sub _segmentCoreInput{
	my $self=shift;
	$self->{'_CoreAccessory_segmentCoreInput'}=shift // return $self->{'_CoreAccessory_segmentCoreInput'};
}

sub _blastType{
	my $self=shift;
	$self->{'_CoreAccessory_blastType'}=shift // return $self->{'_CoreAccessory_blastType'};
}

sub _blastDirectory{
	my $self=shift;
	$self->{'_CoreAccessory_blastDirectory'}=shift // return $self->{'_CoreAccessory_blastDirectory'};
}

sub _muscleExecutable{
	my $self=shift;
	$self->{'_CoreAccessory_muscleDirectory'}=shift // return $self->{'_CoreAccessory_muscleDirectory'};
}

sub _novelSeedName{
	my $self=shift;
	$self->{'_CoreAccessory_novelSeedName'}=shift // return $self->{'_CoreAccessory_novelSeedName'};
}

sub _seedFileName{
	my $self=shift;
	$self->{'_CoreAccessory_seedFileName'}=shift // return $self->{'_CoreAccessory_seedFileName'};
}

sub _notSeedFileName{
	my $self=shift;
	$self->{'_CoreAccessory_notSeedFileName'}=shift // return $self->{'_CoreAccessory_notSeedFileName'};
}


sub _fragmentationSize{
	my $self=shift;
	$self->{'_PanseqShared_fragmentationSize'}=shift // return $self->{'_PanseqShared_fragmentationSize'};
}

sub logger{
	my $self=shift;
	$self->{'_logger'}=shift // return $self->{'_logger'};
}



#methods
sub _initialize{
	my($self)=shift;
	#inheritance
	$self->SUPER::_initialize(@_);
	
	#logging
	$self->logger(Log::Log4perl->get_logger());
}

#methods

sub _createNovelConfigFile{
	my($self)=shift;
	
	my $fileName = $self->_baseDirectory . 'temp_novel_config.txt';
	my $outFH = IO::File->new('>' . $fileName) or die "$!";
	print $outFH (
		'queryDirectory' . "\t" . $self->queryDirectory . "\n",
		'baseDirectory' . "\t" . $self->_baseDirectory . "\n",
		'numberOfCores' . "\t" . $self->_numberOfCores . "\n",
		'mummerDirectory' . "\t" . $self->mummerDirectory . "\n",
		'minimumNovelRegionSize' . "\t" . $self->minimumNovelRegionSize . "\n",
		'novelRegionFinderMode' . "\t" . 'no_duplicates' . "\n",
		'createGraphic' . "\t" . 'no' . "\n",
		'skipGatherFiles' . "\t" . '1' . "\n",
		'combinedReferenceFile' . "\t" . $self->combinedQueryFile . "\n",
		'combinedQueryFile' . "\t" . $self->_notSeedFileName . "\n"	
	);
		
	$outFH->close();
	return $fileName;
}

sub _createSeedAndNotSeedFiles{
	my($self)=shift;
	
	my $seed = $self->_getSeedFromQueryNameHash();
	
	#create database from queryFiles
	my $retriever = FileInteraction::Fasta::SequenceRetriever->new(
		'inputFile'=>$self->combinedQueryFile,
		'outputFile'=>$self->combinedQueryFile .'db'
	);
	$self->_seedFileName($self->_baseDirectory . 'seedFile_' . $seed->name . '.fasta');
	$self->_notSeedFileName($self->_baseDirectory . 'notSeedFile' . '.fasta');
	
	my $seedFH = IO::File->new('>' . $self->_seedFileName) or die "Cannot open " . $self->_seedFileName . "$!";
	my $notSeedFH = IO::File->new('>' . $self->_notSeedFileName)  or die 'Cannot open ' . $self->_notSeedFileName . "$!";
	
	#create reference file from seed
	foreach my $queryName(keys %{$self->queryNameObjectHash}){
		foreach my $fastaHeader(@{$self->queryNameObjectHash->{$queryName}->arrayOfHeaders}){
			if($self->queryNameObjectHash->{$queryName}->name eq $seed->name){
				print $seedFH '>' . $fastaHeader . "\n" . $retriever->extractRegion($fastaHeader) . "\n";
			}
			else{
				print $notSeedFH '>' . $fastaHeader . "\n" . $retriever->extractRegion($fastaHeader) . "\n";
			}
		}		
	}	
	$seedFH->close();
	$notSeedFH->close();
}

sub _runBlast{ 
	my $self=shift;
	
	my $inputFile=shift;
	my $numberOfSplits=shift;
	
	my @blastOutputFileNames;
	
	#create blast db
	my $blastDB = $self->_createBlastDB();		
			
	$self->logger->info("Running BLAST\+ in sequence");
	
	#blast in parallel works for small datasets, but multi-GB files among multiple processors
	#create an unacceptable memory requirement
	my $splitter = FileInteraction::Fasta::FastaFileSplitter->new();
	$splitter->splitFastaFile($inputFile,$numberOfSplits);
	my $forker = Parallel::ForkManager->new($numberOfSplits);
	my $counter=0;
	
	foreach my $splitFile(@{$splitter->arrayOfSplitFiles}){
		#run blast / set params 
		my $blastFileName = $self->_baseDirectory . $counter . '_blastoutput.xml';
		
		my $blaster = Blast::BlastIO->new({
			'blastDirectory'=>$self->_blastDirectory,
			'type'=>$self->_blastType // 'blastn', #default to blastn
			'db'=>$blastDB,
			'outfmt'=>'5',
			'evalue'=>'0.00001',
			'word_size'=>20,
			'num_threads'=>$self->_numberOfCores
		});
		
		
		push @blastOutputFileNames, $blastFileName;
		$counter++;
		
		$forker->start and next;
			$blaster->runBlastn(
				'query'=>$splitFile,
				'out'=>$blastFileName
			);
		$forker->finish();	
		
	}
	$forker->wait_all_children();
	return \@blastOutputFileNames;
}

sub _createPhylogenyFiles{
	my($self)=shift;
	
	if(scalar(@_)==4){
		my $type=shift;
		my $tabFile=shift;
		my $phylogenyOutputName = shift;
		my $phylogenyOutputInfoName = shift;
		
		$self->logger->info("INFO:\tCreating phylogeny files $phylogenyOutputName and $phylogenyOutputInfoName");
		
		#check to see if file exists and is non-zero in size
		if(-s $tabFile){
		
			#create core phylogeny file based on snps
			my $phyllo= TreeBuilding::PhylogenyFileCreator->new();
			my $phylogenyFH = IO::File->new('>' . $phylogenyOutputName) or die "$!";
			my $phylogenyInfoFH = IO::File->new('>' . $phylogenyOutputInfoName) or die "$!";
			
			$phyllo->outputFH($phylogenyFH);
			$phyllo->phylipInfoFH($phylogenyInfoFH); #defaults to STDOUT
			
			#requires <type>,<input file>, <header flag 0/1> (optional. default=0)
			$phyllo->createFile(
				$type,
				$tabFile,
				1
			);
			$phylogenyFH->close();
			$phylogenyInfoFH->close();
		}
	}
		else{
		print STDERR "Wrong number of arguments sent to createPhylogenyFiles!\n";
		exit(1);
	}
}

sub _createBlastDB{
	my($self)=shift;	
	
	my $dbMaker = Blast::FormatBlastDB->new($self->_blastDirectory);
	
	my $blastDB = $self->_baseDirectory . 'blastdb';	
	
	$self->logger->info("INFO:\tCreating the blast database as $blastDB");
	
	$dbMaker->runMakeBlastDb(
		'dbtype'=>'nucl',
		'in'=>$self->combinedQueryFile,		
		'out'=>$blastDB,
		'title'=>'blastdb',
		'logFile'=>'>>'.$self->_baseDirectory . 'logs/FormatBlastDB.pm.log'	
	);
	return $blastDB;
}



sub _validateCoreSettings {
	my ($self) = shift;

	my $validator = $self->_validator;

	if (@_) {
		my $settingsHashRef = shift;

		foreach my $setting ( keys %{$settingsHashRef} ) {
			my $value = $settingsHashRef->{$setting};

			$self->_segmentCoreInput( $validator->yesOrNo($value) )       if $setting eq 'segmentCoreInput';
			$self->_blastDirectory( $validator->isADirectory($value) )    if $setting eq 'blastDirectory';
			$self->_muscleExecutable( $validator->doesFileExist($value) ) if $setting eq 'muscleExecutable';

			#unique checks
			$self->_percentIdentityCutoff( $validator->isAValidPercentID($value)*100 ) if $setting eq 'percentIdentityCutoff';
			$self->_coreGenomeThreshold( $validator->isAnIntGreaterThan( $value, -1 ) ) if $setting eq 'coreGenomeThreshold';
			$self->_novelRegionFinderMode( $validator->novelRegionFinderModeCheck($value) ) if $setting eq 'novelRegionFinderMode';
			$self->_accessoryType( $validator->accessoryTypeCheck($value) )                 if $setting eq 'accessoryType';
			$self->_coreInputType($value)                                                   if $setting eq 'coreInputType';
			#set snpType
			$self->_coreComparisonType( $validator->coreComparisonTypeCheck($value) )       if $setting eq 'coreComparisonType';
			if ( $setting eq 'blastType' ) {
				$self->_blastType( $validator->blastTypeCheck($value) );
				if ( $value eq 'blastn' ) {
					$self->_snpType('nucleotide');
				}
				elsif ( $value eq 'tblastn' ) {
					$self->_snpType('protein');
				}
			}
			$self->_fragmentationSize( $validator->isAnInt($value) ) if $setting eq 'fragmentationSize';
		}
	}
}


sub _getSeedFromQueryNameHash{
	my($self)=shift;
		
	my $seed;
	foreach my $queryName(keys %{$self->queryNameObjectHash}){
		$seed=$queryName;
		my $numberOfFastaSequences = scalar(@{$self->queryNameObjectHash->{$queryName}->arrayOfHeaders});
		
		#if single fasta header, means a closed genome
		if($numberOfFastaSequences ==1){
			last;
		}
	}	
	$self->logger->info("INFO:\t" . $self->queryNameObjectHash->{$seed}->name . ' selected as seed sequence.');
		
	return $self->queryNameObjectHash->{$seed};
}

1;
