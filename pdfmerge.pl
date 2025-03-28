#!/Users/herm/bin/perl

use 5.40.1;
use utf8;
use File::Spec;
use File::Basename;
use Cwd;
use PDF::API2;

# Call:  pdfmerge.pl <playlist-file>
# Names: <playlist-file> is <project-name>-<playlist-name>[-[play]list].txt
#        or:                <project-name>-<abc|alphabet[ical]>
#        <project-name> is the PDF subdirectory under $all_pdf_parent_path.
# Example:
#        pdfmerge.pl WestCoast-2025-full.txt
#        => PDF files under $all_pdf_path/WestCoast/
#        => Output as $results_dir_path/WestCoast-2025-full.pdf
#        pdfmerge.pl WestCoast-abc
#        => PDF files under $all_pdf_path/WestCoast/
#        => Output as $results_dir_path/WestCoast-abc.pdf

my $home = $ENV{'HOME'}; 

# Adapt default paths to your environment:
my $default_all_pdf_parent_path = "$home/OneDrive/PadMu-Content";
my $default_results_dir_path = $default_all_pdf_parent_path;

# Adapt naming conventions or leave as is:
# Regex for the part of the playlist filename that will be ignored:
my $playlist_suffix_regex = qr/(-(play)?list)?\..*\z/;
# Regex indicating that the playlist argument is not a file, but that
# we just want an alphabetical sorted list of the PDF files:
my $alphabetic_playlist_regex = qr/abc|alphabet(ical)?/;
# Regex for filenames that will be ignored when reading directories:
my $ignored_filenames_regex = qr/^(?:\.|\~)/;

my $debug = 1;

my @messages; # Messages showing result or failed searches
my $playlist_path;
my $project_name;
my $playlist_name;
my $pdf_source_dir_path;
my $pdf_names;
my $results_dir_path;

my $narg = scalar(@ARGV);
if ($narg == 0) {
	say usage();
	exit();
}

$playlist_path = $ARGV[0];
my ($base, $path, $suffix) = fileparse($playlist_path, $playlist_suffix_regex);
($project_name, $playlist_name) = $base =~ /(.*?)(?:-(.*))/;

unless ($project_name && $playlist_name) {
	say "Playlist format needs minimum 2 parts:";
	say "<project_name>-<playlist_name>[-[play]list].<suffix>";
	say "Call $0 without arguments for usage instructions.";
	exit;
}
# We have a project name and a playlist name (extracted from playlist path).

if ($narg == 1) {
	# Argument: <playlist-path> (other paths are defaults configured above)
	my $all_pdf_parent_path = $default_all_pdf_parent_path;
	$pdf_source_dir_path = File::Spec->catfile($all_pdf_parent_path, $project_name);
	$results_dir_path = $default_results_dir_path;
} else {
	# Arguments: <playlist-path> <source-pdf-dir-path> [<ouput-dir-path>]
	$pdf_source_dir_path = $ARGV[1];
	if ($narg == 2) {
		my $cwd = getcwd();
		$results_dir_path = $cwd;
		say "Output directory not specified. Using: $cwd" 
	} elsif ($narg = 3) {
		$results_dir_path = $ARGV[2];
	} else {
		say usage();
		say "Call this programme with 1 to 3 arguments; details see above.";
		exit();
	}
} 

# Build a list of all files in the source PDF directory:
my @pdf_names = &all_filenames($pdf_source_dir_path, $ignored_filenames_regex);

# Read directory entries once:

my @playlist_pdf_names; # PDFs to go in result PDF; collected below.
if ($playlist_name =~ $alphabetic_playlist_regex) {
	say "Just sorting available PDFs of project alphabetically." if ($debug);
	@playlist_pdf_names = sort(@pdf_names);
} else {
	say "Reading the playlist and searching PDFs." if ($debug);
	open(my $listfh, $playlist_path) or
		die "Cannot open playlist $playlist_path. $!";
	my @playlist_lines = <$listfh>;
	chomp @playlist_lines;
	my @songs = grep /\S/, @playlist_lines; # without empty lines
	foreach my $song (@songs) {
		my $song_pdf_name = &find_pdf($song, \@pdf_names);
		if ($song_pdf_name) {
			push @playlist_pdf_names, $song_pdf_name;
			say "$song is in $song_pdf_name" if ($debug);
		} else {
			push @messages, "Song $song skipped: No PDF found.";
		}
	}
}
# Now we got @playlist_pdf_names populated. Ready for merging.
my $result_filename = "$project_name-$playlist_name.pdf";
my $result_path = File::Spec->catfile($results_dir_path, $result_filename);
say scalar(@playlist_pdf_names), " to merge into: $result_path";
&save_combined_pdf($pdf_source_dir_path, \@playlist_pdf_names,
                   $result_path);
say join("\n", @messages);


#=== Functions ===

sub save_combined_pdf {
	my ($in_dir_path, $in_filenames, $out_path) = @_;
	my $out_pdf = PDF::API2->new() or die "Cannot create PDF::API2. $!";
	foreach my $in_fn (@$in_filenames) {
		my $in_path = File::Spec->catfile($in_dir_path, $in_fn);
		say "Import: $in_path" if ($debug);
		my $in_pdf = PDF::API2->open($in_path) or die "Cannot open $in_path. $!";
		my $in_page_count = $in_pdf->page_count();
		# say "Has $in_page_count pages." if ($debug);
		for my $page_num (1..$in_page_count) {
			# say "Page $page_num" if ($debug);
			# my $page = $in_pdf->open_page($page_num);
			# my $new_page = $out_pdf->import_page($in_pdf, $page_num);
			$out_pdf->import_page($in_pdf, $page_num) or die "Cannot import page. $!";
		}
	}
	say "Writing to: $out_path" if ($debug);
	$out_pdf->save($out_path);
}

sub find_pdf {
	my $song = shift;
	my $fns = shift;
	say "Checking for: $song";
	foreach my $fn (@$fns) {
		if (&fuzzy_match($song, $fn)) {
			say "Found $fn";
			return $fn;
		}
	}
}

# To do: Replace match via title variations with something
# that transforms both title and filename before comparing.
sub fuzzy_match {
	my $title = shift;
	my $fn = shift;
	my $t = essence($title);
	my $f = essence($fn);
	$f =~ /$t/;
}

sub essence {
	my $s = shift;
	$s =~ s/\W//g;
	return lc($s);
}

# Return lists of relevant filenames in the directory,
# excluding those matching one of the patterns in @hidden_patterns
# (i.e. the respective pre-compiled regular expression in argument 2).
sub all_filenames {
	my $dp = shift;          # Path to directory
	my $hide_re = shift;     # Regex: Ignore files that match
	opendir(my $dh, $dp) || die "Cannot open directory $dp. $!";
	my @all = readdir($dh);
	return grep(!/$hide_re/, @all);
}


sub usage() {
	return '
PDF Merger (for sheet music)

Merge song PDF files into one large PDF document, sorted by a playlist
or by alphabet. The individual PDF files need to be kept in one
directory named after the project/band/orchestra.

Two modes of calling:

1. Using presets (configurable in the Perl code):

	Best practice and highly recommended:
	Never use spaces or special characters in directory or file names!
	Use only the following characters: \[a-z\] \[A-Z] [0-9] - _
	
	' .
	"$0" .' <playlist-file>

	playlist-file ::= [PlaylistPath] <ProjectName> - <PlaylistName> - <Suffix>

	The playlist-file is just a text file that lists the songs which
	should get merged into the new PDF, listed in the order they should
	come up there.

	PlaylistPath
		The directory where the playlist file is located.
		If it is in the current working directory just leave it out.

	ProjectName
		The name of the project (band/orchestra/...), but also (in sync)
		the name of the subfolder under: \$all_pdf_parent_path
		That means: The PDFs for this project need to be in
		\$all_pdf_parent_path/ProjectName
	
	PlaylistName
		The name of the specific playlist that lists the songs in the
		order the PDF should be merged into the output PDF.
		PlaylistName can identify the name of a 

	Suffix
		The filename suffix of the playlist file. You can end your
		playlist filenames with anything that matches the regex
		defined under this variable: \$playlist_suffix_regex
		It is recommended to end the filename with just 
		Simply put: End it with ".txt" or "-playlist.txt".
		For the Perl literate, here is the regex: /(-(play)?list)?\..*\z/

	The result of this run, i.e. the merged PDF can be found
		in directory   \$results_dir_path
		with filename  <ProjectName> <PlaylistName> .pdf

2. File location via command line arguments

	' .
	"$0" . ' <playlist=file> <PDF-Source-Dir> <PDF-Target-Dir>

	<playlist-file> see above under 1.

	<PDF-Source-Dir>
		The full path of the directory in which all the PDF files
		for this project are located.

	<PDF-Target-Dir>
		Destination where the result (one PDF file with all song
		PDF files merged into) goes.';
}



