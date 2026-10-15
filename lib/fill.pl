#!/usr/bin/env perl
# Fills {name} placeholders in the text on standard input.
#
#   fill.pl NAMES  NAMES is a comma-separated list of the allowed names. The
#                  value of {name} is the FILL_name environment variable.
#
# Exits 2 and lists the names when the text holds a placeholder outside NAMES,
# and 3 when an allowed placeholder has an empty value. A {name} right after a
# $ is shell text, not a placeholder.
use strict;
use warnings;

my %allowed = map { $_ => 1 } grep { $_ ne '' } split /,/, ($ARGV[0] // '');
my $text = do { local $/; <STDIN> };
$text = '' unless defined $text;

my $placeholder = qr/(?<!\$)\{([a-z][a-z0-9-]*)\}/;
my (%unknown, %empty);
while ($text =~ /$placeholder/g) {
  my $name = $1;
  if (!$allowed{$name}) {
    $unknown{$name} = 1;
    next;
  }
  my $value = $ENV{"FILL_$name"};
  $empty{$name} = 1 unless defined $value && $value ne '';
}

if (%unknown) {
  print STDERR join(', ', map { "{$_}" } sort keys %unknown), "\n";
  exit 2;
}
if (%empty) {
  print STDERR join(', ', map { "{$_}" } sort keys %empty), "\n";
  exit 3;
}

$text =~ s/$placeholder/$ENV{"FILL_$1"}/g;
print $text;
