#!/bin/sh
# Git for the private docs, which live in this folder but only in a local repository, never on
# GitHub: docs/, ROADMAP.md, AGENTS.md and CLAUDE.md. Use it like git:
#   tools/docs_git.sh status
#   tools/docs_git.sh add docs/status.md && tools/docs_git.sh commit -m "..."
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec git --git-dir="$ROOT/.git-docs" --work-tree="$ROOT" "$@"
