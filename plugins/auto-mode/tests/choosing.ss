(import (tuna) (test) (test-runner) (auto-mode) (modes) (prog) (python) (files) (buffers) (document) (hooks) (options) (tables) (buffers-test)
        (modes-test text) (modes-test fill) (auto-mode-test modes))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(define (write-file! name text)
  (call-with-output-file (home-file name) (lambda (p) (put-string p text)) 'replace))

(define (local option b) (buffers:with-buffer b (option)))

(define archive auto-mode-test/modes:archive)
(define make auto-mode-test/modes:make)
(define html auto-mode-test/modes:html)
(define text modes-test/text:mode)

(tables:set! auto-mode:file-names "tar.gz" archive)
(tables:set! auto-mode:file-names "zip" archive)
(tables:set! auto-mode:interpreters "guile" text)

(define b (buffers:make "b" "x"))

(options:set! auto-mode:default-mode text)

(test "by the program a #! line names: the last part of its path; for env its first argument that neither starts with - nor holds =; as written, then without a version"
  (check-equal? (list python:mode python:mode python:mode text #f #f #f #f #f)
                (map (lambda (line) (auto-mode:by-interpreter (buffers:make (buffers:free-name "script") line) "script"))
                     '("#!/usr/bin/python\nprint(1)\n" "#!/usr/bin/env python3\n" "#! /usr/bin/env -S VAR=1 python3.12 -u\n"
                       "#!/usr/local/bin/guile-3.0 -s\n" "#!/usr/bin/env\n" "#!/bin/sh\n" "# python\n" "" "#!"))))

(test "a #! line is read up to 256 characters"
  (check-equal? python:mode
                (auto-mode:by-interpreter (buffers:make "long" (string-append "#!" (make-string 240 #\/) "python\n")) "long"))
  (check-equal? #f
                (auto-mode:by-interpreter (buffers:make "longer" (string-append "#!" (make-string 260 #\/) "python\n")) "longer")))

(test "by file name: the last part without a trailing ~, whole, then from each dot on, longest first; as written, then in lowercase"
  (tables:set! auto-mode:file-names "Makefile" make)
  (tables:set! auto-mode:file-names "gz" text)
  (check-equal? (list make #f archive text archive python:mode #f python:mode #f python:mode python:mode #f #f)
                (map (lambda (name) (auto-mode:by-file-name b name))
                     '("/src/Makefile" "/src/makefile" "/x/a.tar.gz" "/x/a.gz" "/x/A.TAR.GZ" "/x/a.py~" "/x/a.py~~" "a.PY"
                       "/x.py/readme" "/x/SConstruct" "/x/.py" "/x/a.unknown" "")))
  (tables:remove! auto-mode:file-names "Makefile")
  (tables:remove! auto-mode:file-names "gz"))

(test "a procedure found is called with the buffer and the name without its ~, and its result is the result, #f included"
  (let* ([seen '()] [looked (lambda (buffer name) (set! seen (cons (list buffer name) seen)) #f)])
    (tables:set! auto-mode:file-names "bak" looked)
    (check-equal? #f (auto-mode:by-file-name b "/x/a.py.bak~"))
    (check-equal? (list (list b "/x/a.py.bak")) seen)
    (check-equal? text (auto-mode:choose b "/x/a.py.bak"))
    (tables:remove! auto-mode:file-names "bak")))

(test "choosing calls the choosers by depth, then takes the default mode, read in the buffer"
  (check-equal? text (auto-mode:choose b "/x/a.nothing"))
  (buffers:with-buffer b (options:set-local! auto-mode:default-mode prog:mode))
  (check-equal? prog:mode (auto-mode:choose b "/x/a.nothing"))
  (buffers:with-buffer b (options:unset-local! auto-mode:default-mode)))

(test "without a name, choosing uses the path of the file the buffer visits, or else its name"
  (write-file! "named.py" "1\n")
  (check-equal? python:mode (auto-mode:choose (files:visit (home-file "named.py"))))
  (check-equal? python:mode (auto-mode:choose (buffers:make "plain.py" "1\n")))
  (check-equal? text (auto-mode:choose (buffers:make "plain" "1\n"))))

(test "the #! line wins over the file name, since its chooser comes first; without it the name decides"
  (tables:set! auto-mode:file-names "Makefile" make)
  (let ([script (buffers:make "plain-script" "#!/usr/bin/env python\n")] [mover (make-owner '(mover))])
    (check-equal? (list python:mode python:mode) (list (auto-mode:choose script "Makefile") (auto-mode:choose script)))
    (call-as-owner mover (lambda () (hooks:remove! auto-mode:choosers auto-mode:by-interpreter)))
    (check-equal? make (auto-mode:choose script "Makefile"))
    (unload-owner! mover)
    (check-equal? python:mode (auto-mode:choose script "Makefile")))
  (tables:remove! auto-mode:file-names "Makefile"))

(test "the public entries check their arguments"
  (check-raises (buffers-test:raised? 'auto-mode:choose "not a buffer") (auto-mode:choose "b"))
  (check-raises (buffers-test:raised? 'auto-mode:choose "not a string") (auto-mode:choose b 'name))
  (check-raises (buffers-test:raised? 'auto-mode:by-file-name "not a string") (auto-mode:by-file-name b 5))
  (check-raises (buffers-test:raised? 'auto-mode:by-interpreter "not a buffer") (auto-mode:by-interpreter 'b "x"))
  (check-raises (buffers-test:raised? 'auto-mode:by-interpreter "not a string") (auto-mode:by-interpreter b 5))
  (check-raises (buffers-test:raised? 'auto-mode:normal-mode "not a buffer") (auto-mode:normal-mode "b")))

(test "a chooser that raises makes the visit's choice raise, reported; the visit goes on and the buffer keeps modes:fundamental"
  (let ([broken (lambda (buffer name) (car '()))])
    (hooks:add! auto-mode:choosers broken -100)
    (write-file! "one.py" "1\n")
    (let ([one #f])
      (check-equal? '(car) (map condition-who (test-runner:reports-during (lambda () (set! one (files:visit (home-file "one.py")))))))
      (check-equal? modes:fundamental (modes:major-mode one))
      (hooks:remove! auto-mode:choosers broken)
      (auto-mode:normal-mode one)
      (check-equal? python:mode (modes:major-mode one)))))

(test "normal-mode chooses again; run by a key, its buffer is the current one"
  (write-file! "three.py" "3\n")
  (let ([three (files:visit (home-file "three.py"))])
    (modes:set-major-mode modes:fundamental three)
    (buffers:with-buffer three (commands:run auto-mode:normal-mode))
    (check-equal? python:mode (modes:major-mode three))))

(test "the visit's entry runs before entries at the default depth, so their local values stay; a revert keeps the mode and them"
  (let ([forty (lambda (b) (options:set-local! modes-test/fill:column 40))])
    (hooks:add! files:after-visit forty)
    (write-file! "two.py" "2\n")
    (let ([two (files:visit (home-file "two.py"))])
      (check-equal? (list python:mode 40) (list (modes:major-mode two) (local modes-test/fill:column two)))
      (buffers:with-buffer two (options:set-local! modes-test/fill:column 41))
      (write-file! "two.py" "22\n")
      (files:revert-from-file two)
      (check-equal? (list python:mode 41 "22\n")
                    (list (modes:major-mode two) (local modes-test/fill:column two) (document:text (buffers:document two)))))
    (hooks:remove! files:after-visit forty)))

(test "a temporary visit sets the mode with its hooks delayed, and a later visit completes it, running after-visit and the hooks once in the same buffer"
  (let* ([visited '()] [hooked '()] [previewed '()]
         [note-visit (lambda (b) (set! visited (cons b visited)))]
         [note-hook (lambda () (set! hooked (cons (buffers:current) hooked)))]
         [note-preview (lambda (b) (set! previewed (cons (list b (modes:major-mode b)) previewed)))])
    (hooks:add! files:after-visit note-visit)
    (hooks:add! python:mode-hook note-hook)
    (hooks:add! modes:delayed-mode-changed note-preview)
    (write-file! "four.py" "4\n")
    (let ([four (files:visit-temporarily (home-file "four.py"))])
      (check-equal? (list python:mode #t #t '() '() (list (list four python:mode)))
                    (list (modes:major-mode four) (modes:hooks-delayed? four) (files:temporary? four) visited hooked previewed))
      (check (eq? four (files:visit-temporarily (home-file "four.py"))))
      (check (eq? four (files:visit (home-file "four.py"))))
      (check-equal? (list python:mode #f #f (list four) (list four))
                    (list (modes:major-mode four) (modes:hooks-delayed? four) (files:temporary? four) visited hooked))
      (files:visit (home-file "four.py"))
      (check-equal? (list (list four) (list four)) (list visited hooked)))
    (hooks:remove! files:after-visit note-visit)
    (hooks:remove! python:mode-hook note-hook)
    (hooks:remove! modes:delayed-mode-changed note-preview)))
