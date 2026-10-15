#!/usr/bin/env perl
# Prints a changelog section without the blank lines around it.
#
#   section.pl unreleased FILE          The section under "## Unreleased" or
#                                       "## [Unreleased]".
#   section.pl version FILE TEMPLATE V  The section under TEMPLATE, where
#                                       {version} is V and {date} is any
#                                       YYYY-MM-DD date.
#
# A section ends at the next "## " line outside a fenced code block. Exits 2
# when no heading matches and 3 when more than one does.
use strict;
use warnings;

sub fail {
  print STDERR "section.pl: @_\n";
  exit 1;
}

my ($mode, $file, $template, $version) = @ARGV;
my $heading;
if (defined $file && $mode eq 'unreleased') {
  $heading = qr/\A## (?:Unreleased|\[Unreleased\])[ \t]*\z/;
} elsif (defined $version && $mode eq 'version') {
  my $regex = join '', map {
      $_ eq '{version}' ? quotemeta($version)
    : $_ eq '{date}'    ? '[0-9]{4}-[0-9]{2}-[0-9]{2}'
    : quotemeta($_)
  } grep { $_ ne '' } split /(\{version\}|\{date\})/, $template;
  $heading = qr/\A$regex[ \t]*\z/;
} else {
  fail('usage: section.pl unreleased FILE | section.pl version FILE TEMPLATE VERSION');
}

open my $in, '<', $file or fail("cannot read $file: $!");
my @lines;
my ($found, $inside, $fence) = (0, 0, 0);
while (my $line = <$in>) {
  $line =~ s/\r?\n\z//;
  $line =~ s/\r\z//;
  if (!$fence && $line =~ $heading) {
    $found++;
    $inside = 1;
    next;
  }
  if (!$fence && $line =~ /\A## /) {
    $inside = 0;
    next;
  }
  $fence = !$fence if $line =~ /\A\s*(?:```|~~~)/;
  push @lines, $line if $inside;
}
close $in;

exit 2 if $found == 0;
exit 3 if $found > 1;
shift @lines while @lines && $lines[0] =~ /\A\s*\z/;
pop @lines while @lines && $lines[-1] =~ /\A\s*\z/;
print map { "$_\n" } @lines;
