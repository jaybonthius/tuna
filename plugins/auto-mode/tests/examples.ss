(import (tuna) (test) (auto-mode) (modes) (python) (files) (buffers) (document) (hooks) (tables) (modes-test text)
        (auto-mode-test modes))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(define (write-file! name text)
  (call-with-output-file (home-file name) (lambda (p) (put-string p text)) 'replace))

(define notes (buffers:make "notes" "x"))

(tables:set! auto-mode:file-names "tar.gz" auto-mode-test/modes:archive)

(test "a rule by content goes above the file name, reading from position 0"
  (define (python-by-content buffer name)
    (let* ([doc (buffers:document buffer)]
           [start (document:text doc 0 (min 7 (document:length doc)))])
      (and (string=? start "import") python:mode)))
  (hooks:add! auto-mode:choosers python-by-content 50)
  (write-file! "setup-tool" "import os\n")
  (check-equal? python:mode (modes:major-mode (files:visit (home-file "setup-tool"))))
  (hooks:remove! auto-mode:choosers python-by-content))

(test "the documented file-name entries: an extension, a whole name, and a procedure for a template's host"
  (define (template-host buffer name)
    (auto-mode:by-file-name buffer (substring name 0 (- (string-length name) 3))))
  (check-equal? auto-mode-test/modes:archive (auto-mode:by-file-name notes "/tmp/backup.tar.gz"))
  (tables:set! auto-mode:file-names "pyi" python:mode)
  (tables:set! auto-mode:file-names "Makefile" auto-mode-test/modes:make)
  (tables:set! auto-mode:file-names "j2" template-host)
  (tables:set! auto-mode:file-names "html" auto-mode-test/modes:html)
  (check-equal? (list auto-mode-test/modes:make auto-mode-test/modes:html #f python:mode)
                (map (lambda (name) (auto-mode:by-file-name notes name))
                     '("~/src/Makefile" "~/site/page.html.j2" "~/site/page.txt.j2" "~/src/types.pyi"))))

(test "the documented interpreter entry"
  (tables:set! auto-mode:interpreters "python" python:mode)
  (write-file! "run" "#!/usr/bin/env python3\nprint(1)\n")
  (check-equal? python:mode (modes:major-mode (files:visit (home-file "run")))))
