; extends

; Emacs's python-ts-mode at its default level colours definitions and
; leaves uses plain. nvim-treesitter colours some uses by their names:
; names in capitals as constants, CamelCase names and builtin type names
; as types, dunder names and Python's builtin constants as builtins, cls
; as a builtin. Here they are uses: variables, after a dot attribute
; uses, and called, calls, as Emacs colours them at its fourth level. The
; patterns after these give definitions, types and builtins their colours
; back.
((identifier) @variable
  (#lua-match? @variable "^[A-Z][A-Z_0-9]*$"))
((identifier) @variable
  (#lua-match? @variable "^[A-Z].*[a-z]"))
((identifier) @variable
  (#lua-match? @variable "^__[a-zA-Z0-9_]*__$"))
((identifier) @variable
  (#any-of? @variable
    "NotImplemented" "Ellipsis" "quit" "exit" "copyright" "credits" "license" "cls"
    "type" "object" "int" "float" "complex" "bool" "list" "tuple" "range" "str"
    "bytes" "bytearray" "memoryview" "set" "frozenset" "dict"))
(attribute attribute: (identifier) @variable.member)
(call function: (identifier) @function.call)
(call function: (attribute attribute: (identifier) @function.method.call))
((call
  function: (identifier) @_isinstance
  arguments: (argument_list (_) (identifier) @variable))
  (#any-of? @_isinstance "isinstance" "issubclass"))
((call function: (identifier) @function.builtin)
  (#any-of? @function.builtin
    "int" "float" "complex" "bool" "list" "tuple" "range" "str" "bytes"
    "bytearray" "memoryview" "set" "frozenset" "dict"
    "abs" "all" "any" "ascii" "bin" "breakpoint" "callable" "chr"
    "classmethod" "compile" "delattr" "dir" "divmod" "enumerate" "eval"
    "exec" "filter" "format" "getattr" "globals" "hasattr" "hash" "help"
    "hex" "id" "input" "isinstance" "issubclass" "iter" "len" "locals"
    "map" "max" "min" "next" "object" "oct" "open" "ord" "pow" "print"
    "property" "repr" "reversed" "round" "setattr" "slice" "sorted"
    "staticmethod" "sum" "super" "type" "vars" "zip" "__import__"))

; Emacs colours imported names as variables, not modules.
(import_statement name: (dotted_name (identifier) @variable))
(aliased_import name: (dotted_name (identifier) @variable) alias: (identifier) @variable)
(import_from_statement module_name: (dotted_name (identifier) @variable))
(import_from_statement module_name: (relative_import (dotted_name (identifier) @variable)))
(future_import_statement "__future__" @none)

; Definitions, from Emacs's definition feature: function, method and class
; names, and plain, typed and default parameters. nvim-treesitter
; captures __init__ and __new__ as @constructor, which is drawn plain with
; calls; Emacs leaves *args and **kwargs, typed or not, typed defaults
; and a lambda's parameters plain.
(function_definition name: (identifier) @function)
(class_definition
  body: (block (function_definition name: (identifier) @function.method)))
(class_definition name: (identifier) @type)
(parameters (identifier) @variable.parameter)
(parameters (typed_parameter (identifier) @variable.parameter))
(parameters (default_parameter name: (identifier) @variable.parameter))
(parameters (list_splat_pattern (identifier) @variable))
(parameters (dictionary_splat_pattern (identifier) @variable))
(parameters (typed_parameter (list_splat_pattern (identifier) @variable)))
(parameters (typed_parameter (dictionary_splat_pattern (identifier) @variable)))
(typed_default_parameter name: (identifier) @variable)
(lambda_parameters (identifier) @variable)
(lambda_parameters (default_parameter name: (identifier) @variable))
(lambda_parameters (list_splat_pattern (identifier) @variable))
(lambda_parameters (dictionary_splat_pattern (identifier) @variable))

; Definitions, from Emacs's assignment feature: nvim-treesitter captures an
; assignment's target as @variable, the capture of a use.
(assignment left: (identifier) @variable.definition)
(assignment left: (attribute attribute: (identifier) @variable.definition))
(augmented_assignment left: (identifier) @variable.definition)
(named_expression name: (identifier) @variable.definition)
(for_statement left: (identifier) @variable.definition)
(pattern_list [(identifier) (list_splat_pattern (identifier))] @variable.definition)
(tuple_pattern [(identifier) (list_splat_pattern (identifier))] @variable.definition)
(list_pattern [(identifier) (list_splat_pattern (identifier))] @variable.definition)
((list_splat_pattern "*" @variable.definition (identifier) @variable.definition) @_splat
  (#has-parent? @_splat pattern_list tuple_pattern list_pattern))

; Emacs colours a first line starting #! as a comment.
((comment) @comment
  (#lua-match? @comment "^#!/"))

; Emacs colours a keyword argument's name as a variable's use.
(keyword_argument name: (identifier) @variable)

; Docstrings are Emacs's: a bare string in a function's or class's body,
; or a module's first statement. nvim-treesitter takes any bare string.
(expression_statement (string) @string)
(function_definition body: (block (expression_statement (string) @string.documentation)))
(class_definition body: (block (expression_statement (string) @string.documentation)))
(module . (comment)* . (expression_statement (string) @string.documentation))

; A string's prefix, such as r or f, is not part of the string's colour.
((string_start) @none
  (#lua-match? @none "^%a+[\"']$")
  (#offset! @none 0 0 0 -1))
((string_start) @none
  (#lua-match? @none "^%a+[\"'][\"'][\"']$")
  (#offset! @none 0 0 0 -3))

; Types, from Emacs's type feature, which overrides the other colours:
; annotations, None in them included, superclasses, class patterns, and
; the type given to isinstance or issubclass.
(type (identifier) @type)
(type (attribute attribute: (identifier) @type))
((identifier) @type
  (#has-ancestor? @type type)
  (#not-has-ancestor? @type attribute))
((attribute attribute: (identifier) @type) @_outermost
  (#has-ancestor? @_outermost type)
  (#not-has-parent? @_outermost attribute))
((none) @type
  (#has-ancestor? @type type))
(class_definition
  superclasses: (argument_list
    [(identifier) @type
     (attribute attribute: (identifier) @type)
     (subscript (identifier) @type)
     (subscript (attribute attribute: (identifier) @type))]))
(class_pattern (dotted_name (identifier) @type .))
((call
  function: (identifier) @_isinstance
  arguments: (argument_list
    .
    (_)
    .
    [(identifier) @type
     (attribute attribute: (identifier) @type)
     (tuple (identifier) @type)
     (tuple (attribute attribute: (identifier) @type))]))
  (#any-of? @_isinstance "isinstance" "issubclass")
  (#lua-match? @type "^_?%u"))
((call
  function: (identifier) @_isinstance
  arguments: (argument_list
    .
    (_)
    .
    [(identifier) @type
     (tuple (identifier) @type)]))
  (#any-of? @_isinstance "isinstance" "issubclass")
  (#any-of? @type
    "int" "float" "complex" "bool" "list" "tuple" "range" "str" "bytes"
    "bytearray" "memoryview" "set" "frozenset" "dict"))

; Emacs colours each name of a decorator as a type, the special attributes
; as builtins, self as a keyword, None elsewhere as a constant, the
; builtin exceptions as types wherever they appear, calls included, and
; leaves an f-string's !r plain.
((identifier) @attribute
  (#has-ancestor? @attribute decorator)
  (#not-has-ancestor? @attribute argument_list))
((attribute attribute: (identifier) @variable.builtin)
  (#any-of? @variable.builtin
    "__annotations__" "__closure__" "__code__" "__defaults__" "__dict__" "__doc__"
    "__globals__" "__kwdefaults__" "__name__" "__module__" "__package__" "__qualname__"
    "__all__"))
((identifier) @keyword
  (#eq? @keyword "self"))
((none) @constant
  (#not-has-ancestor? @constant type))
(type_conversion) @none
((identifier) @type.builtin
  (#any-of? @type.builtin
    "ArithmeticError" "AssertionError" "AttributeError" "BaseException"
    "BufferError" "BytesWarning" "DeprecationWarning" "EOFError"
    "EnvironmentError" "Exception" "FloatingPointError" "FutureWarning"
    "GeneratorExit" "IOError" "ImportError" "ImportWarning"
    "IndentationError" "IndexError" "KeyError" "KeyboardInterrupt"
    "LookupError" "MemoryError" "NameError" "NotImplementedError" "OSError"
    "OverflowError" "PendingDeprecationWarning" "ReferenceError"
    "RuntimeError" "RuntimeWarning" "StopIteration" "SyntaxError"
    "SyntaxWarning" "SystemError" "SystemExit" "TabError" "TypeError"
    "UnboundLocalError" "UnicodeDecodeError" "UnicodeEncodeError"
    "UnicodeError" "UnicodeTranslateError" "UnicodeWarning" "UserWarning"
    "ValueError" "Warning" "ZeroDivisionError" "StandardError"
    "BlockingIOError" "BrokenPipeError" "ChildProcessError"
    "ConnectionAbortedError" "ConnectionError" "ConnectionRefusedError"
    "ConnectionResetError" "FileExistsError" "FileNotFoundError"
    "InterruptedError" "IsADirectoryError" "NotADirectoryError"
    "PermissionError" "ProcessLookupError" "RecursionError"
    "ResourceWarning" "StopAsyncIteration" "TimeoutError" "ExceptionGroup"
    "VMSError" "WindowsError"))
