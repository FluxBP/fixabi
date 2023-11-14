#!/usr/bin/perl

# --------------------------------------------------------------------------------------------
# fixabi.pl
#
# Repository:
#   http://github.com/FluxBP/fixabi
#
# Optional dependency:
#   
# How to use:
#   - Have basic Perl in the system so "#!/usr/bin/perl" works (any Linux distribution);
#     if for some strange reason you don't have it, "sudo apt-get install perl" does it.
#   - Have jq (sudo apt-get install jq) to pretty-indent the ABI that is written to the
#     output (optional)
#   - Mark as executable (chmod +x fixabi.pl)
#   - ./fixabi.pl <input ABI file> <input C++ file> [output ABI file]
#   - The fixed ABI file is written as 'output.json' if you don't give a name
#   - Put it somewhere in your PATH for greater convenience
#
# If you have multiple C++ files to parse to change the same ABI file, just call this
#   multiple times with one C++ file for each, and it will populate the ABI incrementally.
# --------------------------------------------------------------------------------------------

use strict;
use warnings;

# --------------------------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------------------------

my $temp_output_file = "fixabi_output_not_pretty.json.tmp";
my $output_file      = "output.json";

# --------------------------------------------------------------------------------------------
# Mini JSON parser copied from JSON::Tiny
# --------------------------------------------------------------------------------------------

# To instead have the Tiny.pm file in the current dir as a separate file:
# use lib '.'; # Find Tiny.pm in current dir
# use Tiny;    # Simple JSON parser from https://github.com/daoswald/JSON-Tiny/

{
    package JSON::Tiny;

    # Minimalistic JSON. Adapted from Mojo::JSON. (c)2012-2015 David Oswald
    # License: Artistic 2.0 license.
    # http://www.perlfoundation.org/artistic_license_2_0

    use Scalar::Util 'blessed';
    use Encode ();
    use B;

    # our $VERSION = '0.58';

    # Literal names
    # Users may override Booleans with literal 0 or 1 if desired.
    our($FALSE, $TRUE) = map { bless \(my $dummy = $_), 'JSON::Tiny::_Bool' } 0, 1;

# Escaped special character map with u2028 and u2029
my %ESCAPE = (
    '"'     => '"',
    '\\'    => '\\',
    '/'     => '/',
    'b'     => "\x08",
    'f'     => "\x0c",
    'n'     => "\x0a",
    'r'     => "\x0d",
    't'     => "\x09",
    'u2028' => "\x{2028}",
    'u2029' => "\x{2029}"
    );
my %REVERSE = map { $ESCAPE{$_} => "\\$_" } keys %ESCAPE;

for(0x00 .. 0x1f) {
    my $packed = pack 'C', $_;
    $REVERSE{$packed} = sprintf '\u%.4X', $_ unless defined $REVERSE{$packed};
}

sub decode_json {
    my $err = _decode(\my $value, shift);

    # pldoh patch: just return undef if any parse error
    #return defined $err ? croak $err : $value;
    return defined $err ? undef : $value;
}

sub encode_json { Encode::encode 'UTF-8', _encode_value(shift) }

sub false () {$FALSE}  ## no critic (prototypes)

sub from_json {
    my $err = _decode(\my $value, shift, 1);
    # pldoh patch: just return undef if any parse error
    #return defined $err ? croak $err : $value;
    return defined $err ? undef : $value;
}

sub j {
    return encode_json $_[0] if ref $_[0] eq 'ARRAY' || ref $_[0] eq 'HASH';
    return decode_json $_[0];
}

sub to_json { _encode_value(shift) }

sub true () {$TRUE} ## no critic (prototypes)

sub _decode {
    my $valueref = shift;

    eval {

        # Missing input
        die "Missing or empty input\n" unless length( local $_ = shift );

        # UTF-8
        $_ = eval { Encode::decode('UTF-8', $_, 1) } unless shift;
        die "Input is not UTF-8 encoded\n" unless defined $_;

        # Value
        $$valueref = _decode_value();

        # Leftover data
        return m/\G[\x20\x09\x0a\x0d]*\z/gc || _throw('Unexpected data');
    } ? return undef : chomp $@;

    return $@;
}

sub _decode_array {
    my @array;
    until (m/\G[\x20\x09\x0a\x0d]*\]/gc) {

        # Value
        push @array, _decode_value();

        # Separator
        redo if m/\G[\x20\x09\x0a\x0d]*,/gc;

        # End
        last if m/\G[\x20\x09\x0a\x0d]*\]/gc;

        # Invalid character
        _throw('Expected comma or right square bracket while parsing array');
    }

    return \@array;
}

sub _decode_object {
    my %hash;
    until (m/\G[\x20\x09\x0a\x0d]*\}/gc) {

        # Quote
        m/\G[\x20\x09\x0a\x0d]*"/gc
      or _throw('Expected string while parsing object');

    # Key
    my $key = _decode_string();

    # Colon
    m/\G[\x20\x09\x0a\x0d]*:/gc
      or _throw('Expected colon while parsing object');

    # Value
    $hash{$key} = _decode_value();

    # Separator
    redo if m/\G[\x20\x09\x0a\x0d]*,/gc;

    # End
    last if m/\G[\x20\x09\x0a\x0d]*\}/gc;

    # Invalid character
    _throw('Expected comma or right curly bracket while parsing object');
  }

  return \%hash;
}

sub _decode_string {
  my $pos = pos;

  # Extract string with escaped characters
  m!\G((?:(?:[^\x00-\x1f\\"]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4})){0,32766})*)!gc; # segfault on 5.8.x in t/20-mojo-json.t
  my $str = $1;

  # Invalid character
  unless (m/\G"/gc) {
    _throw('Unexpected character or invalid escape while parsing string')
      if m/\G[\x00-\x1f\\]/;
    _throw('Unterminated string');
  }

  # Unescape popular characters
  if (index($str, '\\u') < 0) {
    $str =~ s!\\(["\\/bfnrt])!$ESCAPE{$1}!gs;
    return $str;
  }

  # Unescape everything else
  my $buffer = '';
  while ($str =~ m/\G([^\\]*)\\(?:([^u])|u(.{4}))/gc) {
    $buffer .= $1;

    # Popular character
    if ($2) { $buffer .= $ESCAPE{$2} }

    # Escaped
    else {
      my $ord = hex $3;

      # Surrogate pair
      if (($ord & 0xf800) == 0xd800) {

        # High surrogate
        ($ord & 0xfc00) == 0xd800
          or pos($_) = $pos + pos($str), _throw('Missing high-surrogate');

        # Low surrogate
        $str =~ m/\G\\u([Dd][C-Fc-f]..)/gc
          or pos($_) = $pos + pos($str), _throw('Missing low-surrogate');

        $ord = 0x10000 + ($ord - 0xd800) * 0x400 + (hex($1) - 0xdc00);
      }

      # Character
      $buffer .= pack 'U', $ord;
    }
  }

  # The rest
  return $buffer . substr $str, pos $str, length $str;
}

sub _decode_value {

  # Leading whitespace
  m/\G[\x20\x09\x0a\x0d]*/gc;

  # String
  return _decode_string() if m/\G"/gc;

  # Object
  return _decode_object() if m/\G\{/gc;

  # Array
  return _decode_array() if m/\G\[/gc;

  # Number
  my ($i) = /\G([-]?(?:0|[1-9][0-9]*)(?:\.[0-9]*)?(?:[eE][+-]?[0-9]+)?)/gc;
  return 0 + $i if defined $i;

  # True
  return $TRUE if m/\Gtrue/gc;

  # False
  return $FALSE if m/\Gfalse/gc;

  # Null
  return undef if m/\Gnull/gc;  ## no critic (return)

  # Invalid character
  _throw('Expected string, array, object, number, boolean or null');
}

sub _encode_array {
  '[' . join(',', map { _encode_value($_) } @{$_[0]}) . ']';
}

sub _encode_object {
  my $object = shift;
  my @pairs = map { _encode_string($_) . ':' . _encode_value($object->{$_}) }
    sort keys %$object;
  return '{' . join(',', @pairs) . '}';
}

sub _encode_string {
  my $str = shift;
  $str =~ s!([\x00-\x1f\x{2028}\x{2029}\\"/])!$REVERSE{$1}!gs;
  return "\"$str\"";
}

sub _encode_value {
  my $value = shift;

  # Reference
  if (my $ref = ref $value) {

    # Object
    return _encode_object($value) if $ref eq 'HASH';

    # Array
    return _encode_array($value) if $ref eq 'ARRAY';

    # True or false
    return $$value ? 'true' : 'false' if $ref eq 'SCALAR';
    return $value  ? 'true' : 'false' if $ref eq 'JSON::Tiny::_Bool'; #'JSON_Bool';

    # Blessed reference with TO_JSON method
    if (blessed $value && (my $sub = $value->can('TO_JSON'))) {
      return _encode_value($value->$sub);
    }
  }

  # Null
  return 'null' unless defined $value;

  # Number (bitwise operators change behavior based on the internal value type)

  return $value
    if B::svref_2object(\$value)->FLAGS & (B::SVp_IOK | B::SVp_NOK)
    # filter out "upgraded" strings whose numeric form doesn't strictly match
    && 0 + $value eq $value
    # filter out inf and nan
    && $value * 0 == 0;

  # String
  return _encode_string($value);
}

sub _throw {

  # Leading whitespace
  m/\G[\x20\x09\x0a\x0d]*/gc;

  # Context
  my $context = 'Malformed JSON: ' . shift;
  if (m/\G\z/gc) { $context .= ' before end of data' }
  else {
    my @lines = split "\n", substr($_, 0, pos);
    $context .= ' at line ' . @lines . ', offset ' . length(pop @lines || '');
  }

  die "$context\n";
}

# Emulate boolean type

package JSON::Tiny::_Bool;
use overload '""' => sub { ${$_[0]} }, fallback => 1;
}

# --------------------------------------------------------------------------------------------
# Debug helpers for the parsed JSON as a Perl data structure
# --------------------------------------------------------------------------------------------

sub dump_hash {
    my ($hash_ref, $indent) = @_;
    my $o = '';
    $indent //= 0;
    my $indentation = " " x $indent;
    foreach my $key (sort keys %$hash_ref) {
        my $value = $hash_ref->{$key};
        $o .= "$indentation$key => ";
        if (ref($value) eq 'HASH') {
            $o .= "{\n";
            $o .= dump_hash($value, $indent + 1);
            $o .= "$indentation}\n";
        } elsif (ref($value) eq 'ARRAY') {
            $o .= "[\n";
            $o .= dump_array($value, $indent + 1);
            $o .= "$indentation]\n";
        } else {
            if (!defined $value) {
                $o .= "<null>\n";
            } else {
                $o .= "\"$value\"\n";
            }
        }
    }
    return $o;
}

sub dump_array {
    my ($array_ref, $indent) = @_;
    my $o = '';
    $indent //= 0;
    my $indentation = " " x $indent;
    for my $index (0 .. $#{$array_ref}) {
        my $value = $array_ref->[$index];
        $o .= $indentation . $index . " => ";
        if (ref($value) eq 'HASH') {
            $o .= "{\n";
            $o .= dump_hash($value, $indent + 1);
            $o .= "$indentation}\n";
        } elsif (ref($value) eq 'ARRAY') {
            $o .= "[\n";
            $o .= dump_array($value, $indent + 1);
            $o .= "$indentation]\n";
        } else {
            if (!defined $value) {
                $o .= "<null>\n";
            } else {
                $o .= "\"$value\"\n";
            }
        }
    }
    return $o;
}

# --------------------------------------------------------------------------------------------
# Actual parser -- subs
# --------------------------------------------------------------------------------------------

sub parse_table {
    my ($entire_cpp_file, $table_name, $table_type) = @_;

    # Skip singleton tables

    if ($entire_cpp_file =~ /eosio::singleton\s*<\s*"$table_name"_n/) {
        print "Singleton table will be skipped: $table_name\n";
        my @empty_array;
        return \@empty_array;
    }

    # Must to parse only ONE typedef line, since the table type (which is what matches on each line)
    #   can be reused as the schema (struct) of different named tables. so we will narrow down the entire
    #   input file to just this typedef here and THEN use the table type to match on each line of the
    #   narrowed-down input string.

    my @table_blocks = $entire_cpp_file =~ /(typedef\s+eosio::multi_index\s*<[^;]+;)/g;
    my $input_string; # this will contain just the piece of $entire_cpp_file that we want
    foreach my $table_block (@table_blocks) {
        if ($table_block =~ qq/"$table_name"_n/) {
            #print "Found typedef for table '$table_name':\n$table_block\n\n";
            $input_string = $table_block;
            last;
        }
    }

    # If we can't find it for whatever reason, revert to use the entire cpp file, which works most of the time

    if (!defined $input_string) {
        print "\nWARNING: Could not find multi-index typedef for table '$table_name', reverting to searching entire cpp file.\n\n";
        $input_string = $entire_cpp_file;
    }

    # Finally, match all (/g) of the indexed_by lines of this typedef

    my $pattern = qr/indexed_by\s*<\s*"(.*?)".*?const_mem_fun\s*<\s*$table_type\s*,\s*(.*?)\s*,.*?by_(.*?)>>/;
    my @matches = $input_string =~ /$pattern/g;

    # Scan the matches,  generate and return an _array_ of entries (triplets) to preserve the order in which
    #   the indices are defined in the source file.

    my @index_array;
    while (@matches) {
        my $name = shift @matches;
        my $type = map_cpp_type_to_abi_type(shift @matches);
        my $func = shift @matches;
        my @entry = ($name, $type, $func);
        push @index_array, \@entry;
    }

    # Before returning, do a final validation step to help spot potential problems
    # The number of entries in @index_array should be the number of lines in the typedef - 1
    # This is not necessarily an error; all it requires is sloppy code formatting,
    #   e.g. the closing ; is in a separate line.

    if ($input_string ne $entire_cpp_file) { # skip cases when we couldn't find the block
        my $got_lines = scalar(@index_array);
        my $expected_lines = (scalar split /\n/, $input_string) - 1;
        if ($got_lines != $expected_lines) {
            print "WARNING: Expected to parse $expected_lines lines of the typedef block for table '$table_name', got $got_lines instead. Typedef block is:\n$input_string\n";
        }
    }

    return \@index_array;
}

sub map_cpp_type_to_abi_type {
    my $cpp_type = shift;

    my %type_mapping = (
        "uint64_t"      => "i64",
        "uint128_t"     => "i128",
        "double"        => "float64",
        "__float128"    => "float128",
        "checksum160"   => "ripemd160",
        "checksum256"   => "sha256",
    );

    # use // to return original type if mapping not found
    return $type_mapping{$cpp_type} // $cpp_type;
}

# --------------------------------------------------------------------------------------------
# Actual parser -- resolve command-line; read input files
# --------------------------------------------------------------------------------------------

# Check the number of command line arguments
if (@ARGV < 2 || @ARGV > 3) {
    die "Usage: $0 <input ABI file> <input C++ file> [output ABI file]\n";
}

# Input ABI file
my $input_abi_file = $ARGV[0];

# Input C++ file
my $input_cpp_file = $ARGV[1];

# Output ABI file (optional)
if (defined $ARGV[2]) { $output_file = $ARGV[2]; }

# Print information about the chosen files
print "Input ABI file: $input_abi_file\n";
print "Input C++ file: $input_cpp_file\n";
print "Output file: $output_file\n";

# Read the input ABI file
open my $abi_file, '<', "$input_abi_file" or die "ERROR: Could not open input ABI file: $!\n";
my $abi_data = do { local $/; <$abi_file> };
close $abi_file;

# Read the C++ code
open my $cpp_file, '<', "$input_cpp_file" or die "ERROR: Could not open input C++ file: $!\n";
my $cpp_code = do { local $/; <$cpp_file> };
close $cpp_file;

# --------------------------------------------------------------------------------------------
# Actual parser
# --------------------------------------------------------------------------------------------

# Parse ABI data
my $abi_structure = JSON::Tiny::decode_json($abi_data);

my %parsed_tables;

foreach my $table (@{$abi_structure->{'tables'}}) {
    my $table_name = $table->{'name'};
    my $table_type = $table->{'type'};

    # Call parse_table and get the @index_array for current table name
    my $index_array = parse_table($cpp_code, $table_name, $table_type);

    # Insert the @index_array into the %tables hash
    $parsed_tables{$table_name} = $index_array;
}

# Print the results for each table in %parsed_tables
foreach my $parsed_table_name (sort keys %parsed_tables) {
    print "Parsed table: $parsed_table_name\n";

    # Access the @index_array for the current parsed_table
    my $index_array = $parsed_tables{$parsed_table_name};

    # Print each @index_array entry
    foreach my $entry (@$index_array) {
        my ($name, $type, $func) = @$entry;
        print "  Name: $name, Type: $type, Func: $func\n";
    }
}

print "Patching internal ABI data structure...\n";

# Update ABI data with key names and types
foreach my $table (@{$abi_structure->{'tables'}}) {
    my $table_name = $table->{'name'};
    my $key_names_ref = $table->{'key_names'};
    my $key_types_ref = $table->{'key_types'};

    if (scalar(@$key_names_ref) > 0 || scalar(@$key_types_ref) > 0) {
        print "\nERROR: In the input ABI file, table '$table_name' already contains key names or key types. To help avoid mistakes, this tool assumes that each table to patch with the given input C++ file still has no key names and key types in its ABI entry. Aborting.\n";
        exit 1;
    }

    my $index_array = $parsed_tables{$table_name};
    foreach my $entry (@$index_array) {
        my ($name, $type, $func) = @$entry;
        push @$key_names_ref, $name;
        push @$key_types_ref, $type;
    }
}

# For debugging:
# Dump perl internal ABI structure
#print dump_hash($abi_structure, 2);

print "Writing fixed ABI file to '$temp_output_file'...\n";

# JSON to temporary file
open my $fh, '>', "$temp_output_file" or die "ERROR: Could not open file for writing: '$temp_output_file': $!\n";
print $fh JSON::Tiny::encode_json($abi_structure);
close $fh;

# Attempt prettify
print "Indenting fixed ABI file with jq and writing as '$output_file'...\n";
system("jq '.' $temp_output_file > $output_file");
if ($? != 0) {
    print "Can't use jq ($?:$!); copying the unindented & fixed ABI file to '$output_file'...\n";
    system("cp $temp_output_file $output_file");
}

# Remove temp file
system("rm -f $temp_output_file");

# Done!
print "fixabi.pl done.\n";
