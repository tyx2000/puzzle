; Highlights for .gitignore — tree-sitter-gitignore ships no query upstream.
; Node names come from its node-types.json.

(comment) @comment

; Leading "!" re-includes a previously excluded path; worth standing out.
(negation) @keyword

; Glob metacharacters, so the pattern's shape reads at a glance.
(wildcard_char_single) @operator
(wildcard_chars) @operator
(wildcard_chars_allow_slash) @operator

(directory_separator) @punctuation.delimiter
(directory_separator_escaped) @escape
(pattern_char_escaped) @escape
(bracket_char_escaped) @escape

; Character classes: [abc], [a-z], [!abc]
(bracket_expr) @string.special
(bracket_negation) @keyword
(bracket_range) @operator
(bracket_char_class) @type
