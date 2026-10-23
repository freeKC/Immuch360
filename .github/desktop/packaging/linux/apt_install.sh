#!/bin/sh
# Installs Ubuntu or Debian packages with apt-get without waiting on a slow mirror until the job runs out of time.
#
# Why: the Linux build of the desktop workflow waited in apt-get until its 45 minute timeout three times on 22 and 23
# October 2026 (desktop runs 39835438528, 39851016802 and 39882296036). azure.archive.ubuntu.com, the mirror of the
# runners, served the 170 MB of its packages at about 45 kB/s, where a good day takes 11 seconds. The mirror list of
# the runner (/etc/apt/apt-mirrors.txt) goes to its next mirror when a file fails, not when it comes slowly.
#
# How: the packages and their dependencies are downloaded first, in three attempts at most, each with its own
# apt-get update and one time limit for both (APT_ATTEMPT_SECONDS, 150 by default). The first attempt uses the sources
# of the system; the next ones a sources list of their own on another mirror of the distribution:
#   Ubuntu  mirrors.edge.kernel.org/ubuntu, then archive.ubuntu.com
#   Debian  mirrors.edge.kernel.org/debian, then ftp.debian.org, with the security updates from security.debian.org
# over plain HTTP, since the containers of the package checks have no CA certificates: apt checks every file against
# the signed Release file of the archive, whichever mirror served it. The files already downloaded stay in apt's
# cache, so a later attempt fetches the missing ones only (the Docker images empty that cache at each update, there
# it starts over). Then the packages are installed from that cache, which holds every file by then: an attempt is
# stopped while it downloads, never while dpkg installs. (--no-download is not used: the apt 2.6 of Debian 12 then
# fails on a .deb file given as an argument, "Pathname to install is not absolute".) The mirror that worked is the
# first one tried by the next call on the same machine.
#
#   apt_install.sh PACKAGE|FILE.deb...
#
# Run as root (sudo on a runner). The arguments are those of apt-get install, .deb files included. The notes of the
# attempts go to stderr, the output of apt-get to stdout. Exit 1 with an error line (a workflow annotation) when no
# attempt got every file.
set -eu

[ "$#" -gt 0 ] || { echo "usage: apt_install.sh PACKAGE|FILE.deb..." >&2; exit 2; }
seconds=${APT_ATTEMPT_SECONDS:-150}
state=/tmp/apt_install.mirror
# shellcheck source=/dev/null
. /etc/os-release
codename=${VERSION_CODENAME:?no VERSION_CODENAME in /etc/os-release}
case "$ID" in
  ubuntu)
    fallbacks='http://mirrors.edge.kernel.org/ubuntu http://archive.ubuntu.com/ubuntu'
    keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
    components='main restricted universe multiverse'
    security=''
    ;;
  debian)
    fallbacks='http://mirrors.edge.kernel.org/debian http://ftp.debian.org/debian'
    keyring=/usr/share/keyrings/debian-archive-keyring.gpg
    components=main
    security=http://security.debian.org/debian-security
    ;;
  *) echo "::error::apt_install.sh: $ID is neither Ubuntu nor Debian" >&2; exit 1 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/parts"

# The sources list of a mirror: the release, its updates and its security updates
sources_on() {
  echo "deb [signed-by=$keyring] $1 $codename $components"
  echo "deb [signed-by=$keyring] $1 $codename-updates $components"
  echo "deb [signed-by=$keyring] ${security:-$1} $codename-security $components"
}

note() {
  echo "apt_install.sh: $*" >&2
}

# The mirror that worked last on this machine first, then the others in their order
order="system $fallbacks"
if [ -s "$state" ]; then
  last=$(cat "$state")
  order="$last $(for mirror in $order; do [ "$mirror" = "$last" ] || printf '%s ' "$mirror"; done)"
fi

attempt=0
for mirror in $order; do
  attempt=$((attempt + 1))
  [ "$attempt" -le 3 ] || break
  [ "$attempt" -eq 1 ] || sleep 5
  if [ "$mirror" = system ]; then
    options=''
    where="the sources of the system"
  else
    sources_on "$mirror" >"$work/sources.list"
    options="-o Dir::Etc::SourceList=$work/sources.list -o Dir::Etc::SourceParts=$work/parts"
    where=$mirror
  fi
  note "attempt $attempt of 3 on $where, $seconds seconds at most"
  start=$(date +%s)
  status=0
  # timeout stops apt-get and its download methods together (their process group), then kills them 10 s later
  # shellcheck disable=SC2086
  timeout -k 10 "$seconds" apt-get $options --error-on=any update 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    left=$((start + seconds - $(date +%s)))
    [ "$left" -ge 1 ] || left=1
    # shellcheck disable=SC2086
    timeout -k 10 "$left" apt-get $options install -y --download-only "$@" 2>&1 || status=$?
  fi
  took=$(($(date +%s) - start))
  if [ "$status" -eq 0 ]; then
    note "downloaded from $where in $took s, now installed from apt's cache"
    echo "$mirror" >"$state"
    # shellcheck disable=SC2086
    apt-get $options install -y "$@" 2>&1 \
      || { echo "::error::apt_install.sh: the packages downloaded from $where did not install" >&2; exit 1; }
    exit 0
  fi
  case "$status" in
    124 | 137) note "attempt $attempt on $where stopped after $took s: the mirror is too slow or does not answer" ;;
    *) note "attempt $attempt on $where failed in $took s (exit code $status)" ;;
  esac
done

echo "::error::apt_install.sh: no mirror gave the packages in 3 attempts of $seconds seconds ($order)" >&2
exit 1
