#!/usr/bin/env bash
#
# setup.sh - install resticagent and its dependencies into ~/.local, without root
#
#   ./setup.sh                    install, or update after a git pull
#   ./setup.sh --uninstall [-y]   remove everything setup.sh installed
#
# It installs the way "make install PREFIX=~/.local" would:
#   ~/.local/bin/resticagent                  the program
#   ~/.local/share/resticagent/systemd/       its systemd unit templates
#   ~/.local/share/resticagent/manifest       every file setup.sh installed
#   ~/.local/share/doc/resticagent/           README.md, USAGE.md, LICENSE
# and only what this host lacks:
#   ~/.local/bin/restic                       the official release, verified with
#                                             restic's GPG key and SHA-256 sums
#   ~/.local/bin/tree                         built from source, for show --tree
#   ~/.local/share/man/man1/tree.1
#
# FUSE, which show needs for its ls listing, cannot be installed like this:
# fusermount3 must be owned by root and setuid. setup.sh checks for it and
# prints the command that installs it. Settings and snapshots are never touched.

if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "error: resticagent needs bash 4.4 or newer" >&2
  exit 1
fi
if (( EUID == 0 )); then
  echo "error: run setup.sh as the user whose backups it is for. For system-wide jobs, use: sudo ./bin/resticagent install" >&2
  exit 1
fi

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# Sourcing the program puts its directory first on PATH; keep the user's own.
USER_PATH=$PATH
# The program's own helpers and paths, so both agree on where everything goes.
# shellcheck source=bin/resticagent
source "$REPO/bin/resticagent"

PREFIX=${BIN_PATH%/bin/resticagent}
MANIFEST="$SHARE_DIR/manifest"
# restic's release signing key, as its installation guide publishes it
RESTIC_KEY_URL=https://restic.net/gpg-key-alex.asc
RESTIC_KEY_FPR=CF8F18F2844575973F79D4E191A6868BD3F7A907
TREE_VERSION=2.3.2
TREE_URL="https://oldmanprogrammer.net/tar/tree/tree-$TREE_VERSION.tgz"
TREE_SHA256=6b941dd6cbecfb4d3250700e4d08d8e0c251488981dd4868b90d744234300e21

declare -A OLD=()   # files the previous run installed, from its manifest
INSTALLED=()        # files this run installed, relative to PREFIX
WORK=''

usage() {
  cat <<USAGE
Usage: ./setup.sh [--uninstall [-y]]

Installs resticagent into $PREFIX, plus restic and tree when this host
lacks them, without root. Run it again after a git pull to update.

  --uninstall   Remove everything setup.sh installed. Remove your jobs first
                with: resticagent remove --all
  -y, --yes     Do not ask before uninstalling.

Set RESTIC_VERSION to install that restic release instead of the latest.
USAGE
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# fetch URL FILE -> downloads URL to FILE
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    die "downloading needs curl or wget. Install one with: $(pkg_hint curl)"
  fi
}

# pkg_hint PACKAGE -> the command that installs PACKAGE on this host
pkg_hint() {
  if command -v apt-get >/dev/null 2>&1; then printf 'sudo apt install %s' "$1"
  elif command -v dnf >/dev/null 2>&1; then printf 'sudo dnf install %s' "$1"
  elif command -v pacman >/dev/null 2>&1; then printf 'sudo pacman -S %s' "$1"
  elif command -v zypper >/dev/null 2>&1; then printf 'sudo zypper install %s' "$1"
  else printf "your package manager's %s package" "$1"
  fi
}

# older VERSION MIN -> true when VERSION sorts before MIN
older() { [[ "$1" != "$2" && "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]; }

restic_version() { "$1" version 2>/dev/null | sed -n 's/^restic \([0-9][0-9.]*\) .*/\1/p'; }
tree_version() { "$1" --version 2>/dev/null | sed -n 's/^tree v\([0-9][0-9.]*\) .*/\1/p'; }

# latest_restic -> the version of restic's latest release, from GitHub's redirect
latest_restic() {
  local url=https://github.com/restic/restic/releases/latest
  {
    if command -v curl >/dev/null 2>&1; then curl -fsSI "$url" || true
    else wget -S --spider --max-redirect=0 "$url" 2>&1 || true
    fi
  } | tr -d '\r' | sed -n 's#^ *[Ll]ocation: .*/tag/v\([0-9][0-9.]*\)$#\1#p' | head -n 1
}

restic_arch() {
  case $(uname -m) in
    x86_64)        echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv6l|armv7l) echo arm ;;
    i?86)          echo 386 ;;
    ppc64le|riscv64|s390x) uname -m ;;
    *) return 1 ;;
  esac
}

# ours FILE -> true when a previous run of setup.sh installed FILE (relative to PREFIX)
ours() { [[ -n "${OLD[$1]:-}" && -e "$PREFIX/$1" ]]; }

# put FILE MODE SOURCE -> installs SOURCE as PREFIX/FILE and records it
put() {
  write_file "$PREFIX/$1" "$2" <"$3"
  INSTALLED+=("$1")
}

cleanup() {
  [[ -n "$WORK" ]] || return 0
  if [[ -d "$WORK/gnupg" ]]; then gpgconf --homedir "$WORK/gnupg" --kill all >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

# install_restic VERSION -> downloads the official release into PREFIX/bin,
# after checking its SHA-256 sum and, with gpg, the signature on the sums
install_restic() {
  local v=$1 arch file base signer
  arch=$(restic_arch) || die "restic publishes no release for $(uname -m). Install it with: $(pkg_hint restic)"
  command -v bunzip2 >/dev/null 2>&1 || die "unpacking restic needs bunzip2. Install it with: $(pkg_hint bzip2)"
  file="restic_${v}_linux_${arch}.bz2"
  base="https://github.com/restic/restic/releases/download/v$v"
  info "  download   restic $v for linux/$arch"
  { fetch "$base/SHA256SUMS" "$WORK/SHA256SUMS" && fetch "$base/$file" "$WORK/$file"; } \
    || die "could not download restic $v from $base"
  if command -v gpg >/dev/null 2>&1; then
    { fetch "$base/SHA256SUMS.asc" "$WORK/SHA256SUMS.asc" && fetch "$RESTIC_KEY_URL" "$WORK/restic-key.asc"; } \
      || die "could not download the signature of restic $v or its key"
    mkdir -m 0700 "$WORK/gnupg"
    GNUPGHOME="$WORK/gnupg" gpg --batch --quiet --import "$WORK/restic-key.asc" 2>/dev/null \
      || die "could not read restic's signing key from $RESTIC_KEY_URL"
    # VALIDSIG ends with the primary key that made the signature. The key file
    # also holds an old, revoked key, so the fingerprint is what counts.
    signer=$(GNUPGHOME="$WORK/gnupg" gpg --batch --status-fd 1 --verify "$WORK/SHA256SUMS.asc" "$WORK/SHA256SUMS" 2>/dev/null \
      | awk '$2 == "VALIDSIG" { print $NF }') || true
    [[ "$signer" == "$RESTIC_KEY_FPR" ]] \
      || die "the signature on the checksums of restic $v is not valid, so restic was not installed"
    ok "verified   the signature on restic's checksums (key ${RESTIC_KEY_FPR: -16})"
  else
    warn "gpg is not installed, so only the SHA-256 sum of restic is checked, not its signature. Install gpg with: $(pkg_hint gnupg)"
  fi
  (cd "$WORK" && awk -v f="$file" '$2 == f' SHA256SUMS | sha256sum -c --status) \
    || die "$file does not match its SHA-256 sum, so restic was not installed"
  ok "verified   the SHA-256 sum of $file"
  { bunzip2 -c "$WORK/$file" >"$WORK/restic" && chmod 0755 "$WORK/restic"; } || die "could not unpack $file"
  [[ "$(restic_version "$WORK/restic")" == "$v" ]] || die "the downloaded restic $v does not run on this host"
  put bin/restic 0755 "$WORK/restic"
}

dep_restic() {
  local have='' v latest
  # resticagent runs the restic next to it first, then the one on PATH.
  if [[ -x "$PREFIX/bin/restic" ]]; then have="$PREFIX/bin/restic"; else have=$(command -v restic || true); fi
  v=${have:+$(restic_version "$have")}

  if ours bin/restic; then
    latest=${RESTIC_VERSION:-$(latest_restic)}
    if [[ -z "$latest" ]]; then
      warn "could not look up the latest restic release, keeping restic $v"
    elif [[ -z "$v" ]] || older "$v" "$latest"; then
      install_restic "$latest"
      return
    fi
    INSTALLED+=(bin/restic)
    info "  current    restic $v in $PREFIX/bin"
  elif [[ -n "$v" ]] && ! older "$v" "0.$MIN_RESTIC_MINOR"; then
    info "  found      restic $v at $have"
  elif [[ "$have" == "$PREFIX/bin/restic" ]]; then
    die "$have is restic ${v:-of an unknown version}, but 0.$MIN_RESTIC_MINOR or newer is needed. setup.sh did not install it, so it leaves it alone: replace or remove it, then run setup.sh again"
  else
    if [[ -n "$have" ]]; then note "  restic ${v:-of an unknown version} at $have is older than 0.$MIN_RESTIC_MINOR, so a current one goes into $PREFIX/bin"; fi
    latest=${RESTIC_VERSION:-$(latest_restic)}
    [[ -n "$latest" ]] || die "could not look up the latest restic release. Set RESTIC_VERSION, e.g. RESTIC_VERSION=0.19.1 ./setup.sh"
    install_restic "$latest"
  fi
}

# install_tree -> builds the pinned tree release into PREFIX. tree only serves
# show --tree, so a failure is a warning, not an error.
install_tree() {
  local cc dir="$WORK/tree-$TREE_VERSION"
  cc=$(command -v cc || command -v gcc || true)
  if [[ -z "$cc" ]] || ! command -v make >/dev/null 2>&1; then
    warn "tree is not installed, and building it needs a C compiler and make. show --tree needs it. Install it with: $(pkg_hint tree)"
    return 0
  fi
  info "  download   tree $TREE_VERSION"
  if ! fetch "$TREE_URL" "$WORK/tree.tgz"; then
    warn "could not download $TREE_URL, so tree is not installed. Install it with: $(pkg_hint tree)"
    return 0
  fi
  printf '%s  %s\n' "$TREE_SHA256" "$WORK/tree.tgz" | sha256sum -c --status \
    || die "tree-$TREE_VERSION.tgz does not match its SHA-256 sum, so tree was not installed"
  ok "verified   the SHA-256 sum of tree-$TREE_VERSION.tgz"
  info "  build      tree $TREE_VERSION with $cc"
  if ! { tar -xzf "$WORK/tree.tgz" -C "$WORK" && make -C "$dir" CC="$cc" >"$WORK/tree-build.log" 2>&1; }; then
    tail -n 20 "$WORK/tree-build.log" 2>/dev/null | sed 's/^/  /' >&2
    warn "building tree failed, so it is not installed. Install it with: $(pkg_hint tree)"
    return 0
  fi
  put bin/tree 0755 "$dir/tree"
  put share/man/man1/tree.1 0644 "$dir/doc/tree.1"
}

dep_tree() {
  local have v
  if ours bin/tree; then
    v=$(tree_version "$PREFIX/bin/tree")
    if [[ "$v" != "$TREE_VERSION" ]]; then install_tree; return; fi
    INSTALLED+=(bin/tree)
    if ours share/man/man1/tree.1; then INSTALLED+=(share/man/man1/tree.1); fi
    info "  current    tree $v in $PREFIX/bin"
  elif have=$(command -v tree); then
    info "  found      tree $(tree_version "$have") at $have"
  else
    install_tree
  fi
}

dep_system() {
  local tool helper
  if [[ -e /dev/fuse ]] && helper=$(command -v fusermount3 || command -v fusermount); then
    info "  found      FUSE, with $helper"
  else
    warn "FUSE is not available, so show cannot list snapshots with ls (show --tree still works). Install it with: $(pkg_hint fuse3)"
  fi
  for tool in systemctl journalctl systemd-analyze; do
    command -v "$tool" >/dev/null 2>&1 || warn "$tool is missing. resticagent schedules and monitors backups with systemd"
  done
  if [[ -d /run/systemd/system ]]; then
    info "  found      systemd $(systemd_version)"
  else
    warn "systemd is not running on this host, so backups cannot be scheduled here"
  fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

do_install() {
  local doc f
  local -a old=()
  load_lines old "$MANIFEST"
  for f in "${old[@]}"; do OLD[$f]=1; done
  WORK=$(mktemp -d)
  trap cleanup EXIT

  # Dependencies first: when restic cannot be installed, nothing else is either.
  header "Dependencies"
  info "  found      bash $BASH_VERSION"
  dep_restic
  dep_tree
  dep_system

  header "resticagent $VERSION"
  install_program
  INSTALLED+=(bin/resticagent "share/resticagent/systemd/${UNIT_PREFIX}.service" "share/resticagent/systemd/${UNIT_PREFIX}.timer")
  for doc in README.md USAGE.md LICENSE; do put "share/doc/resticagent/$doc" 0644 "$REPO/$doc"; done

  INSTALLED+=(share/resticagent/manifest)
  write_file "$MANIFEST" 0644 < <(printf '%s\n' "${INSTALLED[@]}" | sort -u)
  for f in "${old[@]}"; do
    # A dependency the host now has itself is no longer setup.sh's to keep.
    if [[ " ${INSTALLED[*]} " != *" $f "* && -e "$PREFIX/$f" ]]; then note "  no longer managed by setup.sh: $PREFIX/$f"; fi
  done

  header "Done"
  ok "resticagent $VERSION is installed in $PREFIX"
  case ":$USER_PATH:" in
    *":$PREFIX/bin:"*)
      f=$(PATH=$USER_PATH command -v resticagent || true)
      if [[ "$f" != "$PREFIX/bin/resticagent" ]]; then
        warn "'resticagent' runs $f, which comes before $PREFIX/bin on your PATH"
      fi ;;
    *)
      warn "$PREFIX/bin is not on your PATH. Most distributions add it at your next login. If yours does not, add this line to ~/.profile, or ~/.zshrc for zsh:"
      info "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac
  if [[ -f "$SYSTEMD_DIR/${UNIT_PREFIX}.service" ]]; then
    note "Bring your jobs' units up to date with: resticagent install"
  elif [[ -z "$(list_jobs)" ]]; then
    note "Next: resticagent add <job>, then resticagent install"
  fi
}

do_uninstall() {
  local yes=$1 f
  local -a files=() present=()
  [[ -f "$MANIFEST" ]] || die "setup.sh has not installed anything in $PREFIX: $MANIFEST does not exist"
  if [[ -f "$SYSTEMD_DIR/${UNIT_PREFIX}.service" || -n "$(installed_jobs)" ]]; then
    die "your backup jobs are still installed. Remove them first with: resticagent remove --all"
  fi
  load_lines files "$MANIFEST"
  for f in "${files[@]}"; do
    if [[ -e "$PREFIX/$f" || -L "$PREFIX/$f" ]]; then present+=("$f"); fi
  done

  header "This will delete"
  for f in "${present[@]}"; do info "  - $PREFIX/$f"; done
  note "Your settings in $CONFIG_DIR and your snapshots stay."
  if (( ! yes )); then
    ask_yesno "Proceed?" n || die "nothing removed"
  fi

  header "Removing"
  for f in "${present[@]}"; do
    rm -f -- "${PREFIX:?}/$f"
    ok "deleted    $PREFIX/$f"
  done
  rmdir "$SHARE_DIR/systemd" "$SHARE_DIR" "$PREFIX/share/doc/resticagent" 2>/dev/null || true
  ok "uninstalled resticagent from $PREFIX"
}

main_setup() {
  local uninstall=0 yes=0 arg
  for arg in "$@"; do
    case $arg in
      --uninstall)    uninstall=1 ;;
      -y|--yes)       yes=1 ;;
      -h|--help|help) usage; return 0 ;;
      *)              die "unknown argument '$arg' (see ./setup.sh --help)" ;;
    esac
  done
  if (( yes && ! uninstall )); then die "-y only applies to --uninstall"; fi
  if (( uninstall )); then do_uninstall "$yes"; else do_install; fi
}

main_setup "$@"
