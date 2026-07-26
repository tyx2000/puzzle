; Supplemental ECMAScript highlights for tree-sitter-typescript
; (the repo query only covers types/keywords).

(comment) @comment

(string) @string
(template_string) @string
(regex) @string.special

(number) @number
[ (true) (false) ] @constant.builtin
(null) @constant.builtin

(property_identifier) @property

(call_expression
  function: (identifier) @function)
(call_expression
  function: (member_expression
    property: (property_identifier) @function.method))
(function_declaration
  name: (identifier) @function)
(method_definition
  name: (property_identifier) @function.method)

[
  "if" "else" "for" "while" "do" "return" "break" "continue" "switch" "case"
  "default" "throw" "try" "catch" "finally" "new" "delete" "typeof" "instanceof"
  "in" "of" "void" "class" "extends" "const" "let" "var" "function" "async"
  "await" "yield" "import" "export" "from" "as" "static" "get" "set"
] @keyword
