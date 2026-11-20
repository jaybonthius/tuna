#!tuna
(import (buffers) (views) (keys) (commands))

(define-table hooks
  "Maps each major mode to its hook. A major mode is defined while it has an entry here.")

(define-table keymaps
  "Maps a major mode or a minor mode to its keymap.")

(define-table parents
  "Maps a major mode to the mode it derives from.")

(define-table lighters
  "Maps a mode to its lighter, the short name a status line shows for it.")

(define-table languages
  "Maps a major mode to its language, the identifier the Language Server Protocol gives it, such as \"python\".")

(define-table minor-modes
  "Maps each minor mode, a procedure of no arguments that returns true where the mode is on, to its depth, a real number.")

(define-hook major-mode-changed
  "Called with a buffer, current, after modes:set-major-mode has called its mode hooks.")

(define-table fundamental-keymap
  "Keys in buffers whose major mode is modes:fundamental.")

(define-hook fundamental-hook
  "Called in each buffer whose major mode becomes modes:fundamental.")

(define (%saved-modes? v)
  (or (null? v)
      (and (pair? v) (fixnum? (car v)) (list? (cdr v))
           (for-all (lambda (entry) (and (pair? entry) (string? (car entry)) (symbol? (cdr entry))))
                    (cdr v)))))

;; Unload actions also run at exit, so the process id tells a reload, which
;; finds its buffers' modes again by name, from a restart, which starts
;; with none.
(define-saved %saved-modes '() %saved-modes?)

(module %internals
  (check-main-thread check-live-buffer define-major-mode! buffer-modes ancestry-of
   minor-modes-on view-keymaps module-part save-modes! restore-modes!)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define (check-live-buffer who b)
    (unless (and (buffers:buffer? b) (buffers:live? b))
      (assertion-violation who "not a live buffer" b)))

  (define buffer-modes (make-weak-eq-hashtable))

  (define (exported-symbol id)
    (let ([owner (current-owner)])
      (if (member owner '((init) (repl)))
          id
          (string->symbol
            (call-with-string-output-port
              (lambda (p)
                (let loop ([parts owner])
                  (display (car parts) p)
                  (unless (null? (cdr parts))
                    (put-char p #\/)
                    (loop (cdr parts))))
                (put-char p #\:)
                (display id p)))))))

  (define (define-major-mode! id parent lighter keymap hook language)
    (define who 'modes:define-major-mode)
    (unless (or (not parent) (symbol? parent))
      (assertion-violation who "not a mode" parent))
    (unless (or (not lighter) (string? lighter))
      (assertion-violation who "not a string" lighter))
    (unless (table? keymap)
      (assertion-violation who "not a keymap" keymap))
    (unless (hook? hook)
      (assertion-violation who "not a hook" hook))
    (unless (or (not language) (string? language))
      (assertion-violation who "not a string" language))
    (let ([mode (exported-symbol id)])
      (table-set! hooks mode hook)
      (table-set! keymaps mode keymap)
      (if parent (table-set! parents mode parent) (table-remove! parents mode))
      (if lighter (table-set! lighters mode lighter) (table-remove! lighters mode))
      (if language (table-set! languages mode language) (table-remove! languages mode))
      mode))

  ;; A table entry can make parents a cycle.
  (define (ancestry-of mode)
    (let loop ([m mode] [acc '()])
      (if (or (not m) (memq m acc))
          (reverse acc)
          (loop (table-ref parents m #f) (cons m acc)))))

  ;; Entries arrive in the order their keys were first set, so one goes
  ;; after those of its depth already placed.
  (define (insert-by-depth entry placed)
    (if (or (null? placed) (< (cdr entry) (cdar placed)))
        (cons entry placed)
        (cons (car placed) (insert-by-depth entry (cdr placed)))))

  (define (warning-only? c)
    (and (warning? c) (not (serious-condition? c))))

  ;; A minor mode that raises, or a depth that is not a number, is reported
  ;; and skipped, so one plugin's mistake leaves every other mode's keys.
  ;; One handler serves all the entries and is set up again only after a
  ;; failure, since a handler costs more than calling an entry.
  (define (entries-on)
    (let ([on '()] [next (table-entries minor-modes)])
      (let run ()
        (unless (null? next)
          (call/cc
            (lambda (k)
              (with-exception-handler
                (lambda (c)
                  (if (or (quit-condition? c) (warning-only? c))
                      (raise-continuable c)
                      (begin (report c) (k #f))))
                (lambda ()
                  (let loop ()
                    (unless (null? next)
                      (let ([entry (car next)])
                        (set! next (cdr next))
                        (unless (real? (cdr entry))
                          (assertion-violation 'modes:minor-modes "not a real number" (cdr entry)))
                        (when ((car entry))
                          (set! on (insert-by-depth entry on))))
                      (loop)))))))
          (run)))
      on))

  (define (minor-modes-on view)
    (map car (views:call-with-view view entries-on)))

  (define (major-keymaps mode tail)
    (let loop ([m mode] [seen '()])
      (if (or (not m) (memq m seen))
          tail
          (let ([keymap (table-ref keymaps m #f)] [next (table-ref parents m #f)])
            (if keymap
                (cons keymap (loop next (cons m seen)))
                (loop next (cons m seen)))))))

  (define (view-keymaps view)
    (let ([buffer (views:buffer view)])
      (fold-right
        (lambda (entry acc)
          (let ([keymap (table-ref keymaps (car entry) #f)])
            (if keymap (cons keymap acc) acc)))
        (if buffer (major-keymaps (eq-hashtable-ref buffer-modes buffer fundamental) '()) '())
        (views:call-with-view view entries-on))))

  (define (module-part mode)
    (let* ([s (symbol->string mode)] [n (string-length s)])
      (let loop ([i (fx- n 1)])
        (cond
          [(fx< i 0) s]
          [(char=? (string-ref s i) #\:) (substring s 0 i)]
          [else (loop (fx- i 1))]))))

  (define (save-modes!)
    (set-saved! %saved-modes
      (cons (get-process-id)
            (fold-right
              (lambda (b acc)
                (let ([mode (eq-hashtable-ref buffer-modes b #f)])
                  (if mode (cons (cons (buffers:name b) mode) acc) acc)))
              '() (buffers:all)))))

  (define (restore-modes!)
    (let ([saved (%saved-modes)])
      (when (and (pair? saved) (eqv? (car saved) (get-process-id)))
        (for-each
          (lambda (entry)
            (let ([b (buffers:find (car entry))])
              (when b (eq-hashtable-set! buffer-modes b (cdr entry)))))
          (cdr saved))))))

(import %internals)

;; Clause names are compared as symbols, so a module whose own variable is
;; named keymap or hook can still write (keymap keymap).
(define-syntax define-major-mode
  (lambda (x)
    (define (invalid c) (syntax-violation 'modes:define-major-mode "invalid clause" x c))
    (syntax-case x ()
      [(_ id clause ...)
       (identifier? #'id)
       (let loop ([clauses #'(clause ...)] [seen '()] [parent #'#f] [lighter #'#f] [keymap #f] [hook #f] [language #'#f])
         (if (null? clauses)
             (begin
               (unless keymap (syntax-violation 'modes:define-major-mode "a keymap clause is required" x))
               (unless hook (syntax-violation 'modes:define-major-mode "a hook clause is required" x))
               #`(define-public id (define-major-mode! 'id #,parent #,lighter #,keymap #,hook #,language)))
             (let* ([c (car clauses)] [rest (cdr clauses)]
                    [name (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ (invalid c)])]
                    [e (syntax-case c () [(_ e) #'e] [_ (invalid c)])])
               (when (memq name seen)
                 (syntax-violation 'modes:define-major-mode "clause given twice" x c))
               (let ([seen (cons name seen)])
                 (case name
                   [(parent) (loop rest seen e lighter keymap hook language)]
                   [(lighter) (loop rest seen parent e keymap hook language)]
                   [(keymap) (loop rest seen parent lighter e hook language)]
                   [(hook) (loop rest seen parent lighter keymap e language)]
                   [(language) (loop rest seen parent lighter keymap hook e)]
                   [else (invalid c)])))))]
      [_ (syntax-violation 'modes:define-major-mode "expected (modes:define-major-mode id clause ...)" x)])))

(define-major-mode fundamental
  (lighter "Fundamental")
  (keymap fundamental-keymap)
  (hook fundamental-hook))

(define-table special-keymap
  "Keys in buffers that are read, not edited, whose major modes derive from modes:special.")

(define-hook special-hook
  "Called in each buffer whose major mode becomes modes:special or a mode derived from it.")

(define-major-mode special
  (lighter "Special")
  (keymap special-keymap)
  (hook special-hook))

(define (major-mode buffer)
  (check-main-thread 'modes:major-mode)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'modes:major-mode "not a buffer" buffer))
  (eq-hashtable-ref buffer-modes buffer fundamental))

(define (set-major-mode mode buffer)
  (check-main-thread 'modes:set-major-mode)
  (check-live-buffer 'modes:set-major-mode buffer)
  (unless (hook? (table-ref hooks mode #f))
    (assertion-violation 'modes:set-major-mode "not a major mode" mode))
  (buffers:reset-scope! buffer)
  (eq-hashtable-set! buffer-modes buffer mode)
  (eq-hashtable-delete! %delayed buffer)
  (run-mode-hooks buffer)
  (buffers:with-buffer buffer (major-mode-changed buffer)))

(define-hook delayed-mode-changed
  "Called with a buffer, current, after modes:set-major-mode-delaying-hooks has set its mode: the work a mode with delayed hooks allows, such as a highlighter's.")

;; A mode set with its hooks delayed, as for a file a preview opens, still
;; draws, but runs no mode hook, which may start work for the buffer as a
;; language server does, until the hooks run.
(define %delayed (make-weak-eq-hashtable))

(define (set-major-mode-delaying-hooks mode buffer)
  (check-main-thread 'modes:set-major-mode-delaying-hooks)
  (check-live-buffer 'modes:set-major-mode-delaying-hooks buffer)
  (unless (hook? (table-ref hooks mode #f))
    (assertion-violation 'modes:set-major-mode-delaying-hooks "not a major mode" mode))
  (buffers:reset-scope! buffer)
  (eq-hashtable-set! buffer-modes buffer mode)
  (eq-hashtable-set! %delayed buffer #t)
  (buffers:with-buffer buffer (delayed-mode-changed buffer)))

(define (hooks-delayed? buffer)
  (check-live-buffer 'modes:hooks-delayed? buffer)
  (eq-hashtable-ref %delayed buffer #f))

(define (run-delayed-hooks buffer)
  (check-main-thread 'modes:run-delayed-hooks)
  (check-live-buffer 'modes:run-delayed-hooks buffer)
  (when (eq-hashtable-ref %delayed buffer #f)
    (eq-hashtable-delete! %delayed buffer)
    (run-mode-hooks buffer)
    (buffers:with-buffer buffer (major-mode-changed buffer))))

(define (run-mode-hooks buffer)
  (check-main-thread 'modes:run-mode-hooks)
  (check-live-buffer 'modes:run-mode-hooks buffer)
  (let ([modes (reverse (ancestry-of (major-mode buffer)))])
    (buffers:with-buffer buffer
      (for-each
        (lambda (mode)
          (let ([hook (table-ref hooks mode #f)])
            (when hook (hook))))
        modes))))

(define (ancestry mode)
  (unless (symbol? mode)
    (assertion-violation 'modes:ancestry "not a mode" mode))
  (ancestry-of mode))

(define (derived? mode ancestor)
  (unless (symbol? mode)
    (assertion-violation 'modes:derived? "not a mode" mode))
  (unless (symbol? ancestor)
    (assertion-violation 'modes:derived? "not a mode" ancestor))
  (and (memq ancestor (ancestry-of mode)) #t))

(define (active-minor-modes view)
  (unless (views:view? view)
    (assertion-violation 'modes:active-minor-modes "not a view" view))
  (check-main-thread 'modes:active-minor-modes)
  (minor-modes-on view))

(define (on? mode view)
  (unless (or (symbol? mode) (procedure? mode))
    (assertion-violation 'modes:on? "not a mode" mode))
  (unless (views:view? view)
    (assertion-violation 'modes:on? "not a view" view))
  (check-main-thread 'modes:on?)
  (let ([b (views:buffer view)])
    (or (and b (symbol? mode) (derived? (major-mode b) mode))
        (and (memq mode (minor-modes-on view)) #t))))

(define (command-for-view? command view)
  (unless (commands:command? command)
    (assertion-violation 'modes:command-for-view? "not a command" command))
  (unless (views:view? view)
    (assertion-violation 'modes:command-for-view? "not a view" view))
  (check-main-thread 'modes:command-for-view?)
  (let ([marks (table-ref commands:command-modes command #f)])
    (or (not marks) (exists (lambda (mode) (on? mode view)) marks))))

(define (active-keymaps client posn)
  (let ([view (if posn (views:posn-view posn) (views:current))])
    (if view
        (view-keymaps view)
        '())))

(define (language mode)
  (unless (symbol? mode)
    (assertion-violation 'modes:language "not a mode" mode))
  (exists (lambda (m) (table-ref languages m #f)) (ancestry-of mode)))

(define (lighter mode)
  (or (table-ref lighters mode #f)
      (and (symbol? mode) (table-ref hooks mode #f) (module-part mode))))

;; Loading a module takes back its local values in every scope, so the
;; hooks run again where a mode was set, and a new plugin's hook entries
;; reach buffers already open.
(define (%run-hooks-after-load loaded name)
  (loaded name)
  (for-each
    (lambda (b)
      (let ([mode (eq-hashtable-ref buffer-modes b #f)])
        (when (and mode (hook? (table-ref hooks mode #f)) (buffers:live? b) (not (eq-hashtable-ref %delayed b #f)))
          (run-mode-hooks b))))
    (buffers:all)))

(restore-modes!)
(keys:bind! special-keymap "g" buffers:revert-buffer)
(keys:bind! special-keymap "SPC" views:scroll-up)
(keys:bind! special-keymap "S-SPC" views:scroll-down)
(keys:bind! special-keymap "DEL" views:scroll-down)
(keys:bind! special-keymap "-" keys:negative-argument)
(for-each (lambda (d) (keys:bind! special-keymap d keys:digit-argument))
          '("0" "1" "2" "3" "4" "5" "6" "7" "8" "9"))
(add-hook! keys:find-keymaps active-keymaps 50)
(advice-add! module-loaded %run-hooks-after-load)
(on-unload save-modes!)
