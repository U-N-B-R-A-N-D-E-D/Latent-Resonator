#!/bin/bash
# Remove Co-authored-by from the last commit.
# Run from Terminal.app (outside Cursor) — Cursor adds it when committing from the IDE.
set -e
cd "$(git rev-parse --show-toplevel)"
git log -1 --format="%B" | grep -v "Co-authored-by:" > /tmp/commit_msg_clean.txt
git commit --amend -F /tmp/commit_msg_clean.txt
echo "Done. Co-authored-by removed."
