(import (tuna) (test) (test-user) (test-runner) (hooks) (tables) (keys) (commands) (buffers) (document) (views)
        (layout) (files) (modes) (prog) (syntax) (kill-ring) (editing) (ask) (minibuffer) (completion)
        (completion-list) (completion-popup) (layout-float) (help) (file-picker) (browse-url) (chez-scheme)
        (chez-scheme-completion) (dired) (shell-commands) (actions) (actions-test acting))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(define (plugin-source name)
  (string-append (path-parent (car (command-line))) "/plugins/" name "/src/" name ".sls"))

(define (scheme-buffer name text)
  (let ([b (actions-test/acting:show! (buffers:make name text))])
    (modes:set-major-mode chez-scheme:mode b)
    b))

(define (prompts count)
  (test-user:press! "C-.")
  (let loop ([n count] [seen '()])
    (if (= n 0)
        (begin
          (check-equal? '(quit) (actions-test/acting:press! "C-g"))
          (reverse seen))
        (let ([p (actions-test/acting:action-prompt)])
          (test-user:press! "C-.")
          (loop (- n 1) (cons p seen))))))

;; Highlighting finds a buffer's scope on a job, and a name is read in
;; that scope.
(define (with-names b)
  (test-runner:wait-until (lambda () (not (eq? (chez-scheme:names b) (chez-scheme:repl-names))))))

(test "outside a read, C-. in a buffer of no language acts on the identifier at point, and w copies it"
  (let ([notes (actions-test/acting:show! (buffers:make "notes" "x = user_id + 1\n"))])
    (actions-test/acting:at! notes "user_id" 2)
    (test-user:press! "C-.")
    (check-equal? "Act on user_id: " (actions-test/acting:action-prompt))
    (check-equal? '() (actions-test/acting:press! "w"))
    (check-equal? '("user_id") (kill-ring:current))))

(test "a Tuna name is a name wherever it is written, and h describes it by its export"
  (let ([bs (actions-test/acting:show! (files:visit (plugin-source "buffers")))])
    (with-names bs)
    (actions-test/acting:at! bs "(define (insert! " 11)
    (test-user:press! "C-.")
    (check-equal? "Act on insert!: " (actions-test/acting:action-prompt))
    (check-equal? '() (actions-test/acting:press! "h"))
    (check-equal? "buffers:insert!" (actions-test/acting:help-title)))
  (let ([hs (actions-test/acting:show! (files:visit (plugin-source "help")))])
    (with-names hs)
    (actions-test/acting:at! hs "(define (%read-name)" 12)
    (test-user:press! "C-.")
    (check-equal? "Act on %read-name: " (actions-test/acting:action-prompt))
    (check-equal? '() (actions-test/acting:press! "h"))
    (check-equal? "help:%read-name" (actions-test/acting:help-title)))
  (let ([prose (actions-test/acting:show! (buffers:make "prose" "see buffers:insert! here\n"))])
    (actions-test/acting:at! prose "buffers:insert!" 3)
    (test-user:press! "C-.")
    (check-equal? '() (actions-test/acting:press! "h"))
    (check-equal? "buffers:insert!" (actions-test/acting:help-title))))

(test "a local is an identifier, with no h"
  (let ([bs (actions-test/acting:show! (files:visit (plugin-source "buffers")))])
    (actions-test/acting:at! bs "(let ([frozen" 8)
    (test-user:press! "C-.")
    (check-equal? "Act on frozen: " (actions-test/acting:action-prompt))
    (check-equal? '("h is not an action") (actions-test/acting:press! "h"))))

(test "in another language's program a symbol is that language's, with no h"
  (let ([py (actions-test/acting:show! (buffers:make "app.py" "print(list(x))\n"))])
    (modes:set-major-mode prog:mode py)
    (actions-test/acting:at! py "list" 1)
    (test-user:press! "C-.")
    (check-equal? "Act on list: " (actions-test/acting:action-prompt))
    (check-equal? '("h is not an action") (actions-test/acting:press! "h"))))

(test "a popup row is the first target, valued as its source values it, and an action on it ends its session"
  (let ([scratch (scheme-buffer "s.ss" "(vector-ma")])
    (views:set-point! (actions-test/acting:view) (document:length (buffers:document scratch)))
    (test-user:press! "C-M-i")
    (actions-test/acting:settled)
    (check-equal? '("vector-map") (actions-test/acting:texts))
    (completion:select! (actions-test/acting:session) (car (actions-test/acting:matches (actions-test/acting:session))))
    (test-user:press! "C-.")
    (check-equal? "Act on vector-map: " (actions-test/acting:action-prompt))
    (check-equal? '() (actions-test/acting:press! "h"))
    (check-equal? "vector-map" (actions-test/acting:help-title))
    (check-equal? #f (actions-test/acting:session))
    (test-user:press! "C-M-i")
    (actions-test/acting:settled)
    (completion:select! (actions-test/acting:session) (car (actions-test/acting:matches (actions-test/acting:session))))
    (test-user:press! "C-;")
    (check-equal? "(vector-map" (actions-test/acting:text scratch))
    (check-equal? #f (actions-test/acting:session))))

(test "u, l and c change the case of a region"
  (let ([words (actions-test/acting:show! (buffers:make "case" "hello world\n"))])
    (actions-test/acting:at! words "hello" 0)
    (views:set-mark! (actions-test/acting:view) (actions-test/acting:position-of words " world" 0))
    (test-user:press! "C-. u")
    (check-equal? "HELLO world\n" (actions-test/acting:text words))
    (actions-test/acting:at! words "HELLO" 0)
    (views:set-mark! (actions-test/acting:view) (actions-test/acting:position-of words " world" 0))
    (test-user:press! "C-. l")
    (check-equal? "hello world\n" (actions-test/acting:text words))
    (actions-test/acting:at! words "hello" 0)
    (views:set-mark! (actions-test/acting:view) (actions-test/acting:position-of words " world" 0))
    (test-user:press! "C-. c")
    (check-equal? "Hello world\n" (actions-test/acting:text words))
    (views:set-mark! (actions-test/acting:view) #f)))

(define code (scheme-buffer "put.ss" "(import (buffers))\n(define (put b piece)\n  (buffers:insert! b piece))\n"))

(test "C-. again moves to the next target, round: the identifier, the list holding it, the top-level form; a count moves that many"
  (actions-test/acting:show! code)
  (actions-test/acting:at! code "! b " 2)
  (test-user:press! "C-.")
  (check-equal? "Act on b: " (actions-test/acting:action-prompt))
  (test-user:press! "C-.")
  (check-equal? "Act on (buffers:insert! b piece): " (actions-test/acting:action-prompt))
  (test-user:press! "C-.")
  (check-equal? "Act on (define (put b piece)\n  (buffers:insert! b piece)): " (actions-test/acting:action-prompt))
  (test-user:press! "C-.")
  (check-equal? "Act on b: " (actions-test/acting:action-prompt))
  (test-user:press! "2 C-.")
  (check-equal? "Act on (define (put b piece)\n  (buffers:insert! b piece)): " (actions-test/acting:action-prompt))
  (check-equal? '() (actions-test/acting:press! "w"))
  (check-equal? '("(define (put b piece)\n  (buffers:insert! b piece))") (kill-ring:current)))

(test "a numeric argument before C-. starts that many targets on"
  (test-user:press! "C-u 1 C-.")
  (check-equal? "Act on (buffers:insert! b piece): " (actions-test/acting:action-prompt))
  (check-equal? '(quit) (actions-test/acting:press! "C-g")))

(define noted #f)

(commands:define-command (note [text (ask:line "Note: ")]) "Notes TEXT." (set! noted text))

(test "C-; runs the default action: the category's entry in actions:default-actions, the target a count further on, else none"
  (tables:set! actions:default-actions completion:expression-category note)
  (test-user:press! "C-u 1 C-;")
  (check-equal? "(buffers:insert! b piece)" noted)
  (actions-test/acting:at! code "(buffers))" 0)
  (test-user:press! "C-;")
  (check-equal? "(buffers)" noted)
  (tables:remove! actions:default-actions completion:expression-category)
  (check-equal? '("No default action for (buffers)") (actions-test/acting:press! "C-;")))

(define (cursor-places)
  (map (lambda (c) (list (views:cursor-point c) (views:cursor-mark c))) (views:cursors (actions-test/acting:view))))

(test "k kills an expression as the region of the view's only cursor, and the view's cursors come back where they were"
  (actions-test/acting:at! code "(buffers:insert!" 0)
  (views:add-cursor! (actions-test/acting:view) (document:position (buffers:document code) 18 (document:unit characters)))
  (let ([before (cursor-places)])
    (test-user:press! "C-.")
    (check-equal? "Act on (buffers:insert! b piece): " (actions-test/acting:action-prompt))
    (check-equal? '() (actions-test/acting:press! "k"))
    (check-equal? "(import (buffers))\n(define (put b piece)\n  )\n" (actions-test/acting:text code))
    (check-equal? before (cursor-places))
    (check-equal? "(buffers:insert! b piece)" (kill-ring:text (kill-ring:current)))))

(test "a region command that leaves the view on another buffer gets no cursors put back there"
  (let ([elsewhere (buffers:make "elsewhere" "one two three\n")])
    (commands:define-command (leave) "Shows another buffer." (views:set-buffer! (views:current) elsewhere))
    (tables:set! commands:region-commands leave #t)
    (keys:bind! completion:expression-action-keymap "e" leave)
    (let ([left (scheme-buffer "left.ss" "(f (g x))\n")])
      (actions-test/acting:at! left "(g x)" 0)
      (views:add-cursor! (actions-test/acting:view) (document:position (buffers:document left) 8 (document:unit characters)))
      (test-user:press! "C-. e")
      (check-equal? elsewhere (views:buffer (actions-test/acting:view)))
      (check-equal? '((1 #f)) (cursor-places)))
    (keys:unbind! completion:expression-action-keymap "e")
    (actions-test/acting:show! code)))

(commands:define-command (pause-then-kill [line (ask:line "Then: ")]) "Kills the region after asking." (editing:kill-region))

(tables:set! commands:region-commands pause-then-kill #t)

(test "the cursors come back moved by edits made while a region command pauses, more than the edit log keeps"
  (buffers:insert! code (actions-test/acting:position-of code "  )" 2) "(list 1 2)")
  (keys:bind! completion:expression-action-keymap "p" pause-then-kill)
  (actions-test/acting:at! code "(list 1 2)" 0)
  (let ([before (cursor-places)])
    (test-user:press! "C-. p")
    (check-equal? "Then: \n" (actions-test/acting:prompt-text))
    (do ([k 0 (+ k 1)]) ((= k 1001)) (buffers:insert! code (actions-test/acting:position-of code "import" 0) "x"))
    (check-equal? '() (actions-test/acting:press! "RET"))
    (let ([t (actions-test/acting:text code)])
      (check-equal? 1046 (string-length t))
      (check-equal? "(define (put b piece)\n  )\n" (substring t (- (string-length t) 26) (string-length t))))
    (check-equal? (map (lambda (p) (map (lambda (x) (and x (+ x 1001))) p)) before) (cursor-places))))

(test "M-| asks its line before it reads the region, finds the target there, and gives the view its region back"
  (keys:bind! completion:expression-action-keymap "|" shell-commands:shell-command-on-region)
  (let ([words (scheme-buffer "words.ss" "(one two) three\n")])
    (actions-test/acting:at! words "(one" 0)
    (views:set-mark! (actions-test/acting:view) (document:position (buffers:document words) 15 (document:unit characters)))
    (test-user:press! "C-.")
    (check-equal? "Act on (one two) three: " (actions-test/acting:action-prompt))
    (test-user:press! "C-.")
    (check-equal? "Act on (one two): " (actions-test/acting:action-prompt))
    (test-user:press! "|")
    (check-equal? "Shell command on region: \n" (actions-test/acting:prompt-text))
    (test-user:type! "tr a-z A-Z")
    (test-user:press! "RET")
    (test-runner:wait-until
      (lambda () (let ([b (buffers:find "*Shell Command Output*")]) (and b (> (string-length (actions-test/acting:text b)) 0)))))
    (check-equal? "(ONE TWO)" (actions-test/acting:text (buffers:find "*Shell Command Output*")))
    (check-equal? '(1 16) (list (views:point (actions-test/acting:view)) (views:mark (actions-test/acting:view))))))

(define (test-target view) (completion:make-target 'test 'tested "tested" #f #f))

(define (same-bounds view)
  (let-values ([(start end) (syntax:symbol-bounds (views:buffer view) (views:point view))])
    (and start (completion:make-target 'test 'same "same" start end))))

(define paths (buffers:make "paths" "see src/notes.txt and https://tuna.example/a\n"))

(test "the finders' targets come in depth order, and one whose bounds an earlier target has is dropped"
  (hooks:add! completion:target-finders test-target -20)
  (hooks:add! completion:target-finders same-bounds 25)
  (actions-test/acting:show! paths)
  (actions-test/acting:at! paths "notes" 0)
  (check-equal? '("Act on tested: " "Act on ~/src/notes.txt: " "Act on src/notes: " "Act on tested: ") (prompts 4))
  (actions-test/acting:at! paths "tuna.example" 0)
  (check-equal? '("Act on https://tuna.example/a: " "Act on tested: " "Act on //tuna: ") (prompts 3))
  (hooks:remove! completion:target-finders test-target)
  (hooks:remove! completion:target-finders same-bounds))

(test "the region hides no later target: a region over exactly a list keeps the list"
  (let ([list-only (scheme-buffer "l.ss" "(f (g x))\n")])
    (views:set-point! (actions-test/acting:view) (actions-test/acting:position-of list-only "(g x)" 0))
    (views:set-mark! (actions-test/acting:view) (actions-test/acting:position-of list-only "(g x)" 5))
    (check-equal? '("Act on (g x): " "Act on (g x): " "Act on (f (g x)): ") (prompts 3))))

(test "a file name holding a slash is a path joined to the buffer's folder, and f visits it"
  (mkdir (home-file "src"))
  (call-with-output-file (home-file "src/notes.txt") (lambda (p) (put-string p "notes\n")))
  (actions-test/acting:show! paths)
  (actions-test/acting:at! paths "notes" 0)
  (test-user:press! "C-.")
  (check-equal? '() (actions-test/acting:press! "f"))
  (actions-test/acting:wait-for-file)
  (check-equal? (home-file "src/notes.txt") (files:path (views:buffer (actions-test/acting:view)))))

(test "C-; on a web address opens it"
  (let* ([opened '()] [note-open (lambda (open url client) (set! opened (cons url opened)))])
    (advice-add! browse-url:open note-open)
    (actions-test/acting:show! paths)
    (actions-test/acting:at! paths "tuna.example" 0)
    (test-user:press! "C-;")
    (check-equal? '("https://tuna.example/a") opened)
    (advice-remove! browse-url:open note-open)))

(test "a region command on the region leaves its own questions to the user"
  (actions-test/acting:show! paths)
  (actions-test/acting:at! paths "tuna.example" 0)
  (views:set-mark! (actions-test/acting:view) (actions-test/acting:position-of paths "see" 0))
  (test-user:press! "C-.")
  (check-equal? "Act on see src/notes.txt and https://: " (actions-test/acting:action-prompt))
  (test-user:press! "|")
  (check-equal? "Shell command on region: \n" (actions-test/acting:prompt-text))
  (check-equal? '(quit) (actions-test/acting:press! "C-g"))
  (views:set-mark! (actions-test/acting:view) #f))

(tables:define-table test-keymap)

(test "a region command on a target with no place in a buffer runs on the selected view's own region and asks its questions"
  (tables:set! completion:action-keymaps 'test (list test-keymap))
  (keys:bind! test-keymap "p" pause-then-kill)
  (let ([r (actions-test/acting:start!
             (lambda () (completion:read "Pick: " (list (completion:source (candidates (vector "one")) (category 'test))))))])
    (test-user:press! "C-.")
    (check-equal? '() (actions-test/acting:press! "p"))
    (check-equal? 'quit (actions-test/acting:result r))
    (check-equal? "Then: \n" (actions-test/acting:prompt-text))
    (check-equal? '(quit) (actions-test/acting:press! "C-g"))))

(test "the commands that act on the region when there is one are marked, so as actions they act on the target: d duplicates the list in place"
  (check-equal? '(#t #t #t #t #t #t #t #t #t #t #t)
    (map (lambda (c) (tables:ref commands:region-commands c #f))
         (list editing:duplicate-dwim editing:move-line-down editing:move-line-up editing:delete-trailing-whitespace
               editing:delete-backward-char editing:delete-forward-char completion:kill-ring-save
               dired:mark dired:unmark dired:flag-deletion dired:toggle-marks)))
  (keys:bind! completion:expression-action-keymap "d" editing:duplicate-dwim)
  (let ([dup (scheme-buffer "dup.ss" "(define (f b)\n  (g (bar b)))\n")])
    (actions-test/acting:at! dup "bar b" 4)
    (let ([before (views:point (actions-test/acting:view))])
      (test-user:press! "C-. C-.")
      (check-equal? "Act on (bar b): " (actions-test/acting:action-prompt))
      (check-equal? '() (actions-test/acting:press! "d"))
      (check-equal? "(define (f b)\n  (g (bar b)(bar b)))\n" (actions-test/acting:text dup))
      (check-equal? before (views:point (actions-test/acting:view))))))

(test "a list holding a line that starts with a bracket in column 0 is one expression"
  (let ([column-0 (scheme-buffer "c0.ss" "(define (outer)\n  (let ()\n(define x 1)\nx))\n")])
    (actions-test/acting:at! column-0 "x))" 2)
    (test-user:press! "C-.")
    (check-equal? "Act on (let ()\n(define x 1)\nx): " (actions-test/acting:action-prompt))
    (check-equal? '(quit) (actions-test/acting:press! "C-g"))))

(test "with no lexer, nothing is an expression or a form"
  (let ([plain (actions-test/acting:show! (buffers:make "plain" "(f (g x))\n"))])
    (actions-test/acting:at! plain "x" 0)
    (check-equal? '("Act on x: " "Act on x: ") (prompts 2))))

(test "a listing's line is its file"
  (mkdir (home-file "listed"))
  (call-with-output-file (home-file "listed/a.txt") (lambda (p) (put-string p "listed\n")))
  (let ([listing (actions-test/acting:show! (dired:visit (home-file "listed")))])
    (test-runner:wait-until
      (lambda ()
        (let ([t (actions-test/acting:text listing)])
          (and (> (string-length t) 5) (string=? "a.txt" (substring t (- (string-length t) 6) (- (string-length t) 1)))))))
    (actions-test/acting:at! listing "a.txt" 0)
    (test-user:press! "C-.")
    (check-equal? "Act on ~/listed/a.txt: " (actions-test/acting:action-prompt))
    (check-equal? '() (actions-test/acting:press! "f"))
    (actions-test/acting:wait-for-file)
    (check-equal? "listed\n" (actions-test/acting:text (views:buffer (actions-test/acting:view))))))

(test "actions imports no plugin whose targets it offers: unloading dired leaves it on"
  (let ([old (module-owner '(dired))] [actions (module-owner '(actions))])
    (unload-owner! old)
    (check-equal? '(#t #f) (list (owner-live? actions) (owner-live? old)))))
