#!tuna
(import (buffers) (views) (keys) (commands) (ask) (hooks) (options) (tables) (saved) (plugins))

(tables:define-table hooks
  "Maps each major mode to its hook. A major mode is defined while it has an entry here.")

(tables:define-table keymaps
  "Maps a major mode or a minor mode to its keymap.")

(tables:define-table parents
  "Maps a major mode to the mode it derives from.")

(tables:define-table lighters
  "Maps a mode to its lighter, the short name a status line shows for it.")

(tables:define-table languages
  "Maps a major mode to its language, the identifier the Language Server Protocol gives it, such as \"python\".")

(tables:define-table minor-modes
  "Maps each minor mode, a procedure of no arguments that returns true where the mode is on, to its depth, a real number.")

(tables:define-table plugin-only
  "Maps a major mode to #t when only its own plugin sets it, on buffers that plugin makes: modes:switch-major-mode neither offers it nor switches a buffer away from it.")

(tables:define-table minor-mode-majors
  "Maps a minor mode to the list of major modes it is for: modes:toggle-minor-mode offers it only in a buffer whose major mode derives from one of them.")

(tables:define-table %names
  "Maps a minor mode defined with modes:define-minor-mode to its name.")

(hooks:define-hook major-mode-changed
  "Called with a buffer, current, after modes:set-major-mode has called its mode hooks.")

(tables:define-table fundamental-keymap
  "Keys in buffers whose major mode is modes:fundamental.")

(hooks:define-hook fundamental-hook
  "Called in each buffer whose major mode becomes modes:fundamental.")

(define (%saved-modes? v)
  (or (null? v)
      (and (pair? v) (fixnum? (car v)) (list? (cdr v))
           (for-all (lambda (entry) (and (pair? entry) (string? (car entry)) (symbol? (cdr entry))))
                    (cdr v)))))

;; Unload actions also run at exit, so the process id tells a reload, which
;; finds its buffers' modes again by name, from a restart, which starts
;; with none.
(saved:define-saved %saved-modes '() %saved-modes?)

(module %internals
  (check-main-thread check-live-buffer define-major-mode! define-minor-mode! buffer-modes ancestry-of
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
    (let ([owner (owner-name (current-owner))])
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

  (define (define-major-mode! id parent lighter keymap hook language plugin-only?)
    (define who 'modes:define-major-mode)
    (unless (or (not parent) (symbol? parent))
      (assertion-violation who "not a mode" parent))
    (unless (or (not lighter) (string? lighter))
      (assertion-violation who "not a string" lighter))
    (unless (tables:table? keymap)
      (assertion-violation who "not a keymap" keymap))
    (unless (hooks:hook? hook)
      (assertion-violation who "not a hook" hook))
    (unless (or (not language) (string? language))
      (assertion-violation who "not a string" language))
    (unless (boolean? plugin-only?)
      (assertion-violation who "not a boolean" plugin-only?))
    (let ([mode (exported-symbol id)])
      (tables:set! hooks mode hook)
      (tables:set! keymaps mode keymap)
      (if parent (tables:set! parents mode parent) (tables:remove! parents mode))
      (if lighter (tables:set! lighters mode lighter) (tables:remove! lighters mode))
      (if language (tables:set! languages mode language) (tables:remove! languages mode))
      (if plugin-only? (tables:set! plugin-only mode #t) (tables:remove! plugin-only mode))
      mode))

  (define (define-minor-mode! mode id depth lighter keymap majors)
    (define who 'modes:define-minor-mode)
    (unless (real? depth)
      (assertion-violation who "not a real number" depth))
    (unless (or (not lighter) (string? lighter))
      (assertion-violation who "not a string" lighter))
    (unless (or (not keymap) (tables:table? keymap))
      (assertion-violation who "not a keymap" keymap))
    (when majors
      (for-each (lambda (m) (unless (symbol? m) (assertion-violation who "not a mode" m))) majors))
    (tables:set! minor-modes mode depth)
    (if lighter (tables:set! lighters mode lighter) (tables:remove! lighters mode))
    (if keymap (tables:set! keymaps mode keymap) (tables:remove! keymaps mode))
    (if majors (tables:set! minor-mode-majors mode majors) (tables:remove! minor-mode-majors mode))
    (tables:set! %names mode (exported-symbol id)))

  ;; A table entry can make parents a cycle.
  (define (ancestry-of mode)
    (let loop ([m mode] [acc '()])
      (if (or (not m) (memq m acc))
          (reverse acc)
          (loop (tables:ref parents m #f) (cons m acc)))))

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
    (let ([on '()] [next (tables:entries minor-modes)])
      (let run ()
        (unless (null? next)
          (call/cc
            (lambda (k)
              (with-exception-handler
                (lambda (c)
                  (if (or (cancelled? c) (warning-only? c))
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
          (let ([keymap (tables:ref keymaps m #f)] [next (tables:ref parents m #f)])
            (if keymap
                (cons keymap (loop next (cons m seen)))
                (loop next (cons m seen)))))))

  (define (view-keymaps view)
    (let ([buffer (views:buffer view)])
      (fold-right
        (lambda (entry acc)
          (let ([keymap (tables:ref keymaps (car entry) #f)])
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
    (saved:set! %saved-modes
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
(meta define (%mode-clauses who form clauses names)
  (let loop ([clauses clauses] [found '()])
    (if (null? clauses)
        (lambda (name) (let ([c (assq name found)]) (and c (cdr c))))
        (let* ([c (car clauses)]
               [name (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ #f])])
          (unless (memq name names)
            (syntax-violation who "invalid clause" form c))
          (when (assq name found)
            (syntax-violation who "clause given twice" form c))
          (loop (cdr clauses) (cons (cons name c) found))))))

(meta define (%clause-expression who form clause default)
  (if clause
      (syntax-case clause () [(_ e) #'e] [_ (syntax-violation who "invalid clause" form clause)])
      default))

(define-syntax define-major-mode
  (lambda (x)
    (define who 'modes:define-major-mode)
    (syntax-case x ()
      [(_ id clause ...)
       (identifier? #'id)
       (let* ([clause (%mode-clauses who x #'(clause ...) '(parent lighter keymap hook language plugin-only))]
              [expression (lambda (name default) (%clause-expression who x (clause name) default))])
         (unless (clause 'keymap) (syntax-violation who "a keymap clause is required" x))
         (unless (clause 'hook) (syntax-violation who "a hook clause is required" x))
         #`(define-public id
             (define-major-mode! 'id #,(expression 'parent #'#f) #,(expression 'lighter #'#f)
               #,(expression 'keymap #f) #,(expression 'hook #f) #,(expression 'language #'#f)
               #,(expression 'plugin-only #'#f))))]
      [_ (syntax-violation who "expected (modes:define-major-mode id clause ...)" x)])))

(define-syntax define-minor-mode
  (lambda (x)
    (define who 'modes:define-minor-mode)
    (syntax-case x ()
      [(_ id doc clause ...)
       (and (identifier? #'id) (string? (syntax->datum #'doc)))
       (let* ([clause (%mode-clauses who x #'(clause ...) '(default on-change state depth lighter keymap majors))]
              [expression (lambda (name default) (%clause-expression who x (clause name) default))])
         (with-syntax ([depth (expression 'depth #'0)]
                       [lighter (expression 'lighter #'#f)]
                       [keymap (expression 'keymap #'#f)]
                       [majors (let ([c (clause 'majors)])
                                 (if c
                                     (syntax-case c () [(_ e1 e2 ...) #'(list e1 e2 ...)] [_ (syntax-violation who "invalid clause" x c)])
                                     #'#f))])
           (let ([register #'(define-values ()
                               (begin (define-minor-mode! id 'id depth lighter keymap majors) (values)))]
                 [state (clause 'state)])
             (if state
                 (begin
                   (for-each
                     (lambda (name)
                       (when (clause name)
                         (syntax-violation who "a state mode has no default or on-change clause" x (clause name))))
                     '(default on-change))
                   ;; A state mode is called with no arguments, so formals that
                   ;; require one would fail at every key.
                   (syntax-case state ()
                     [(_ formals body1 body2 ...)
                      (syntax-case #'formals ()
                        [() #t]
                        [rest (identifier? #'rest) #t]
                        [_ (syntax-violation who "a state mode's formals must allow no arguments" x state)])
                      #`(begin
                          (define-public (id . formals) doc body1 body2 ...)
                          #,register)]
                     [_ (syntax-violation who "invalid clause" x state)]))
                 (with-syntax ([default (expression 'default #'#f)]
                               [on-change (expression 'on-change #'#f)])
                   #`(begin
                       (options:define-option id default boolean? doc on-change)
                       #,register))))))]
      [_ (syntax-violation who "expected (modes:define-minor-mode id doc-string clause ...)" x)])))

(define-major-mode fundamental
  (lighter "Fundamental")
  (keymap fundamental-keymap)
  (hook fundamental-hook))

(tables:define-table special-keymap
  "Keys in buffers that are read, not edited, whose major modes derive from modes:special.")

(hooks:define-hook special-hook
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
  (unless (hooks:hook? (tables:ref hooks mode #f))
    (assertion-violation 'modes:set-major-mode "not a major mode" mode))
  (buffers:reset-scope! buffer)
  (eq-hashtable-set! buffer-modes buffer mode)
  (eq-hashtable-delete! %delayed buffer)
  (run-mode-hooks buffer)
  (buffers:with-buffer buffer (major-mode-changed buffer)))

(hooks:define-hook delayed-mode-changed
  "Called with a buffer, current, after modes:set-major-mode-delaying-hooks has set its mode: the work a mode with delayed hooks allows, such as a highlighter's.")

;; A mode set with its hooks delayed, as for a file a preview opens, still
;; draws, but runs no mode hook, which may start work for the buffer as a
;; language server does, until the hooks run.
(define %delayed (make-weak-eq-hashtable))

(define (set-major-mode-delaying-hooks mode buffer)
  (check-main-thread 'modes:set-major-mode-delaying-hooks)
  (check-live-buffer 'modes:set-major-mode-delaying-hooks buffer)
  (unless (hooks:hook? (tables:ref hooks mode #f))
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
          (let ([hook (tables:ref hooks mode #f)])
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
  (let ([marks (tables:ref commands:command-modes command #f)])
    (or (not marks) (exists (lambda (mode) (on? mode view)) marks))))

(define (active-keymaps client posn)
  (let ([view (if posn (views:posn-view posn) (views:current))])
    (if view
        (view-keymaps view)
        '())))

(define (language mode)
  (unless (symbol? mode)
    (assertion-violation 'modes:language "not a mode" mode))
  (exists (lambda (m) (tables:ref languages m #f)) (ancestry-of mode)))

(define (lighter mode)
  (or (tables:ref lighters mode #f)
      (and (symbol? mode) (tables:ref hooks mode #f) (module-part mode))))

(define (name mode)
  (cond
    [(symbol? mode) (and (tables:ref hooks mode #f) mode)]
    [(procedure? mode) (tables:ref %names mode #f)]
    [else #f]))

(define (%by-name modes)
  (list-sort (lambda (a b) (string<? (symbol->string (name a)) (symbol->string (name b)))) modes))

(define (%check-not-plugin-only who mode)
  (when (tables:ref plugin-only mode #f)
    (errorf who "~a is set only by its plugin" mode)))

(define (%read-major-mode)
  (let* ([buffer (buffers:current)] [current (major-mode buffer)])
    (%check-not-plugin-only 'modes:switch-major-mode current)
    (values
      (ask:choice "Major mode: "
        (map (lambda (m)
               (if (eq? m current)
                   (vector (symbol->string m) m "current")
                   (cons (symbol->string m) m)))
             (%by-name (remp (lambda (m) (tables:ref plugin-only m #f)) (map car (tables:entries hooks))))))
      buffer)))

(commands:define-command (switch-major-mode [(mode buffer) (%read-major-mode)])
  "Sets BUFFER's major mode to MODE with modes:set-major-mode, reading MODE by name among the major modes that are not plugin-only. Refuses when MODE or BUFFER's mode is plugin-only."
  (check-main-thread 'modes:switch-major-mode)
  (check-live-buffer 'modes:switch-major-mode buffer)
  (unless (hooks:hook? (tables:ref hooks mode #f))
    (assertion-violation 'modes:switch-major-mode "not a major mode" mode))
  (%check-not-plugin-only 'modes:switch-major-mode (major-mode buffer))
  (%check-not-plugin-only 'modes:switch-major-mode mode)
  (set-major-mode mode buffer))

(define (%option-mode? mode)
  (and (options:option? mode) (tables:ref %names mode #f) #t))

(define (%for-major? mode major)
  (let ([majors (tables:ref minor-mode-majors mode #f)])
    (or (not majors) (exists (lambda (m) (derived? major m)) majors))))

(define (%read-minor-mode)
  (let* ([buffer (buffers:current)]
         [view (let ([v (views:current)]) (and v (eq? (views:buffer v) buffer) v))]
         [prefix (commands:prefix-argument)]
         [number (commands:prefix-number)]
         [major (major-mode buffer)]
         [state (lambda (m) (if view (views:call-with-view view m) (buffers:with-buffer buffer (m))))]
         [mode (ask:choice "Toggle minor mode: "
                 (map (lambda (m) (vector (symbol->string (name m)) m (if (state m) "on" "off")))
                      (%by-name (filter (lambda (m) (and (options:option? m) (%for-major? m major)))
                                        (map car (tables:entries %names))))))])
    (values mode buffer (if prefix (>= number 1) (not (state mode))))))

(define (%toggle-message mode buffer on?)
  (let ([view (views:current)])
    (format "~a ~a in current buffer~a" (name mode) (if on? "enabled" "disabled")
      (if (and view (eq? (views:buffer view) buffer) (not (eq? (views:call-with-view view mode) on?)))
          "; this view keeps its own value"
          ""))))

(commands:define-command (toggle-minor-mode [(mode buffer on?) (%read-minor-mode)])
  "Sets the option mode MODE's local value in BUFFER to ON?, reading MODE by name among the option modes for BUFFER's major mode. Read by name, ON? is the opposite of MODE's state in the selected view; with a prefix argument, it is true when the argument's number is 1 or more."
  (check-main-thread 'modes:toggle-minor-mode)
  (check-live-buffer 'modes:toggle-minor-mode buffer)
  (unless (%option-mode? mode)
    (assertion-violation 'modes:toggle-minor-mode "not an option mode" mode))
  (unless (boolean? on?)
    (assertion-violation 'modes:toggle-minor-mode "not a boolean" on?))
  (let ([major (major-mode buffer)])
    (unless (%for-major? mode major)
      (assertion-violationf 'modes:toggle-minor-mode "~a is not for ~a" (name mode) major)))
  (if (eq? (commands:this-command) toggle-minor-mode)
      (let ([outer (ask:message-writer)] [spoke? #f])
        (options:with ([ask:message-writer (lambda (text) (set! spoke? #t) (outer text))])
          (buffers:with-buffer buffer (options:set-local! mode on?)))
        (unless spoke? (ask:message (%toggle-message mode buffer on?))))
      (buffers:with-buffer buffer (options:set-local! mode on?))))

;; Loading a module takes back its local values in every scope, so the
;; hooks run again where a mode was set, and a new plugin's hook entries
;; reach buffers already open. The configuration, read again whenever a
;; plugin it imports reloads, is no module, so its reading counts too.
(define (%run-hooks-after-load loaded name)
  (loaded name)
  (%run-mode-hooks-again!))

(define (%run-hooks-after-configuration loaded)
  (loaded)
  (%run-mode-hooks-again!))

(define (%run-mode-hooks-again!)
  (for-each
    (lambda (b)
      (let ([mode (eq-hashtable-ref buffer-modes b #f)])
        (when (and mode (hooks:hook? (tables:ref hooks mode #f)) (buffers:live? b) (not (eq-hashtable-ref %delayed b #f)))
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
(hooks:add! keys:find-keymaps active-keymaps 50)
(advice-add! module-loaded %run-hooks-after-load)
(advice-add! plugins:configuration-loaded %run-hooks-after-configuration)
(on-unload save-modes!)
