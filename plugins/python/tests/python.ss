(import (tuna) (test) (test-user) (python) (prog) (modes) (auto-mode) (syntax) (buffers) (layout) (keys) (tables) (editing))

(test "python:mode derives from prog:mode, with its keymap, hook, lighter Python and language python"
  (check-equal? (list python:mode prog:mode) (modes:ancestry python:mode))
  (check (eq? python:keymap (tables:ref modes:keymaps python:mode #f)))
  (check (eq? python:mode-hook (tables:ref modes:hooks python:mode #f)))
  (check-equal? "Python" (modes:lighter python:mode))
  (check-equal? "python" (modes:language python:mode)))

(test "python:keymap is empty"
  (check-equal? '() (keys:bindings python:keymap)))

(test "the plugin chooses the mode for .py, .pyi and .pyw files, SConstruct and SConscript"
  (let ([b (buffers:make "n" "")])
    (check-equal? (list python:mode python:mode python:mode python:mode python:mode #f)
                  (map (lambda (name) (auto-mode:by-file-name b name))
                       '("/x/a.py" "/x/a.pyi" "/x/a.pyw" "/x/SConstruct" "/x/SConscript" "/x/a.pyc")))))

(test "the plugin chooses the mode for a #! line naming python, python3 or python3.12"
  (check-equal? (list python:mode python:mode python:mode)
                (map (lambda (line) (auto-mode:by-interpreter (buffers:make (buffers:free-name "script") line) "script"))
                     '("#!/usr/bin/python\n" "#!/usr/bin/env python3\n" "#!/usr/bin/python3.12\n"))))

(test "_ is a symbol character and no other ASCII character but letters and digits is part of a word or a symbol"
  (check-equal? '("" "_") (list (syntax:mode-word-characters python:mode) (syntax:mode-symbol-characters python:mode)))
  (let ([code (buffers:make "code.py" "total=x+y-z total_ordering $a %b")])
    (modes:set-major-mode python:mode code)
    (check-equal? '((7 8) (13 27) (29 30) (32 33))
                  (map (lambda (position) (call-with-values (lambda () (syntax:symbol-bounds code position)) list)) '(7 16 29 32)))))

(test "M-f stops at the _ of total_ordering"
  (test-user:show! "|total_ordering")
  (modes:set-major-mode python:mode (buffers:find "*test*"))
  (test-user:press! "M-f")
  (check-equal? "total|_ordering" (test-user:text)))
