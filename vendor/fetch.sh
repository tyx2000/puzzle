#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
clone() { # repo, dir, ref
  if [ -d "$2" ]; then echo "  have $2"; return; fi
  echo "==> $2"
  git clone --depth 1 --quiet "$1" "$2"
}
clone https://github.com/tree-sitter/tree-sitter.git             tree-sitter
clone https://github.com/tree-sitter/tree-sitter-json.git        tree-sitter-json
clone https://github.com/tree-sitter/tree-sitter-bash.git        tree-sitter-bash
clone https://github.com/tree-sitter-grammars/tree-sitter-yaml.git tree-sitter-yaml
clone https://github.com/tree-sitter/tree-sitter-typescript.git  tree-sitter-typescript
clone https://github.com/tree-sitter-grammars/tree-sitter-markdown.git tree-sitter-markdown
clone https://github.com/tree-sitter/tree-sitter-html.git      tree-sitter-html
clone https://github.com/tree-sitter/tree-sitter-css.git       tree-sitter-css
clone https://github.com/tree-sitter/tree-sitter-python.git    tree-sitter-python
clone https://github.com/tree-sitter/tree-sitter-rust.git      tree-sitter-rust
clone https://github.com/tree-sitter/tree-sitter-go.git        tree-sitter-go
clone https://github.com/tree-sitter/tree-sitter-c.git         tree-sitter-c
clone https://github.com/tree-sitter-grammars/tree-sitter-toml.git tree-sitter-toml
clone https://github.com/tree-sitter-grammars/tree-sitter-xml.git  tree-sitter-xml
clone https://github.com/camdencheek/tree-sitter-dockerfile.git    tree-sitter-dockerfile
clone https://github.com/shunsambongi/tree-sitter-gitignore.git    tree-sitter-gitignore

# File-tree icons (MIT). Only icons/ and the two mapping sources are used;
# Tools/generate-file-icons.py turns them into the bundled icon set.
clone https://github.com/material-extensions/vscode-material-icon-theme.git material-icon-theme

# tree-sitter-swift does not commit its generated parser.c; take the release
# tarball, which ships src/parser.c + src/scanner.c.
if [ ! -d tree-sitter-swift ]; then
  echo "==> tree-sitter-swift (release tarball)"
  mkdir -p .swift-dl
  curl -sL -o .swift-dl/swift.tar.gz \
    https://github.com/alex-pinkus/tree-sitter-swift/releases/download/0.7.3/tree-sitter-swift.tar.gz
  tar -xzf .swift-dl/swift.tar.gz -C .swift-dl
  rm -f .swift-dl/swift.tar.gz
  mv .swift-dl tree-sitter-swift
fi

# tree-sitter-sql, like swift, does not commit its generated parser.c.
if [ ! -d tree-sitter-sql ]; then
  echo "==> tree-sitter-sql (release tarball)"
  mkdir -p .sql-dl
  curl -sL -o .sql-dl/sql.tar.gz \
    https://github.com/DerekStride/tree-sitter-sql/releases/download/v0.3.11/tree-sitter-sql-v0.3.11.tar.gz
  tar -xzf .sql-dl/sql.tar.gz -C .sql-dl
  rm -f .sql-dl/sql.tar.gz
  mv .sql-dl tree-sitter-sql
fi

echo "done"
