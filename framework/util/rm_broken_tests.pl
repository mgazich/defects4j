#!/usr/bin/env perl
#
#-------------------------------------------------------------------------------
# Copyright (c) 2014-2015 René Just, Darioush Jalali, and Defects4J contributors.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#-------------------------------------------------------------------------------

=pod

=head1 NAME

rm_broken_tests.pl -- Fix broken test methods from a set of test classes

=head1 SYNOPSIS

rm_broken_tests.pl log_file src_dir

=head1 DESCRIPTION

Parses the file F<log_file> and fixes failing test methods by replacing each
broken test method with a dummy test method in the source file of the corresponding test
class. The source file of the test class is backed up prior to the first
modification.

=cut

use IO::File;
use File::Copy;
use Text::Balanced qw (extract_bracketed);
use warnings;
use strict;

($#ARGV==1 || $#ARGV==2) or die "usage: $0 log_file src_dir [except]";

my $log_file = shift @ARGV;
my $base_dir = shift @ARGV;
my $except   = shift @ARGV;

my $verbose = 0;

-e $log_file or die "Cannot open log file: $!";

=pod

The log file may contain arbitrary lines -- the script only considers lines that
match the pattern: B</--- ([^:]*)(::(.*))?/>.

=head3 Example entries in the log file

=over

=item Failing test class: --- package.Class

=item Failing test method: --- package.Class::method

=back

All lines matching the pattern are sorted, such that a failing test class in the
list will appear before any of its failing methods.

=cut
my @list = `grep -a "^---" $log_file | sort -u -k1 -t":"`;

my $counter=0;
my @tests;

# Check all entries in the log file
for (@list) {
    /--- ([^:]+)(::([^:]+))?/ or die "Corrupted log file: $_";
}

my %buffers;

# This variable is used to keep track of whether this program uses
# junit 4 styles. This is important, since the @Test annotation
# must not be added on empty method additions for superclass
# failing methods
# This hash will map a filename to 1 in case it is junit 4.
my %is_buffer_junit4 = ();

for (@list){
    chomp;
    /--- ([^:]+)(::([^:]+))?/;
    _exclude_test_class($1) unless defined $3;
    if ($except) {
        next if "$1::$3" eq $except;    # skip the excepted test.
    }
    _remove_test_method($1, $3) if defined $3;
}
_write_buffers();

0;

sub _exclude_test_class {
    my $class = shift;
    # We do not remove broken test classes as
    # this might cause compilation issues
}

sub _remove_test_method {
    my ($class, $method) = @_;
    my $file = $class;
    $file =~ s/\./\//g;
    $file = "$base_dir/$file.java";

    # Skip non-existing files
    if (! -e $file) {
        print STDERR "$0: $file does not exist -> SKIP ($method)\n" if $verbose;
        return;
    }

    # Backup file if necessary
    if (! -e "$file.bak") {
        copy("$file","$file.bak") or die "Cannot backup file ($file): $!";
    }

    if (!defined($buffers{$file})) {
        # Read the entire file
        my $in = IO::File->new("<$file") or die "Cannot open source file: $file!";
        my @data = <$in>;
        $in->close();
        $buffers{$file}=\@data;

        # Check for junit 4
        $is_buffer_junit4{$file} = 0;
        $is_buffer_junit4{$file} = 1 if grep {/import org\.junit\.Test/} @data;
    }

    my @lines=@{$buffers{$file}};
    # Line buffer for the fixed source file
    my @buffer;
    for (my $i=0; $i<=$#lines; ++$i) {
        if ($lines[$i] =~ /^([^\/]*)public.+$method\(\)/) {
            my $index = $i;
            # Found the test to exclude
            my $space = $1;
            # Dummy test
            my $dummy = "${space}public void $method() {}\n";
            # Check whether JUnit4 annotation is present
            if ($lines[$i-1] =~ /\@Test/) {
                $dummy = "${space}\@Test\n$dummy";
                --$index;
            }

            # Remove all comments as they may contain unbalanced delimiters
            # or brackets
            my @tmp = @lines[$index..$#lines];
            foreach (@tmp) {
                s/^\s*\/\/.*/\/\//;
            }

            my @result = extract_bracketed(join("", @tmp), '{"\'}', '[^\{]*');
            die "Could not extract method body" unless defined $result[0];

            my $len = scalar(split("\n", $result[2].$result[0]));

            # Add everything before broken method
            push(@buffer, @lines[0..($index-1)]);
            # Add dummy method
            push(@buffer, $dummy);
            # Comment out broken method
            foreach (@lines[$index..($index+$len-1)]) {
                push(@buffer, "// $_");
            }
            # Add everything after broken method
            push(@buffer, @lines[($index+$len)..$#lines]);

            last;
        }
    }

    if (@buffer) {
        # Update file buffer
        $buffers{$file} = \@buffer;
    } else {
        # Override failing test method if it was implemented in super class
        my $override = ###### "    \@Override\n" .
                       ###### TODO: There is a problem with adding the @Override annotation
                       #              it is that when we are dealing with e.g, broken_tests
                       #              and specify them project wide, it may be that
                       #              the file exists but not the method, so we
                       #              don't find it and assume it was in the super class
                       #              This is different than the case when we know it is
                       #              failing for this particular revision.
                       "    public void $method() {} // Fails in super class\n";

        # Only add @Test annotation if we are using Junit 4
        $override =       "    \@Test\n" . $override if $is_buffer_junit4{$file};


        # Read file buffer, determine closing curly brace of test class,
        # and insert test method before the brace.
        # TODO: This is probably not the most elegant solution.
        my @buffer = @{$buffers{$file}};
        for (my $index=$#buffer; $index>=0; --$index) {
            # Find closing curly
            next unless $buffer[$index] =~ /}/;
            # Insert dummy (empty) test method
            $buffer[$index] =~ s/^(.*)}([^}])$/$1\n$override}$2/;
            $buffers{$file} = \@buffer;

            last;
        }
    }
}

sub _write_buffers {
    sleep(1);
    foreach my $file (keys %buffers) {
        my @buffer = @{$buffers{$file}};
        unlink($file);
        my $fix = IO::File->new(">$file") or die "Cannot write source file: $file!";
        print $fix @buffer;
        $fix->flush();
        $fix->close();
    }
}
