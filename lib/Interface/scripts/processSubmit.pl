#!/usr/bin/env perl
use strict;
use warnings FATAL => 'all';
use CGI;
use Data::Dumper;
use File::Path qw/make_path/;
use File::Copy;
use Net::FTP;
use Archive::Extract;
use Carp;

my $cgi = CGI->new();
my $serverSettings = _loadServerSettings();
my $RESULTS_URL = '/panseq/page/output/' . $serverSettings->{'resultsHtml'};

my $pid = fork();
if(!defined $pid){
    die "cannot fork process!\n $!";
};

if($pid){


my $hereDoc = <<END_HTML;
<!DOCTYPE html>
<html lang="en" xmlns="http://www.w3.org/1999/html">
<head>
    <meta charset="UTF-8">
    <title>Panseq</title>
    <link href="/panseq/css/panseq.css" rel="stylesheet">
    <link href="/panseq/images/favicon.ico" rel="shortcut icon">
</head>
<body>
<div id="panseqImage">
    <p>Pan~genomic sequence analysis</p>
</div>


<div id="nav">
    <ul>
        <li><a href="/panseq/page/index.html">Home</a></li>
        <li><a href="/panseq/page/novel.html">Novel Regions</a></li>
        <li><a href="/panseq/page/pan.html">Pan-genome</a></li>
        <li><a href="/panseq/page/loci.html">Loci</a></li>
        <li><a href="/panseq/page/faq.html">FAQ</a></li>
    </ul>
</div>

<div class="mainBody">
<h1>Your job has been submitted.</h1>

<p>
    Results, when available can be retrieved from:

    <a href="$RESULTS_URL">$RESULTS_URL</a>

    Please bookmark this address and return in a few minutes to retrieve your results.
</p>
</div>
</body>
</html>



END_HTML

    print $cgi->header() . $hereDoc;
}
else {
    my $gid = fork();
    if(!defined $gid){
        die "cannot fork process!\n $!";
    };
    open STDIN, "</dev/null";
    open STDOUT, ">/dev/null";
    open STDERR, ">/dev/null";

    if($gid){
        #good
    }
    else{
        #We need to close STDERR otherwise Apache will wait for the
        #analyses to complete before showing the in-progress page.
        _launchPanseq();
    }
}


sub _launchPanseq{
    #link the waiting html to the current html page
    my $symFile = $serverSettings->{panseqDirectory} . 'Interface/html/output/' . $serverSettings->{resultsHtml};
    my $waitingHtml = $serverSettings->{panseqDirectory} . 'Interface/html/waiting.html';
    symlink($waitingHtml, $symFile);


    #we need to determine what run mode (pan, novel, loci)
    my $runMode = $cgi->param('runMode');

    #we need a new directory regardless of the mode
    my $newDir = $serverSettings->{'outputDirectory'} . $serverSettings->{'newDir'};

    if($runMode eq 'novel' || $runMode eq 'pan'){
#
        #for a novel run we need both query / reference directories
        my $resultsDir = $newDir . 'results/';
        my $queryDir = $newDir . 'query/';
        my $refDir = $newDir . 'reference/';

        eval{_createDirectory($queryDir)};
        if($@){
            _makeErrorPage();
            die($@);
        }

        if($runMode eq 'novel'){
            eval{_createDirectory($refDir)};
            if($@){
                _makeErrorPage();
                die($@);
            }
        }

        #create a hash of settings
        #base directory is used in the Panseq program to mean results dir
        #in this hash the results dir is one level down from the base dir
        #baseDirectory in Panseq really should have been called results,
        #but it is too late for that change now
        my %runSettings = (
            queryDirectory     => $queryDir,
            mummerDirectory    => $serverSettings->{'mummerDirectory'},
            blastDirectory     => $serverSettings->{'blastDirectory'},
            numberOfCores      => $serverSettings->{'numberOfCores'},
            baseDirectory      => $resultsDir,
            numberOfCores      => $serverSettings->{'numberOfCores'},
            muscleExecutable   => $serverSettings->{'muscleExecutable'},
            outputDirectory    => $newDir,
            nucB               => $cgi->param( 'nucB' ),
            nucC               => $cgi->param( 'nucC' ),
            nucD               => $cgi->param( 'nucD' ),
            nucG               => $cgi->param( 'nucG' ),
            nucL               => $cgi->param( 'nucL' )
        );

        if($runMode eq 'novel') {
            $runSettings{runMode}='novel';
            $runSettings{referenceDirectory} = $refDir;
        }
        else{
            #run mode is pan
            $runSettings{runMode} = 'pan';
            $runSettings{fragmentationSize} = $cgi->param('fragmentationSize');
            $runSettings{coreGenomeThreshold} = $cgi->param('coreGenomeThreshold');
            $runSettings{blastWordSize} = $cgi->param('blastWordSize');
        }

        my $batchFile = eval{_createBatchFile(\%runSettings)};
        if($@){
            _makeErrorPage();
            die($@);
        }
        else{
            eval{_downloadUserSelections(\%runSettings)};
            if($@){
                _makeErrorPage();
                die($@);
            }
        }


        my @qFiles = $cgi->upload('userQueryFiles');
        eval{_uploadUserFiles(\@qFiles, $runSettings{'queryDirectory'}) };
        if($@){
            _makeErrorPage();
            die($@);
        }


        if($runMode eq 'novel'){
            my @rFiles = $cgi->upload('userReferenceFiles');

            eval{ _uploadUserFiles(\@rFiles, $runSettings{'referenceDirectory'}) };
            if($@){
                _makeErrorPage();
                die($@);
            }

            eval{ _checkFiles([$refDir])};
            if($@){
                _makeErrorPage();
                die($@);
            }
        }

        eval{  _checkFiles([$queryDir]) };
        if($@){
            _makeErrorPage();
            die($@);
        }

        #check that panseq finished correctly
        eval _runPanseq($batchFile);
        if($@){
            _makeErrorPage();
            die($@);
        }

        #everything went peachy, no errors, so link to the download page
        eval{_createDownloadPage()};
        if($@){
            _makeErrorPage();
            die($@);
        }
    }
    elsif($runMode eq 'loci'){

    }
    else{
        _makeErrorPage();
        die($@);
    }
}


sub _createDownloadPage{
    #check if zip file exists
    my $resultsFile = $serverSettings->{'outputDirectory'} . $serverSettings->{'newDir'} . 'results/panseq_results.zip';

    if(-e $resultsFile){

        my $downloadHtml =   $serverSettings->{'outputDirectory'} . $serverSettings->{'newDir'} . 'download.html';
        my $symFile = $serverSettings->{panseqDirectory} . 'Interface/html/output/' . $serverSettings->{resultsHtml};
        my $outputResultsSym = '/panseq/page/output/' . $serverSettings->{resultsHtml} . '.zip';
        my $serverResultsSym = $serverSettings->{panseqDirectory} . 'Interface/html/output/' . $serverSettings->{resultsHtml} . '.zip';

my $hereDoc = <<END_HTML;
<!DOCTYPE html>
    <html lang="en" xmlns="http://www.w3.org/1999/html">
<head>
    <meta charset="UTF-8">
    <title>Panseq</title>
    <link href="/panseq/css/panseq.css" rel="stylesheet">
    <link href="/panseq/images/favicon.ico" rel="shortcut icon">
</head>
<body>
<div id="panseqImage">
    <p>Pan~genomic sequence analysis</p>
</div>


<div id="nav">
    <ul>
        <li><a href="/panseq/page/index.html">Home</a></li>
        <li><a href="/panseq/page/novel.html">Novel Regions</a></li>
        <li><a href="/panseq/page/pan.html">Pan-genome</a></li>
        <li><a href="/panseq/page/loci.html">Loci</a></li>
        <li><a href="/panseq/page/faq.html">FAQ</a></li>
    </ul>
</div>

<div class="mainBody">
<h1>Analyses Completed</h1>
<p>
   Please click here:<a href="$outputResultsSym" download="panseq_results.zip"> Panseq Results </a>to download your results.
</p>
</div>
</body>
</html>

END_HTML

        open(my $outFH, '>', $downloadHtml) or die ("Could not create $downloadHtml" and return 0);
        $outFH->print($hereDoc);



        if(-e $symFile){
            unlink($symFile);
        }
        symlink($downloadHtml, $symFile);


       if(-e $serverResultsSym){
           unlink($serverResultsSym);

       }
        symlink($resultsFile, $serverResultsSym);
        return 1;
    }
    else{
        #carp "No Reults!";
        return 0;
    }
}


sub _uploadUserFiles{
    my $filesRef = shift;
    my $outputDir = shift;

    #make sure there are files to upload
    unless(scalar(@{$filesRef}) > 0){
        return 1;
    }

    foreach my $f(@{$filesRef}){
        my $cleanedFile = $f;
        $cleanedFile =~ s/\W/_/g;

        my $inFH = $f->handle;
        open(my $outFH, '>', $outputDir . $cleanedFile) or die ("Cannot create cleaned file from user upload\n" and return 0);

        #upload file using 1024 byte buffer
        my $buffer;
        my $bytesread = $inFH->read( $buffer, 1024 );
        while ($bytesread) {
            $outFH->print($buffer);
            $bytesread = $inFH->read( $buffer, 1024 );
        }
        $outFH->close();
    }

    return 1;
}



sub _checkFiles{
    my $directoriesRef = shift;

    foreach my $dir(@{$directoriesRef}) {
        #requires functional SLURM
        my $systemLine = 'srun perl '. $serverSettings->{'panseqDirectory'}.'Interface/scripts/single_file_check.pl '.$dir;
        system( $systemLine );
    }
}


sub _makeErrorPage{
    my $tempHtml =  $serverSettings->{'panseqDirectory'} . 'Interface/html/'. 'error.html';
    my $symFile = $serverSettings->{panseqDirectory} . 'Interface/html/output/' . $serverSettings->{resultsHtml};

    if(-e $symFile){
        unlink($symFile);
    }
    symlink($tempHtml, $symFile);
}

sub _runPanseq{
    my $configFile = shift;

    #requires SLURM to be operational
    my $systemLine = 'srun perl ' . $serverSettings->{'panseqDirectory'} . 'panseq.pl ' . $configFile;
    my $panseqReturn = eval{readpipe($systemLine)};
    unless($panseqReturn =~ m/Creating zip file/){
        _makeErrorPage();
    }
}



sub _downloadUserSelections{
    my $runSettings = shift;

    my @ncbiQueryGenomes;
    my @ncbiReferenceGenomes;
    foreach my $p(keys %{$cgi->{'param'}}){
        if($p =~ m/^q_(.+)/){
            push @ncbiQueryGenomes, $1;
        }
        elsif($p =~ m/^r_(.+)/){
            push @ncbiReferenceGenomes, $1;
        }
    }

    #if no selections, skip
    unless(scalar(@ncbiQueryGenomes) > 0 || scalar(@ncbiReferenceGenomes) > 0){
        return 1;
    }

    #sets up the parameters for ncbi ftp connection
    my $host = 'ftp.ncbi.nlm.nih.gov';
    #constructs the connection
    my $ftp = Net::FTP->new($host, Debug => 1,Passive => 1) or die ("Cannot connect to genbank: $@" and return 0);
    #log in as anonymous, use email as password
    $ftp->login("anonymous",'chadlaing@inoutbox.com') or die ("Cannot login " . $ftp->message and return 0);


    $ftp->binary();
    my @allDownloadedFiles;
    my $ncbiPrefix = '/genomes/all/';

    foreach my $q(@ncbiQueryGenomes){
        my $genomeName = _getGenomeName($q);

        #the FTP path is given in $q, need to specify the _genomic.fna.gz
        my $ncbiFile = $ncbiPrefix .  $q . '/' . $genomeName . '_genomic.fna.gz';
        my $localFile = $runSettings->{'queryDirectory'} . $genomeName;

        push @allDownloadedFiles, $localFile;
        $ftp->get($ncbiFile, $localFile) or die ("Cannot get $q" . $ftp->message and return 0);

        #don't get banned from NCBI
        sleep 1;
    }

    foreach my $r(@ncbiReferenceGenomes){
        my $genomeName = _getGenomeName($r);

        my $ncbiFile = $ncbiPrefix . $r . '/' . $genomeName . '_genomic.fna.gz';
        my $localFile = $runSettings->{'referenceDirectory'} . $genomeName;

        push @allDownloadedFiles, $localFile;
        $ftp->get($ncbiFile, $localFile) or die ("Cannot get $r" . $ftp->message and return 0);

        #don't get banned from NCBI
        sleep 1;
    }
    $ftp->ascii();


    #extract them all
    foreach my $f(@allDownloadedFiles){
        my $extracter = Archive::Extract->new('archive'=>$f, type=>'gz');
        $extracter->extract(to=>$f . '.fna') or die ("Could not extract $f\n" and return 0);
        unlink $f;
    }
}

sub _getGenomeName{
    my $name = shift;

    my $gName;
    if($name =~ m/\/(GC(F|A)_.+)$/){
        $gName = $1;
    }
    else{
        die "Unable to find genome name in $name\n!";
        exit(1);
    }
    return $gName;
}



sub _createBatchFile{
    my $paramRef = shift;

    my $batchFile = $paramRef->{'outputDirectory'} . 'panseq.batch';
    open(my $batchFH, '>', $batchFile) or die ("Could not create $batchFile\n$!");

    foreach my $k(sort keys %{$paramRef}){
        $batchFH->print($k . "\t" . $paramRef->{$k} . "\n");
    }

    $batchFH->close();
    return $batchFile;
}



sub _loadServerSettings{
    my $symlinkFile = './server.conf';

    my %settings;
    open(my $inFH, '<', $symlinkFile) or die "$!\n";

    while(my $line = $inFH->getline){
        $line =~ s/\R//g;
        my @la = split(/\s+/, $line);

        $settings{$la[0]}=$la[1];
    }

    #create newDir for output

    $settings{'newDir'} =  _createBaseDirectoryName();

    my $newDir = $settings{'newDir'};
    $newDir =~ s/\/$//;
    $settings{'resultsHtml'} = $newDir . '.html';

    return \%settings;
}



sub _createBaseDirectoryName{
    #use random number as well as localtime to ensure no directory overlap
    my $randomNumber = int( rand(8999) ) + 1000;
    my $directory    = localtime . $randomNumber;
    $directory =~ s/[\W]//g;

    return $directory . '/';
}


sub _createDirectory{
    my $dirName = shift;

    if(defined $dirName){
        #we don't want any permission issues, so don't downgrade the directory permissions
        umask(0);
        #from File::Path
        make_path($dirName) or die ("Couldn't create fastaBase $dirName\n");

    }
}