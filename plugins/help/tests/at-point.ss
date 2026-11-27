(import (tuna) (test) (test-runner) (test-user) (buffers) (document) (views) (layout) (files) (minibuffer) (completion)
        (completion-annotations) (chez-scheme) (help) (help-test) (chez-scheme-test scheme-buffers))

(chez-scheme-test/scheme-buffers:write-lib-modules!)
(load-module! '(zeppo))

(define (view) (layout:selected-view))

(define (cancels-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons (if (cancelled? c) 'cancelled c) reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    reported))

(define (quit!) (check-equal? '(cancelled) (cancels-during (lambda () (test-user:press! "C-g")))))

(define (default-of keys)
  (test-user:press! keys)
  (let ([default (minibuffer:prompt-default (minibuffer:current-prompt))])
    (quit!)
    default))

(define (show! b offset)
  (views:set-buffer! (view) b)
  (views:set-point! (view) (document:position (buffers:document b) offset (document:unit characters))))

(define (offset-after b text shift)
  (let* ([all (document:text (buffers:document b))] [n (string-length text)])
    (let loop ([i 0])
      (if (string=? (substring all i (+ i n)) text) (+ i shift) (loop (+ i 1))))))

;; Highlighting finds a buffer's scope in a job, so a test waits until
;; the buffer's names have come.
(define (wait-for-names b)
  (test-runner:wait-until (lambda () (not (eq? (chez-scheme:names b) (chez-scheme:repl-names))))))

(define plugins (string-append (path-parent (car (command-line))) "/plugins"))

(test-user:show! "|")

(test "in a module's own file, C-h f offers the export of the name at point, as the file spells it"
  (let ([b (files:visit (string-append plugins "/buffers/src/buffers.sls"))])
    (wait-for-names b)
    (show! b (offset-after b "(define (insert! " 11))
    (check-equal? "buffers:insert!" (default-of "C-h f"))))

(test "in a module's own file, a helper at point is offered too"
  (let ([b (files:visit (string-append (getenv "HOME") "/.config/tuna/lib/zeppo.sls"))])
    (wait-for-names b)
    (show! b (offset-after b "(define (%tune" 11))
    (check-equal? "zeppo:%tune" (default-of "C-h f"))))

(define plain (buffers:make "plain" "(editing:forward-word b) ( editing:forward-word c) buffers:insert!"))

(test "in a plain buffer, an argument offers the call's first symbol, to C-h x the command it names"
  (show! plain 22)
  (check-equal? '("editing:forward-word" "editing:forward-word") (list (default-of "C-h f") (default-of "C-h x"))))

(test "a space after a list's opening bracket makes no call, so nothing is offered"
  (show! plain 48)
  (check-equal? '(#f #f) (list (default-of "C-h f") (default-of "C-h x"))))

(test "a name at point is offered as itself"
  (show! plain 54)
  (check-equal? "buffers:insert!" (default-of "C-h f")))

(test "in prose, a lone double quote above the call hides nothing, as in Emacs"
  (let ([prose (buffers:make "prose" "He said \"hi.\nAnd then\nsee (editing:forward-word b) here\n")])
    (show! prose (offset-after prose "word b" 5))
    (check-equal? '("editing:forward-word" "editing:forward-word") (list (default-of "C-h f") (default-of "C-h x")))))

(define (help-text)
  (apply string-append (map (lambda (line) (string-append line "\n")) (help-test:lines))))

(define (holds? text piece)
  (let ([n (string-length piece)])
    (let loop ([i 0])
      (and (<= (+ i n) (string-length text)) (or (string=? (substring text i (+ i n)) piece) (loop (+ i 1)))))))

(test "Chez's own names are described, and a name two libraries export is described once, as the one Tuna's code resolves"
  (help:describe-name 'car (view))
  (test-user:settle)
  (check-equal? "car" (help-test:title))
  (check (holds? (help-text) "A procedure in (chezscheme)."))
  (help:describe-name 'dynamic-wind (view))
  (test-user:settle)
  (check-equal? "dynamic-wind" (help-test:title))
  (check (holds? (help-text) "(tuna core replaced)")))

(define (minibuffer-session)
  (let ([v (layout:find-view (buffers:find " *Minibuf*"))])
    (and v (views:call-with-view v completion:current-session))))

(define (row text)
  (let* ([s (minibuffer-session)] [ms (completion:session-matches s)])
    (let loop ([k 0])
      (and (< k (completion:matches-count ms))
           (let ([m (completion:matches-ref ms k)])
             (if (equal? text (completion:text s m))
                 (list (completion:text s m) (completion:value s m) (completion:category s m)
                       (map (lambda (c) (if (pair? c) (cdr c) c)) (completion:annotation s m)))
                 (loop (+ k 1))))))))

(test "C-h f offers each name with its kind, as Marginalia annotates a symbol's class; a table is a variable"
  (show! plain 0)
  (test-user:press! "C-h f")
  (test-user:type! "help:key")
  (test-runner:wait-until
    (lambda () (let ([s (minibuffer-session)]) (and s (equal? "help:key" (completion:session-input s)) (not (completion:session-busy? s))))))
  (check-equal? '("help:keymap" help:keymap completion:name-category ("variable")) (row "help:keymap"))
  (quit!))
