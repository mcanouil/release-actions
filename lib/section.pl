#!/usr/bin/env perl
# Reads or rolls a changelog section.
#
#   section.pl unreleased FILE          Prints the section under "## Unreleased"
#                                       or "## [Unreleased]".
#   section.pl version FILE TEMPLATE V  Prints the section under TEMPLATE, where
#                                       {version} is V and {date} is any
#                                       YYYY-MM-DD date.
#   section.pl roll FILE                Replaces the Unreleased heading with an
#                                       empty Unreleased heading, in the same
#                                       form, followed by the HEADING
#                                       environment variable.
#
# A section ends at the next "## " line outside a fenced code block. Printed
# sections have no blank lines around them. Exits 2 when no heading matches and
# 3 when more than one does.
use strict;
use warnings;

sub fail {
  print STDERR "section.pl: @_\n";
  exit 1;
}

my ($mode, $file, $template, $version) = @ARGV;
my $heading;
if (defined $file && ($mode eq 'unreleased' || $mode eq 'roll')) {
  $heading = qr/\A## (Unreleased|\[Unreleased\])[ \t]*\z/;
} elsif (defined $version && $mode eq 'version') {
  my $regex = join '', map {
      $_ eq '{version}' ? quotemeta($version)
    : $_ eq '{date}'    ? '[0-9]{4}-[0-9]{2}-[0-9]{2}'
    : quotemeta($_)
  } grep { $_ ne '' } split /(\{version\}|\{date\})/, $template;
  $heading = qr/\A$regex[ \t]*\z/;
} else {
  fail('usage: section.pl unreleased FILE | section.pl version FILE TEMPLATE VERSION | section.pl roll FILE');
}
fail('HEADING is not set') if $mode eq 'roll' && !($ENV{HEADING} // '');

open my $in, '<', $file or fail("cannot read $file: $!");
my (@lines, @raw);
my ($found, $inside, $fence) = (0, 0, 0);
while (my $raw = <$in>) {
  push @raw, $raw;
  (my $line = $raw) =~ s/\r?\n\z//;
  $line =~ s/\r\z//;
  if (!$fence && $line =~ $heading) {
    $found++;
    $inside = 1;
    if ($mode eq 'roll' && $found == 1) {
      my $form = $1;
      my ($eol) = $raw[-1] =~ /(\r?\n)\z/;
      $eol //= "\n";
      $raw[-1] = "## $form$eol$eol$ENV{HEADING}$eol";
    }
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

if ($mode eq 'roll') {
  open my $out, '>', $file or fail("cannot write $file: $!");
  print {$out} @raw;
  close $out or fail("cannot write $file: $!");
  exit 0;
}

shift @lines while @lines && $lines[0] =~ /\A\s*\z/;
pop @lines while @lines && $lines[-1] =~ /\A\s*\z/;
print map { "$_\n" } @lines;
