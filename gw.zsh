# Git worktree helpers
#
# gw <branch>          checkout existing branch in .worktrees/<branch>, cd in
# gw -b <branch>       create new branch + worktree, cd in
# gw -d <branch>       remove worktree + delete branch (safe: refuses if dirty/unmerged)
# gw -D <branch>       force-remove worktree + force-delete branch
# gw -r                cd to the main worktree
# gw                   list worktrees
#
# Worktrees live at <repo>/.worktrees/<sanitized-branch-name>.
# The function ensures `.worktrees/` is in .git/info/exclude and the dir exists.

_gw_help() {
  cat <<'EOF'
gw — git worktree helper

Usage:
  gw                    list worktrees
  gw <branch>           checkout existing branch in .worktrees/<branch>, cd in
  gw -b <branch>        create new branch + worktree, cd in
  gw -d <branch>        remove worktree + delete branch (safe)
  gw -D <branch>        force-remove worktree + force-delete branch
  gw -r                 cd to the main worktree
  gw -h, --help         show this help

Worktrees live at <repo>/.worktrees/<sanitized-branch-name>.
On first use, .worktrees/ is added to .git/info/exclude and created.
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

gw() {
  case "$1" in
    -h|--help) _gw_help; return 0 ;;
  esac

  # No args: list worktrees
  if [[ $# -eq 0 ]]; then
    git worktree list
    return
  fi

  local repo_root mode=add branch dir wt_path
  repo_root=$(_gw_repo_root) || return 1

  case "$1" in
    -r) cd "$repo_root"; return ;;
    -b) mode=create; shift ;;
    -d) mode=delete; shift ;;
    -D) mode=force_delete; shift ;;
  esac

  branch="$1"
  if [[ -z "$branch" ]]; then
    echo "usage: gw [-b|-d|-D] <branch>" >&2
    return 1
  fi

  dir="${branch//\//-}"
  wt_path="$repo_root/.worktrees/$dir"

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
        git -C "$repo_root" worktree add -b "$branch" "$wt_path" || return
      else
        git -C "$repo_root" worktree add "$wt_path" "$branch" || return
      fi

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
  )

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
  esac
}

(( $+functions[compdef] )) && compdef _gw gw
