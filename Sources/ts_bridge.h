#ifndef PUZZLE_TS_BRIDGE_H
#define PUZZLE_TS_BRIDGE_H

#include <tree_sitter/api.h>

// Grammar entry points (compiled from vendored parser.c files).
const TSLanguage *tree_sitter_json(void);
const TSLanguage *tree_sitter_bash(void);
const TSLanguage *tree_sitter_yaml(void);
const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_markdown(void);
const TSLanguage *tree_sitter_markdown_inline(void);
const TSLanguage *tree_sitter_swift(void);
const TSLanguage *tree_sitter_html(void);
const TSLanguage *tree_sitter_css(void);
const TSLanguage *tree_sitter_python(void);
const TSLanguage *tree_sitter_rust(void);
const TSLanguage *tree_sitter_go(void);
const TSLanguage *tree_sitter_c(void);
const TSLanguage *tree_sitter_toml(void);
const TSLanguage *tree_sitter_xml(void);
const TSLanguage *tree_sitter_sql(void);
const TSLanguage *tree_sitter_dockerfile(void);
const TSLanguage *tree_sitter_gitignore(void);

#endif
