#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
clone() { # repo, dir
  if [ -d "$2" ]; then echo "  have $2"; return; fi
  echo "==> $2"
  git clone --depth 1 --quiet "$1" "$2"
}

# File icons for the change and commit lists (MIT). Only icons/ and the two
# mapping sources are used; Tools/generate-file-icons.py turns them into the
# bundled icon set.
clone https://github.com/material-extensions/vscode-material-icon-theme.git material-icon-theme
