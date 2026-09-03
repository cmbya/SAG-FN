#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -gt 0 ]; then
  current="$1"
else
  current=""
fi

if [ -z "$current" ]; then
  printf '%s\n' "0.1.0"
  exit 0
fi

if [[ ! "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Invalid local version: %s\n' "$current" >&2
  exit 1
fi

IFS=. read -r major minor patch <<< "$current"
if [ "$patch" -lt 9 ]; then
  patch=$((patch + 1))
else
  patch=0
  minor=$((minor + 1))
fi

printf '%s.%s.%s\n' "$major" "$minor" "$patch"
