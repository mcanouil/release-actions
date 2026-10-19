#!/usr/bin/env perl
# Finds or replaces the matches of a target pattern in a file.
#
#   target.pl find PATTERN FILE [SECTION]
#                                   Prints one line per match: the {version}
#                                   value when the pattern has one, else the
#                                   whole match.
#   target.pl replace PATTERN FILE [SECTION]
#                                   Rewrites FILE in place with the values of
#                                   the VERSION, DATE and MAJOR environment
#                                   variables, and prints the number of matches.
#
# SECTION, such as [package], limits the matches to the lines under that header
# line, up to the next line that starts with [.
#
# A pattern is literal text with {version}, {date} and {major} placeholders.
# A leading ^ and a trailing $ anchor it to a line; a trailing $ also matches
# before a carriage return.
use strict;
use warnings;

sub fail {
  print STDERR "target.pl: @_\n";
  exit 1;
}

my %placeholder = (
  version => '[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?',
  date    => '[0-9]{4}-[0-9]{2}-[0-9]{2}',
  major   => '[0-9]+(?![.0-9])',
);

my ($mode, $pattern, $file, $section) = @ARGV;
fail('usage: target.pl find|replace PATTERN FILE [SECTION]')
  unless defined $file && $mode =~ /\A(?:find|replace)\z/;

my $start = $pattern =~ s/\A\^// ? '^' : '';
my $end = $pattern =~ s/\$\z// ? '(?=\r?$)' : '';
my @kinds;
my $regex = '';
for my $part (split /(\{(?:version|date|major)\})/, $pattern) {
  next if $part eq '';
  if ($part =~ /\A\{(version|date|major)\}\z/) {
    push @kinds, $1;
    $regex .= "($placeholder{$1})";
  } else {
    push @kinds, 'literal';
    $regex .= '(' . quotemeta($part) . ')';
  }
}
my $compiled = qr/$start$regex$end/m;

open my $in, '<', $file or fail("cannot read $file: $!");
my $text = do { local $/; <$in> };
close $in;

# The text before the section, the section body and the text after it.
my ($head, $tail) = ('', '');
if (defined $section && $section ne '') {
  if ($text =~ /^\Q$section\E[ \t]*\r?\n/m) {
    $head = substr($text, 0, $+[0]);
    my $rest = substr($text, $+[0]);
    if ($rest =~ /^\[/m) {
      $tail = substr($rest, $-[0]);
      $rest = substr($rest, 0, $-[0]);
    }
    $text = $rest;
  } else {
    $text = '';
  }
}

if ($mode eq 'find') {
  my ($version_index) = grep { $kinds[$_] eq 'version' } 0 .. $#kinds;
  while ($text =~ /$compiled/g) {
    print defined $version_index ? ${^CAPTURE}[$version_index] : $&, "\n";
  }
  exit 0;
}

my %value;
for my $kind (grep { $_ ne 'literal' } @kinds) {
  my $name = uc $kind;
  fail("$name is not set, so {$kind} has no value")
    unless defined $ENV{$name} && $ENV{$name} ne '';
  $value{$kind} = $ENV{$name};
}

my $count = 0;
$text =~ s{$compiled}{
  $count++;
  join '', map { $kinds[$_] eq 'literal' ? ${^CAPTURE}[$_] : $value{$kinds[$_]} } 0 .. $#kinds
}ge;

if ($count > 0) {
  open my $out, '>', $file or fail("cannot write $file: $!");
  print {$out} $head, $text, $tail;
  close $out or fail("cannot write $file: $!");
}
print "$count\n";
