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

echo "done"
