#ifndef PUZZLE_TS_BRIDGE_H
#define PUZZLE_TS_BRIDGE_H

#include <tree_sitter/api.h>

// Grammar entry points (compiled from vendored parser.c files).
const TSLanguage *tree_sitter_json(void);
const TSLanguage *tree_sitter_bash(void);
const TSLanguage *tree_sitter_yaml(void);
const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_markdown(void);
const TSLanguage *tree_sitter_swift(void);
const TSLanguage *tree_sitter_html(void);
const TSLanguage *tree_sitter_css(void);

#endif
