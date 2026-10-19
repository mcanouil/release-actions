# shellcheck shell=bash
# The r preset: R package versions and NEWS.md, after the usethis conventions.
# Needs lib/common.sh. Compatible with bash 3.2.

# An R package version: two to four parts, such as 1.2, 1.2.3 or 1.2.3.9000.
R_VERSION_REGEX='^[0-9]+(\.[0-9]+){1,3}$'

# Prints the version after CURRENT for BUMP: patch, minor or major on the
# first three parts, which drops a fourth part; dev, which adds .9000 to a
# version of two or three parts and keeps a four-part version as it is; or an
# explicit version of two or three parts. Parts are read as decimal.
r_next_version() {
  local current="$1" bump="$2" major minor patch extra
  if [[ ! "${current}" =~ ${R_VERSION_REGEX} ]]; then
    die "the current version '${current}' is not an R package version. Use two to four parts, such as 1.2.3 or 1.2.3.9000."
  fi
  IFS=. read -r major minor patch extra <<<"${current}"
  major=$((10#${major}))
  minor=$((10#${minor}))
  patch=$((10#${patch:-0}))
  case "${bump}" in
  major) printf '%d.0.0\n' "$((major + 1))" ;;
  minor) printf '%d.%d.0\n' "${major}" "$((minor + 1))" ;;
  patch) printf '%d.%d.%d\n' "${major}" "${minor}" "$((patch + 1))" ;;
  dev)
    if [[ -n "${extra}" ]]; then
      printf '%s\n' "${current}"
    else
      printf '%d.%d.%d.9000\n' "${major}" "${minor}" "${patch}"
    fi
    ;;
  calver)
    die "bump is calver, which the r preset does not use. Use patch, minor, major, dev, or a version such as 1.2.3."
    ;;
  *)
    if [[ "${bump}" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
      die "bump is '${bump}', which has four parts. The r preset keeps four parts for development versions; use dev, or a version such as 1.2.3."
    fi
    if [[ ! "${bump}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
      die "bump is '${bump}'. Use patch, minor, major, dev, or a version such as 1.2.3."
    fi
    if [[ "${bump}" == "${current}" ]]; then
      die "bump is '${bump}', which is already the current version."
    fi
    printf '%s\n' "${bump}"
    ;;
  esac
}

# Prints the Package: value of the DESCRIPTION file FILE.
r_package() {
  local package
  [[ -f "$1" ]] || die "$1 does not exist. Run bump at the root of the R package."
  package="$(sed -n 's/^Package:[[:space:]]*//p' "$1" | sed -n 1p | tr -d '[:space:]')"
  [[ -n "${package}" ]] || die "$1 has no Package: line. Add one, such as 'Package: mypackage'."
  printf '%s\n' "${package}"
}

# Prints the section of the NEWS.md file FILE under the heading
# "# PACKAGE VERSION", up to the next level-1 heading outside a fenced code
# block, without blank lines around it. VERSION can be "(development version)".
# Returns 2 when no heading matches and 3 when more than one does.
r_news_section() {
  HEADING="# $2 $3" perl -e '
    my ($found, $inside, $fence, @lines) = (0, 0, 0);
    open my $in, "<", $ARGV[0] or die "cannot read $ARGV[0]: $!\n";
    while (my $line = <$in>) {
      $line =~ s/\s+\z//;
      if (!$fence && $line eq $ENV{HEADING}) {
        $found++;
        $inside = 1;
        next;
      }
      if (!$fence && $line =~ /\A# /) {
        $inside = 0;
        next;
      }
      $fence = !$fence if $line =~ /\A\s*(?:```|~~~)/;
      push @lines, $line if $inside;
    }
    close $in;
    exit 2 if $found == 0;
    exit 3 if $found > 1;
    shift @lines while @lines && $lines[0] eq "";
    pop @lines while @lines && $lines[-1] eq "";
    print map { "$_\n" } @lines;
  ' "$1"
}

# Returns 0 when the first line of FILE that is not blank is the heading
# "# PACKAGE (development version)".
r_news_pending() {
  local first
  first="$(sed -n '/[^[:space:]]/{p;q;}' "$1")"
  first="${first%"${first##*[![:space:]]}"}"
  [[ "${first}" == "# $2 (development version)" ]]
}

# Rolls the NEWS.md file FILE of PACKAGE. For a VERSION, renames the heading
# "# PACKAGE (development version)" on the first line that is not blank to
# "# PACKAGE VERSION", and returns 2 without a change when that line is not
# the heading. For dev, puts that heading and an empty line on top, unless the
# first line that is not blank is already the heading.
r_roll_news() {
  local file="$1" development="# $2 (development version)" title="# $2 $3"
  if r_news_pending "${file}" "$2"; then
    [[ "$3" != "dev" ]] || return 0
  else
    [[ "$3" == "dev" ]] || return 2
    title=""
  fi
  DEVELOPMENT="${development}" TITLE="${title}" perl -e '
    open my $in, "<", $ARGV[0] or die "cannot read $ARGV[0]: $!\n";
    my @raw = <$in>;
    close $in;
    my ($index) = grep { $raw[$_] =~ /\S/ } 0 .. $#raw;
    my ($eol) = (defined $index ? $raw[$index] : "") =~ /(\r?\n)\z/;
    $eol //= "\n";
    if ($ENV{TITLE} eq "") {
      unshift @raw, "$ENV{DEVELOPMENT}$eol$eol";
    } else {
      $raw[$index] = "$ENV{TITLE}$eol";
    }
    open my $out, ">", $ARGV[0] or die "cannot write $ARGV[0]: $!\n";
    print {$out} @raw;
    close $out or die "cannot write $ARGV[0]: $!\n";
  ' "${file}"
}
