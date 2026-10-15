# shellcheck shell=bash
# Version arithmetic for the bump action. Needs lib/common.sh.

# shellcheck disable=SC2034 # Read by the scripts that source this file.
VERSION_REGEX='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'

# Prints the version after CURRENT for BUMP (patch, minor, major, calver, or an
# explicit version) on DATE (YYYY-MM-DD). Parts are read as decimal, so CalVer
# parts such as 08 do not fail as octal.
next_version() {
  local current="$1" bump="$2" date="$3"
  local core major minor patch base suffix
  if [[ ! "${current}" =~ ${VERSION_REGEX} ]]; then
    die "the current version '${current}' is not X.Y.Z or X.Y.Z-suffix."
  fi
  core="${current%%-*}"
  IFS=. read -r major minor patch <<<"${core}"
  major=$((10#${major}))
  minor=$((10#${minor}))
  patch=$((10#${patch}))
  case "${bump}" in
  major) printf '%d.0.0\n' "$((major + 1))" ;;
  minor) printf '%d.%d.0\n' "${major}" "$((minor + 1))" ;;
  patch) printf '%d.%d.%d\n' "${major}" "${minor}" "$((patch + 1))" ;;
  calver)
    base="${date//-/.}"
    if [[ "${current}" == "${base}" ]]; then
      printf '%s-2\n' "${base}"
    elif [[ "${current}" == "${base}"-* ]]; then
      suffix="${current#"${base}"-}"
      if [[ ! "${suffix}" =~ ^[0-9]+$ ]]; then
        die "the current version '${current}' has a suffix that is not a number."
      fi
      printf '%s-%d\n' "${base}" "$((10#${suffix} + 1))"
    else
      printf '%s\n' "${base}"
    fi
    ;;
  *)
    if [[ ! "${bump}" =~ ${VERSION_REGEX} ]]; then
      die "bump is '${bump}'. Use patch, minor, major, calver, or a version such as 1.2.3."
    fi
    if [[ "${bump}" == "${current}" ]]; then
      die "bump is '${bump}', which is already the current version."
    fi
    printf '%s\n' "${bump}"
    ;;
  esac
}

# Prints the major part of VERSION: 1 for 1.5.0, 2026 for 2026.10.15-2.
version_major() {
  local core="${1%%-*}"
  printf '%s\n' "${core%%.*}"
}

# Prints the major and minor parts of VERSION: 1.5 for 1.5.0.
version_minor() {
  local core="${1%%-*}"
  printf '%s\n' "${core%.*}"
}

# Reads tag names on standard input and prints the highest one that is PREFIX
# followed by X.Y.Z or X.Y.Z-N, without PREFIX. Prints nothing when none is.
highest_version() {
  PREFIX="$1" perl -ne '
    chomp;
    next unless s/\A\Q$ENV{PREFIX}\E(?=[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9]+)?\z)//;
    push @versions, $_;
    END {
      my @sorted = sort {
        my @x = split /[.-]/, $a;
        my @y = split /[.-]/, $b;
        $x[3] //= 1;
        $y[3] //= 1;
        $x[0] <=> $y[0] || $x[1] <=> $y[1] || $x[2] <=> $y[2] || $x[3] <=> $y[3]
      } @versions;
      print "$sorted[-1]\n" if @sorted;
    }'
}

# Prints the highest PREFIX X.Y.Z or X.Y.Z-N tag of the current repository,
# without PREFIX, or 0.0.0 when there is none.
latest_tag() {
  local latest
  latest="$(git tag --list | highest_version "$1")"
  printf '%s\n' "${latest:-0.0.0}"
}
