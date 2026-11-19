# Git worktree helpers
#
# gw <branch>          checkout existing branch in .worktrees/<branch>, cd in
# gw -b <branch> [<start>]  create new branch (from <start>, default HEAD) + worktree, cd in
# gw -d <branch>       remove worktree + delete branch (safe: refuses if dirty/unmerged)
# gw -D <branch>       force-remove worktree + force-delete branch
# gw -r                cd to the main worktree
# gw                   list worktrees
# gw --no-cow ...      skip cloning gitignored files into a new worktree
#
# Worktrees live at <repo>/.worktrees/<sanitized-branch-name>.
# The function ensures `.worktrees/` is in .git/info/exclude and the dir exists.
# New worktrees get copy-on-write clones of the main worktree's gitignored files
# (APFS on macOS; btrfs, XFS, bcachefs, ZFS on Linux).

_gw_help() {
  cat <<'EOF'
gw — git worktree helper

Usage:
  gw                    list worktrees
  gw <branch>           checkout existing branch in .worktrees/<branch>, cd in
  gw -b <branch> [<start>]
                        create new branch (from <start>, default HEAD) + worktree, cd in
  gw -d <branch>        remove worktree + delete branch (safe)
  gw -D <branch>        force-remove worktree + force-delete branch
  gw -r                 cd to the main worktree
  gw --no-cow <...>     don't clone gitignored files into the new worktree
  gw -h, --help         show this help

Worktrees live at <repo>/.worktrees/<sanitized-branch-name>.
On first use, .worktrees/ is added to .git/info/exclude and created.

New worktrees get copy-on-write clones of the main worktree's gitignored
files (node_modules, .env, build output): instant, no extra disk. Needs APFS
on macOS, or btrfs, XFS, bcachefs or ZFS on Linux; skipped elsewhere.
  - .worktreeinclude (gitignore syntax) limits it to the ignored paths it matches
  - virtualenvs and CMake build dirs are skipped unless .worktreeinclude lists them
  - `git config gw.cow false` turns it off (per repo, or --global)
EOF
}

_gw_repo_root() {
  local common_dir
  common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    echo "not in a git repo" >&2
    return 1
  }
  (cd "$common_dir/.." && pwd)
}

_gw_path_for_branch() {
  git worktree list --porcelain 2>/dev/null | awk -v want="branch refs/heads/$1" '
    /^worktree / { path = substr($0, 10) }
    $0 == want   { print path; exit }
  '
}

_gw_ensure_worktrees_dir() {
  local repo_root="$1"
  local exclude_file="$repo_root/.git/info/exclude"

  # If we're inside a linked worktree, .git/info/exclude lives in the common dir.
  [[ -f "$exclude_file" ]] || exclude_file="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"

  if [[ -f "$exclude_file" ]] && ! grep -qxF ".worktrees/" "$exclude_file" 2>/dev/null; then
    echo ".worktrees/" >> "$exclude_file"
    echo "added .worktrees/ to $exclude_file"
  fi

  [[ -d "$repo_root/.worktrees" ]] || mkdir -p "$repo_root/.worktrees"
}

# --- copy-on-write ------------------------------------------------------------

# macOS `cp -c` silently falls back to a full copy, so check for APFS there.
# On Linux, only a real reflink attempt gives a reliable answer.
_gw_cow_supported() {
  emulate -L zsh
  local dir="$1" dev probe rc
  case "$OSTYPE" in
    darwin*)
      dev=$(df -P "$dir" 2>/dev/null | awk 'NR == 2 { print $1 }')
      [[ -n "$dev" ]] && mount | awk -v dev="$dev on " '
        index($0, dev) == 1 && /\(apfs[,)]/ { found = 1 }
        END { exit !found }
      '
      ;;
    linux*)
      probe=$(mktemp "$dir/.gw-cow-probe.XXXXXX" 2>/dev/null) || return 1
      print gw > "$probe"
      cp --reflink=always "$probe" "$probe.clone" 2>/dev/null
      rc=$?
      rm -f "$probe" "$probe.clone"
      return $rc
      ;;
    *) return 1 ;;
  esac
}

_gw_cow_copy() {
  emulate -L zsh
  case "$OSTYPE" in
    darwin*) cp -c -pR "$1" "$2" ;;
    *)       cp -a --reflink=always "$1" "$2" ;;
  esac
}

# Clones one gitignored path (relative to the worktree root) from $1 to $2.
# Paths that hold another checkout or absolute paths back to the source are
# skipped, since a clone would keep reading from or building into the source.
_gw_cow_clone_entry() {
  emulate -L zsh
  local src="$1" dst="$2" rel="$3" include="$4" comp child rc=0
  local -a never_names=(.hg .jj .svn .bzr .pijul .sl .worktrees .conductor .entire)
  local -a never_paths=(.claude/worktrees)

  for comp in ${(s:/:)rel}; do
    (( ${never_names[(Ie)$comp]} )) && return 0
  done
  (( ${never_paths[(Ie)$rel]} )) && return 0
  [[ -e "$src/$rel/.git" ]] && return 0
  [[ -e "$dst/$rel" || -L "$dst/$rel" ]] && return 0

  # Virtualenvs and CMake build dirs embed absolute paths; .worktreeinclude can opt in.
  if (( ! include )) && [[ -f "$src/$rel/pyvenv.cfg" || -f "$src/$rel/CMakeCache.txt" ]]; then
    return 0
  fi

  # A skipped path nested inside this directory: clone the children one by one.
  if [[ -d "$src/$rel" && ! -L "$src/$rel" ]] && (( ${never_paths[(I)$rel/*]} )); then
    mkdir -p "$dst/$rel" || return 1
    for child in "$src/$rel"/*(DN); do
      _gw_cow_clone_entry "$src" "$dst" "$rel/${child:t}" "$include" || rc=1
    done
    return $rc
  fi

  mkdir -p "$dst/${rel:h}" && _gw_cow_copy "$src/$rel" "$dst/$rel"
}

# Clones $1's gitignored files (node_modules, .env, build output, ...) into the
# new worktree $2. If $1/.worktreeinclude exists, only ignored paths that also
# match it are cloned.
_gw_cow_populate() {
  emulate -L zsh
  local src="$1" dst="$2" include=0 g i p failed=0
  local -a ignored included
  local -aU paths

  if ! _gw_cow_supported "$dst"; then
    echo "gw: no copy-on-write support on this filesystem; skipped copying ignored files" >&2
    return 0
  fi

  ignored=(${(0)"$(git -C "$src" ls-files -z --others --ignored --exclude-standard --directory)"})

  if [[ -f "$src/.worktreeinclude" ]]; then
    include=1
    included=(${(0)"$(git -C "$src" ls-files -z --others --ignored --directory \
      --exclude-from="$src/.worktreeinclude")"})
    # Both lists collapse whole directories to "dir/", so intersect by prefix.
    for g in $ignored; do
      for i in $included; do
        if [[ $g == $i || ( $i == */ && $g == ${i}* ) ]]; then
          paths+=$g
          break
        elif [[ $g == */ && $i == ${g}* ]]; then
          paths+=$i
        fi
      done
    done
  else
    paths=($ignored)
  fi

  (( $#paths )) || return 0

  for p in $paths; do
    _gw_cow_clone_entry "$src" "$dst" "${p%/}" "$include" || failed=1
  done

  if (( failed )); then
    echo "gw: some ignored files failed to clone (see above)" >&2
  else
    echo "gw: cloned ignored files from $src (copy-on-write)" >&2
  fi
}

gw() {
  case "$1" in
    -h|--help) _gw_help; return 0 ;;
  esac

  # No args: list worktrees
  if [[ $# -eq 0 ]]; then
    git worktree list
    return
  fi

  local repo_root mode=add branch start dir wt_path existing cow=1
  repo_root=$(_gw_repo_root) || return 1

  [[ "$1" == --no-cow ]] && { cow=0; shift; }
  [[ "$(git -C "$repo_root" config --bool gw.cow 2>/dev/null)" == false ]] && cow=0

  case "$1" in
    -r) cd "$repo_root"; return ;;
    -b) mode=create; shift ;;
    -d) mode=delete; shift ;;
    -D) mode=force_delete; shift ;;
  esac

  branch="$1"
  start="$2"
  if [[ -z "$branch" ]]; then
    echo "usage: gw [-b|-d|-D] <branch>" >&2
    return 1
  fi

  dir="${branch//\//-}"
  wt_path="$repo_root/.worktrees/$dir"

  existing=$(_gw_path_for_branch "$branch")
  [[ -n "$existing" ]] && wt_path="$existing"

  case "$mode" in
    delete)
      [[ "$PWD" == "$wt_path" || "$PWD" == "$wt_path"/* ]] && cd "$repo_root"
      git -C "$repo_root" worktree remove "$wt_path" && \
        git -C "$repo_root" branch -d "$branch"
      ;;
    force_delete)
      [[ "$PWD" == "$wt_path" || "$PWD" == "$wt_path"/* ]] && cd "$repo_root"
      git -C "$repo_root" worktree remove --force "$wt_path" 2>/dev/null
      git -C "$repo_root" branch -D "$branch" 2>/dev/null
      ;;
    *)
      _gw_ensure_worktrees_dir "$repo_root"

      if [[ -d "$wt_path" ]]; then
        cd "$wt_path"
        return
      fi

      if [[ "$mode" == create ]]; then
        git -C "$repo_root" worktree add -b "$branch" "$wt_path" ${start:+"$start"} || return
      else
        git -C "$repo_root" worktree add "$wt_path" "$branch" || return
      fi

      (( cow )) && _gw_cow_populate "$repo_root" "$wt_path"
      cd "$wt_path"
      ;;
  esac
}

# --- completion ---------------------------------------------------------------

_gw_worktree_branches() {
  git worktree list --porcelain 2>/dev/null | \
    awk '/^worktree / {p=$2} /^branch refs\/heads\// {b=substr($2, 12); if (p ~ /\.worktrees\//) print b}'
}

_gw() {
  local -a flags worktrees all_branches other_branches
  flags=(
    '-b:create new branch + worktree'
    '-d:remove worktree + delete branch'
    '-D:force-remove worktree + force-delete branch'
    '-r:cd to main worktree'
    '-h:show help'
    '--help:show help'
    '--no-cow:skip cloning gitignored files into the new worktree'
  )

  if [[ $words[2] == --no-cow ]] && (( CURRENT > 2 )); then
    words[2]=()
    (( CURRENT-- ))
  fi

  case $CURRENT in
    2)
      worktrees=(${(f)"$(_gw_worktree_branches)"})
      all_branches=(${(f)"$(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)"})
      local b
      for b in $all_branches; do
        (( ${worktrees[(I)$b]} )) || other_branches+=$b
      done
      _describe -t worktrees 'worktree' worktrees
      _describe -t branches 'branch' other_branches
      _describe -t flags 'option' flags
      ;;
    3)
      case $words[2] in
        -d|-D)
          worktrees=(${(f)"$(_gw_worktree_branches)"})
          _describe -t worktrees 'worktree branch' worktrees
          ;;
        -b)
          all_branches=(${(f)"$(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)"})
          _describe -t branches 'existing branch (for reference)' all_branches
          ;;
      esac
      ;;
    4)
      if [[ $words[2] == -b ]]; then
        all_branches=(${(f)"$(git for-each-ref --format='%(refname:short)' refs/heads/ refs/remotes/ 2>/dev/null)"})
        _describe -t branches 'start point' all_branches
      fi
      ;;
  esac
}

(( $+functions[compdef] )) && compdef _gw gw
