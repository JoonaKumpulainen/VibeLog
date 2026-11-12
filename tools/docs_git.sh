#!/bin/sh
# Git for the private docs, which live in this folder but only in a local repository, never on
# GitHub: docs/, ROADMAP.md, AGENTS.md and CLAUDE.md. Use it like git:
#   tools/docs_git.sh status
#   tools/docs_git.sh add docs/status.md && tools/docs_git.sh commit -m "..."
# The folder's .gitignore keeps these out of the public repository, and applies here too, so
# `add` always forces.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$1" = "add" ]; then
  shift
  exec git --git-dir="$ROOT/.git-docs" --work-tree="$ROOT" add -f "$@"
fi
exec git --git-dir="$ROOT/.git-docs" --work-tree="$ROOT" "$@"
