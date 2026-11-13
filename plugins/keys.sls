#!tuna
(import (commands) (web))

(define-table global "The global keymap, searched after every other.")

(define-hook find-keymaps
  "Called with a client; each entry returns a list of the client's keymaps, innermost first.")

(define-option left-option-meta? #t boolean? "Whether the left Option key on a Mac is Meta.")

(define-option right-option-meta? #t boolean? "Whether the right Option key on a Mac is Meta.")

(module %internals
  (check-main-thread check-key check-sequence check-keymap quit-keys? prefix-argument?
   remember-name! bound-name
   sessions session-of session-pending session-pending-set! session-prefix session-prefix-set!
   session-temporaries session-running session-running-set!
   keymaps-of resolve-key resolve-sequence prefix-binding? lone-escape? remapped
   last-key key-count browser-key
   current-press make-press current-keys current-shifted current-session make-quit
   push-temporary! end-temporary! end-temporaries! end-owned! test-temporaries! quit-paused!
   set-prefix! universal-arguments push-universal-arguments! give-page-settings!)

  (define main-thread (get-thread-id))

  (define (main-thread?) (fx= (get-thread-id) main-thread))

  (define (check-main-thread who)
    (unless (main-thread?)
      (assertion-violation who "not on the main thread")))

  (define (modifier-rank c)
    (case c [(#\C) 0] [(#\M) 1] [(#\S) 2] [(#\s) 3] [else #f]))

  ;; In "C--" the second hyphen is the key, so a modifier needs a
  ;; character after it.
  (define (base-start s start end)
    (let loop ([i start] [rank -1])
      (if (and (fx< (fx+ i 2) end) (char=? (string-ref s (fx+ i 1)) #\-) (modifier-rank (string-ref s i)))
          (let ([r (modifier-rank (string-ref s i))])
            (and (fx> r rank) (loop (fx+ i 2) r)))
          i)))

  (define (shift-modifier? s start base)
    (let loop ([i start])
      (and (fx< i base)
           (or (char=? (string-ref s i) #\S) (loop (fx+ i 2))))))

  (define (name-char? c)
    (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (char=? c #\-) (char=? c #\_)))

  (define (named-base? s start end)
    (let ([n (fx- end start)])
      (or (and (fx= n 3)
               (let ([name (substring s start end)])
                 (member name '("RET" "SPC" "TAB" "ESC" "DEL"))))
          (and (fx> n 2)
               (char=? (string-ref s start) #\<)
               (char=? (string-ref s (fx- end 1)) #\>)
               (let loop ([i (fx+ start 1)])
                 (or (fx= i (fx- end 1))
                     (and (name-char? (string-ref s i)) (loop (fx+ i 1)))))))))

  (define (printing-char? c)
    (not (or (char=? c #\space) (eq? (char-general-category c) 'Cc))))

  ;; Shift on a character is in the character itself, so S- goes only on
  ;; a named key.
  (define (valid-key? s start end)
    (let ([base (base-start s start end)])
      (and base
           (fx< base end)
           (if (fx= (fx- end base) 1)
               (and (printing-char? (string-ref s base)) (not (shift-modifier? s start base)))
               (named-base? s base end)))))

  (define (valid-sequence? s)
    (let ([n (string-length s)])
      (let loop ([start 0] [i 0])
        (cond
          [(fx= i n) (and (fx< start n) (valid-key? s start n))]
          [(char=? (string-ref s i) #\space)
           (and (fx< start i) (valid-key? s start i) (loop (fx+ i 1) (fx+ i 1)))]
          [else (loop start (fx+ i 1))]))))

  (define (check-key who key)
    (unless (and (string? key) (valid-key? key 0 (string-length key)))
      (assertion-violation who "not one valid key" key)))

  (define (check-sequence who keys)
    (unless (and (string? keys) (valid-sequence? keys))
      (assertion-violation who "not a valid key sequence" keys)))

  (define (check-keymap who keymap)
    (unless (table? keymap)
      (assertion-violation who "not a keymap" keymap)))

  (define (quit-keys? v)
    (and (list? v)
         (for-all (lambda (key) (and (string? key) (valid-key? key 0 (string-length key)))) v)))

  (define (prefix-argument? v)
    (define (count? v) (and (integer? v) (exact? v)))
    (or (not v) (count? v) (eq? v '-) (and (pair? v) (count? (car v)) (null? (cdr v)))))

  (define (last-space s)
    (let loop ([i (fx- (string-length s) 1)])
      (cond
        [(fx< i 0) #f]
        [(char=? (string-ref s i) #\space) i]
        [else (loop (fx- i 1))])))

  (define (last-key s)
    (let ([i (last-space s)])
      (if i (substring s (fx+ i 1) (string-length s)) s)))

  (define (key-count s)
    (let loop ([i 0] [n 1])
      (cond
        [(fx= i (string-length s)) n]
        [(char=? (string-ref s i) #\space) (loop (fx+ i 1) (fx+ n 1))]
        [else (loop (fx+ i 1) n)])))

  ;; A command's name, kept from when it was bound, names it once its
  ;; module has unloaded and the commands plugin has forgotten it.
  (define names (make-weak-eq-hashtable))

  (define (remember-name! v)
    (when (commands:command? v)
      (eq-hashtable-set! names v (commands:command-name v))))

  (define (bound-name v)
    (or (and (procedure? v) (eq-hashtable-ref names v #f)) v))

  (define-record-type session
    (sealed #t)
    (fields (mutable pending) (mutable prefix) (mutable temporaries) (mutable running)))

  ;; Ephemeron, so a frame that is gone takes its session with it even
  ;; when a temporary keymap's procedures hold the frame. A pending
  ;; sequence is one pair of what was typed and what it resolved to, so a
  ;; quit cannot leave the two apart.
  (define sessions (make-ephemeron-eq-hashtable))

  (define (session-of frame)
    (or (eq-hashtable-ref sessions frame #f)
        (let ([s (make-session #f #f '() '())])
          (eq-hashtable-set! sessions frame s)
          s)))

  (define (warning-only? c)
    (and (warning? c) (not (serious-condition? c))))

  ;; Not guard, which allocates more than the rest of a key's lookup; and
  ;; one handler for all the entries, set up again only after one that
  ;; fails, since a handler allocates more than calling an entry.
  (define (hook-keymaps frame)
    (let ([found '()] [next (hook-entries find-keymaps)])
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
                        (let ([keymaps (entry frame)])
                          (unless (and (list? keymaps) (for-all table? keymaps))
                            (assertion-violation 'keys:find-keymaps "an entry returned what is not a list of keymaps" keymaps))
                          (set! found (cons keymaps found))))
                      (loop)))))))
          (run)))
      (fold-left (lambda (keymaps entry-keymaps) (append entry-keymaps keymaps)) (list global) found)))

  (define-record-type temporary
    (sealed #t)
    (fields session keymap keep on-exit owner))

  (define (keymaps-of frame)
    (let ([s (eq-hashtable-ref sessions frame #f)])
      (let loop ([ts (if s (session-temporaries s) '())])
        (if (null? ts)
            (hook-keymaps frame)
            (cons (temporary-keymap (car ts)) (loop (cdr ts)))))))

  (define (space-after s from)
    (let loop ([i from])
      (cond
        [(fx= i (string-length s)) #f]
        [(char=? (string-ref s i) #\space) i]
        [else (loop (fx+ i 1))])))

  (define (find-in keymap seq)
    (or (table-ref keymap seq #f)
        (and (fx= (string-length seq) 1) (table-ref keymap "<printing-char>" #f))
        (find-below keymap seq 0)))

  (define (find-below keymap seq from)
    (let ([i (space-after seq from)])
      (and i
           (let ([v (table-ref keymap (substring seq 0 i) #f)])
             (cond
               [(table? v) (find-in v (substring seq (fx+ i 1) (string-length seq)))]
               [(eq? v #t) (find-below keymap seq (fx+ i 1))]
               [else #f])))))

  (define (find-first keymaps seq)
    (let loop ([ks keymaps])
      (if (null? ks)
          (values #f #f)
          (let ([v (find-in (car ks) seq)])
            (if v (values v (car ks)) (loop (cdr ks)))))))

  (define (prefix-binding? v) (or (eq? v #t) (table? v)))

  (define (escape-pending? base)
    (and base (string=? (last-key base) "ESC")))

  (define (with-meta key)
    (let ([base (base-start key 0 (string-length key))])
      (cond
        [(and (fx>= base 2) (char=? (string-ref key 0) #\M)) #f]
        [(and (fx>= base 4) (char=? (string-ref key 2) #\M)) #f]
        [(and (fx>= base 2) (char=? (string-ref key 0) #\C))
         (string-append "C-M-" (substring key 2 (string-length key)))]
        [else (string-append "M-" key)])))

  (define (unshifted seq)
    (let* ([start (let ([i (last-space seq)]) (if i (fx+ i 1) 0))]
           [end (string-length seq)]
           [base (base-start seq start end)])
      (cond
        [(shift-modifier? seq start base)
         (let loop ([i start])
           (if (char=? (string-ref seq i) #\S)
               (string-append (substring seq 0 i) (substring seq (fx+ i 2) end))
               (loop (fx+ i 2))))]
        [(and (fx= (fx- end base) 1)
              (let ([c (string-ref seq base)])
                (and (char-upper-case? c) (not (char=? c (char-downcase c))))))
         (string-append (substring seq 0 base) (string (char-downcase (string-ref seq base))))]
        [else #f])))

  (define (resolve-key keymaps base key)
    (let ([seq (if base (string-append base " " key) key)])
      (let-values ([(v found) (find-first keymaps seq)])
        (if v
            (values v found seq #f)
            (let* ([meta (and (escape-pending? base) (with-meta key))]
                   [seq (if meta
                            (let ([i (last-space base)])
                              (if i (string-append (substring base 0 i) " " meta) meta))
                            seq)])
              (let-values ([(v found) (if meta (find-first keymaps seq) (values #f #f))])
                (if v
                    (values v found seq #f)
                    (let ([plain (unshifted seq)])
                      (if plain
                          (let-values ([(v found) (find-first keymaps plain)])
                            (if v (values v found plain #t) (values #f #f seq #f)))
                          (values #f #f seq #f))))))))))

  ;; ESC ESC is M-ESC, not a second wait for a key to make Meta.
  (define (lone-escape? v base key)
    (and (not v) (string=? key "ESC") (not (escape-pending? base))))

  (define (resolve-sequence keymaps keys)
    (let loop ([base #f] [from 0])
      (let* ([i (space-after keys from)]
             [key (substring keys from (or i (string-length keys)))])
        (let-values ([(v found seq shifted?) (resolve-key keymaps base key)])
          (cond
            [(not i) (values v found shifted?)]
            [(or (prefix-binding? v) (lone-escape? v base key)) (loop seq (fx+ i 1))]
            [else (values #f #f #f)])))))

  (define (remapped keymaps command)
    (if (procedure? command)
        (let loop ([ks keymaps])
          (if (null? ks)
              command
              (or (table-ref (car ks) command #f) (loop (cdr ks)))))
        command))

  (define named-keys
    (let ([t (make-hashtable string-hash string=?)])
      (for-each
        (lambda (p) (hashtable-set! t (car p) (cdr p)))
        '((" " . "SPC") ("Enter" . "RET") ("Tab" . "TAB") ("Escape" . "ESC") ("Backspace" . "DEL")
          ("Delete" . "<delete>") ("Insert" . "<insert>") ("ArrowLeft" . "<left>")
          ("ArrowRight" . "<right>") ("ArrowUp" . "<up>") ("ArrowDown" . "<down>")
          ("Home" . "<home>") ("End" . "<end>") ("PageUp" . "<prior>") ("PageDown" . "<next>")))
      t))

  ;; A Mac composes a character from Option and the key, so Meta reads
  ;; the key from its place on a US keyboard; only Chromium offers the
  ;; layout's own map.
  (define us-keys
    (let ([t (make-hashtable string-hash string=?)])
      (for-each
        (lambda (p) (hashtable-set! t (car p) (cdr p)))
        '(("Backquote" . "`~") ("Minus" . "-_") ("Equal" . "=+") ("BracketLeft" . "[{")
          ("BracketRight" . "]}") ("Backslash" . "\\|") ("Semicolon" . ";:") ("Quote" . "'\"")
          ("Comma" . ",<") ("Period" . ".>") ("Slash" . "/?") ("Space" . "  ")
          ("Digit0" . "0)") ("Digit1" . "1!") ("Digit2" . "2@") ("Digit3" . "3#") ("Digit4" . "4$")
          ("Digit5" . "5%") ("Digit6" . "6^") ("Digit7" . "7&") ("Digit8" . "8*") ("Digit9" . "9(")))
      t))

  (define (us-key code shift?)
    (cond
      [(and (string? code) (fx= (string-length code) 4) (string=? (substring code 0 3) "Key")
            (char<=? #\A (string-ref code 3) #\Z))
       (let ([c (string-ref code 3)])
         (string (if shift? c (char-downcase c))))]
      [(and (string? code) (hashtable-ref us-keys code #f))
       => (lambda (pair) (string (string-ref pair (if shift? 1 0))))]
      [else #f]))

  (define (field item name)
    (let ([p (assoc name item)])
      (and p (cdr p))))

  (define (ascii-name? s)
    (and (fx> (string-length s) 1)
         (let loop ([i 0])
           (or (fx= i (string-length s))
               (let ([c (string-ref s i)])
                 (and (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9))
                      (loop (fx+ i 1))))))))

  (define (browser-key item)
    (unless (and (list? item) (for-all pair? item))
      (assertion-violation 'keys:item-key "not an item" item))
    (let ([key (field item "key")] [code (field item "code")] [modifiers (field item "modifiers")])
      (unless (string? key)
        (assertion-violation 'keys:item-key "an item without a key" item))
      (unless (vector? modifiers)
        (assertion-violation 'keys:item-key "an item without a list of modifiers" item))
      (let loop ([i 0] [control? #f] [alt? #f] [shift? #f] [super? #f] [graph? #f] [left? #f] [right? #f])
        (if (fx< i (vector-length modifiers))
            (let ([m (vector-ref modifiers i)])
              (cond
                [(not (string? m)) (assertion-violation 'keys:item-key "not a modifier name" m)]
                [(string=? m "control") (loop (fx+ i 1) #t alt? shift? super? graph? left? right?)]
                [(string=? m "alt") (loop (fx+ i 1) control? #t shift? super? graph? left? right?)]
                [(string=? m "shift") (loop (fx+ i 1) control? alt? #t super? graph? left? right?)]
                [(string=? m "super") (loop (fx+ i 1) control? alt? shift? #t graph? left? right?)]
                [(string=? m "alt-graph") (loop (fx+ i 1) control? alt? shift? super? #t left? right?)]
                [(string=? m "left-option") (loop (fx+ i 1) control? alt? shift? super? graph? #t right?)]
                [(string=? m "right-option") (loop (fx+ i 1) control? alt? shift? super? graph? left? #t)]
                [else (assertion-violation 'keys:item-key "not a modifier name" m)]))
            ;; AltGraph types a character, so the Control and Alt that some
            ;; systems report with it are part of typing it.
            (let* ([option-meta? (or (and left? (left-option-meta?)) (and right? (right-option-meta?)))]
                   [meta? (or option-meta? (and alt? (not graph?)))]
                   [name (or (and option-meta? (us-key code shift?)) key)]
                   [base (cond
                           [(hashtable-ref named-keys name #f)]
                           [(fx= (string-length name) 1) name]
                           [(ascii-name? name) (string-append "<" (string-downcase name) ">")]
                           [else (assertion-violation 'keys:item-key "not a key" key)])])
              (string-append
                (if (and control? (not graph?)) "C-" "")
                (if meta? "M-" "")
                (if (and shift? (fx> (string-length base) 1)) "S-" "")
                (if super? "s-" "")
                base))))))

  ;; One parameter for the three, since each binding costs a
  ;; dynamic-wind.
  (define-record-type press
    (sealed #t)
    (fields keys shifted? session))

  (define current-press (make-thread-parameter #f))

  ;; A thread forked in a command inherits its thread parameters, but runs
  ;; no command.
  (define (running-press)
    (and (main-thread?) (current-press)))

  (define (current-keys)
    (let ([p (running-press)]) (and p (press-keys p))))

  (define (current-shifted)
    (let ([p (running-press)]) (and p (press-shifted? p))))

  (define (current-session)
    (let ([p (running-press)]) (and p (press-session p))))

  (define make-quit (record-constructor (record-constructor-descriptor &quit)))

  (define (end-temporary! t)
    (let ([s (temporary-session t)])
      (when (memq t (session-temporaries s))
        (session-temporaries-set! s (remq t (session-temporaries s)))
        (guard (c [(not (quit-condition? c)) (report c)])
          ((temporary-on-exit t))))))

  (define (end-temporaries! s)
    (for-each end-temporary! (session-temporaries s)))

  (define (end-owned! owner)
    (vector-for-each
      (lambda (s)
        (for-each
          (lambda (t) (when (or (not owner) (equal? (temporary-owner t) owner)) (end-temporary! t)))
          (session-temporaries s)))
      (hashtable-values sessions)))

  ;; One unload action per owner, not one per push: the configuration and
  ;; the REPL push from every command the user runs and unload only at the
  ;; end.
  (define watched
    (let ([t (make-hashtable equal-hash equal?)])
      (hashtable-set! t (this-module) #t)
      t))

  (define (push-temporary! s keymap keep on-exit owner)
    (unless (hashtable-contains? watched owner)
      (on-unload (lambda () (hashtable-delete! watched owner) (end-owned! owner)))
      (hashtable-set! watched owner #t))
    (let ([t (make-temporary s keymap keep on-exit owner)])
      (session-temporaries-set! s (cons t (session-temporaries s)))
      t))

  (define (test-temporaries! s found command)
    (let loop ([ts (session-temporaries s)])
      (unless (null? ts)
        (let ([t (car ts)])
          (unless (and (memq t (session-temporaries s))
                       (guard (c [(not (quit-condition? c)) (report c) #f])
                         ((temporary-keep t) found command)))
            (end-temporary! t)
            (loop (cdr ts)))))))

  ;; The command that keys:keyboard-quit runs in is running, not paused,
  ;; and a command's task that has ended pauses no more. A signalled task
  ;; stays paused until it runs, so its entry goes at once and the next
  ;; C-g reaches the next paused command.
  (define (quit-paused! s)
    (let loop ([es (session-running s)])
      (unless (null? es)
        (let ([task (caar es)])
          (if (or (eq? task (current-task)) (task-done? task))
              (loop (cdr es))
              (begin
                (session-running-set! s (remq (car es) (session-running s)))
                (signal-task task (make-quit))))))))

  (define (set-prefix! s prefix)
    (session-prefix-set! s prefix)
    (commands:keep-last-command!))

  (define-table universal-arguments)

  (define (push-universal-arguments! s)
    (let ([ts (session-temporaries s)])
      (unless (and (pair? ts) (eq? (temporary-keymap (car ts)) universal-arguments))
        (push-temporary! s universal-arguments
          (lambda (found command) (eq? found universal-arguments))
          void (this-module)))))

  ;; The page script names each key as it is typed, so that a quit key
  ;; quits before the keys queued ahead of it run. A client whose stream
  ;; closed may have missed a change, so it gets the settings again once
  ;; it is connected.
  (define given '())

  (define (page-settings)
    (vector (quit-keys) (left-option-meta?) (right-option-meta?)))

  (define (current-settings? v)
    (and (eq? (vector-ref v 0) (quit-keys))
         (eq? (vector-ref v 1) (left-option-meta?))
         (eq? (vector-ref v 2) (right-option-meta?))))

  (define (settings-value v)
    (list (cons "quitKeys" (list->vector (vector-ref v 0)))
          (cons "leftOptionMeta" (vector-ref v 1))
          (cons "rightOptionMeta" (vector-ref v 2))))

  (define (give-page-settings!)
    (let ([clients (web:clients)])
      (unless (and (fx= (length clients) (length given))
                   (for-all (lambda (c g) (and (eq? c (car g)) (current-settings? (cdr g)))) clients given))
        (set! given
          (map (lambda (c)
                 (let ([g (assq c given)])
                   (if (and g (current-settings? (cdr g)))
                       g
                       (let ([v (page-settings)])
                         (web:call-page! c "keys-settings" (settings-value v))
                         (cons c v)))))
               clients))))))

(import %internals)

(define-option quit-keys '("C-g") quit-keys?
  "The keys that quit as they arrive, stopping the running command before the keys queued ahead of them run.")

(define (bind! keymap keys binding)
  (check-main-thread 'keys:bind!)
  (check-keymap 'keys:bind! keymap)
  (check-sequence 'keys:bind! keys)
  (unless (or (commands:command? binding) (table? binding))
    (assertion-violation 'keys:bind! "neither a command nor a keymap" binding))
  (remember-name! binding)
  ;; A leading part bound to a keymap is set to that keymap as this
  ;; binder's change too, so the part stays a prefix when the keymap's
  ;; binder unloads, and a mark does not hide the keymap's bindings.
  (let loop ([i 0])
    (when (fx< i (string-length keys))
      (when (char=? (string-ref keys i) #\space)
        (let* ([part (substring keys 0 i)] [v (table-ref keymap part #f)])
          (table-set! keymap part (if (table? v) v #t))))
      (loop (fx+ i 1))))
  (table-set! keymap keys binding))

(define (unbind! keymap keys)
  (check-keymap 'keys:unbind! keymap)
  (check-sequence 'keys:unbind! keys)
  (table-remove! keymap keys))

(define (remap! keymap command replacement)
  (check-main-thread 'keys:remap!)
  (check-keymap 'keys:remap! keymap)
  (unless (commands:command? command)
    (assertion-violation 'keys:remap! "not a command" command))
  (unless (commands:command? replacement)
    (assertion-violation 'keys:remap! "not a command" replacement))
  (remember-name! replacement)
  (table-set! keymap command replacement))

(define (bindings keymap)
  (check-keymap 'keys:bindings keymap)
  (filter (lambda (entry) (and (string? (car entry)) (not (eq? (cdr entry) #t))))
          (table-entries keymap)))

(define (active-keymaps frame)
  (check-main-thread 'keys:active-keymaps)
  (keymaps-of frame))

(define (lookup frame keys)
  (check-main-thread 'keys:lookup)
  (check-sequence 'keys:lookup keys)
  (let ([keymaps (keymaps-of frame)])
    (let-values ([(v found shifted?) (resolve-sequence keymaps keys)])
      (cond
        [(eq? v #t) found]
        [(table? v) v]
        [else (remapped keymaps v)]))))

(define (where-is frame command)
  (check-main-thread 'keys:where-is)
  (unless (commands:command? command)
    (assertion-violation 'keys:where-is "not a command" command))
  (let ([keymaps (keymaps-of frame)] [seen (make-hashtable string-hash string=?)] [sequences '()])
    (let walk ([walked keymaps] [prefix #f] [path '()])
      (for-each
        (lambda (keymap)
          (unless (memq keymap path)
            (for-each
              (lambda (entry)
                (let* ([k (car entry)] [v (cdr entry)] [seq (if prefix (string-append prefix " " k) k)])
                  (cond
                    [(table? v) (walk (list v) seq (cons keymap path))]
                    [(hashtable-contains? seen seq) (void)]
                    [else
                     (hashtable-set! seen seq #t)
                     (let-values ([(v found shifted?) (resolve-sequence keymaps seq)])
                       (when (eq? (remapped keymaps v) command)
                         (set! sequences (cons seq sequences))))])))
              (bindings keymap))))
        walked))
    (list-sort (lambda (a b) (fx< (key-count a) (key-count b))) (reverse sequences))))

(define (press! frame key)
  (check-main-thread 'keys:press!)
  (check-key 'keys:press! key)
  (let* ([s (session-of frame)]
         [pending (session-pending s)]
         [base (and pending (cdr pending))]
         [typed (if pending (string-append (car pending) " " key) key)]
         [keymaps (keymaps-of frame)])
    (let-values ([(v found seq shifted?) (resolve-key keymaps base key)])
      (if (or (prefix-binding? v) (lone-escape? v base key))
          (session-pending-set! s (cons typed seq))
          (let ([prefix (session-prefix s)] [command (and v (remapped keymaps v))])
            (session-pending-set! s #f)
            (session-prefix-set! s #f)
            (test-temporaries! s found command)
            (cond
              [(and command (not (commands:command? command)))
               (raise-continuable
                 (condition (make-warning)
                   (make-message-condition
                     (format "~a runs ~a, which is not loaded" typed (bound-name command)))))]
              [else
               (let ([entry (list (current-task))])
                 (when (car entry)
                   (session-running-set! s (cons entry (session-running s))))
                 (parameterize ([current-press (make-press typed shifted? s)])
                   (if (eq? (commands:prefix-argument) prefix)
                       (commands:run (or command undefined))
                       (parameterize ([commands:prefix-argument prefix])
                         (commands:run (or command undefined)))))
                 (session-running-set! s
                   (remp (lambda (e) (or (eq? e entry) (task-done? (car e)))) (session-running s))))]))))))

(define (pending frame)
  (check-main-thread 'keys:pending)
  (let ([s (eq-hashtable-ref sessions frame #f)])
    (and s (session-pending s) (car (session-pending s)))))

(define (command-keys) (current-keys))

(define (typed-char)
  (let ([keys (current-keys)])
    (and keys
         (let ([key (last-key keys)])
           (cond
             [(fx= (string-length key) 1) (string-ref key 0)]
             [(string=? key "SPC") #\space]
             [(string=? key "TAB") #\tab]
             [(string=? key "RET") #\newline]
             [else #f])))))

(define (shift-translated?) (current-shifted))

(define push-keymap!
  (case-lambda
    [(frame keymap keep) (push-keymap! frame keymap keep void)]
    [(frame keymap keep on-exit)
     (check-main-thread 'keys:push-keymap!)
     (check-keymap 'keys:push-keymap! keymap)
     (unless (procedure? keep)
       (assertion-violation 'keys:push-keymap! "not a procedure" keep))
     (unless (procedure? on-exit)
       (assertion-violation 'keys:push-keymap! "not a procedure" on-exit))
     (let ([t (push-temporary! (session-of frame) keymap keep on-exit (current-owner))])
       (lambda ()
         (check-main-thread 'keys:push-keymap!)
         (end-temporary! t)))]))

(define (item-key item) (browser-key item))

(define (set-prefix-argument! prefix)
  (check-main-thread 'keys:set-prefix-argument!)
  (unless (prefix-argument? prefix)
    (assertion-violation 'keys:set-prefix-argument! "not a prefix argument" prefix))
  (let ([s (current-session)])
    (unless s
      (assertion-violation 'keys:set-prefix-argument! "no command a key ran is running"))
    (set-prefix! s prefix)))

(commands:define-command (keyboard-quit)
  "Clears the frame's pending keys and prefix argument; with none, also ends its temporary keymaps and quits the newest paused command its keys started."
  (let ([s (current-session)])
    (when s
      (let ([none? (and (not (commands:prefix-argument)) (fx= (key-count (current-keys)) 1))])
        (session-pending-set! s #f)
        (session-prefix-set! s #f)
        (when none?
          (end-temporaries! s)
          (quit-paused! s))))))

(commands:define-command (undefined)
  "Raises a warning that the keys that ran it are undefined."
  (raise-continuable
    (condition (make-warning)
      (make-message-condition (format "~a is undefined" (or (current-keys) "the key"))))))

(commands:define-command (universal-argument)
  "Sets the prefix argument to (4), or four times a list one, then digits and - go on typing it."
  (let ([s (current-session)])
    (when s
      (let ([p (commands:prefix-argument)])
        (set-prefix! s (if (pair? p) (list (* 4 (car p))) '(4)))
        (push-universal-arguments! s)))))

(commands:define-command (digit-argument)
  "Appends the digit of the keys that ran it to the prefix argument."
  (let ([s (current-session)] [keys (current-keys)])
    (when (and s keys)
      (let* ([key (last-key keys)] [c (string-ref key (fx- (string-length key) 1))])
        (when (char<=? #\0 c #\9)
          (let ([d (fx- (char->integer c) (char->integer #\0))] [p (commands:prefix-argument)])
            (set-prefix! s
              (cond
                [(integer? p) (+ (* p 10) (if (< p 0) (- d) d))]
                [(eq? p '-) (if (fx= d 0) '- (- d))]
                [else d]))
            (push-universal-arguments! s)))))))

(commands:define-command (negative-argument)
  "Negates the prefix argument, or makes it -."
  (let ([s (current-session)])
    (when s
      (let ([p (commands:prefix-argument)])
        (set-prefix! s
          (cond
            [(integer? p) (- p)]
            [(eq? p '-) #f]
            [else '-]))
        (push-universal-arguments! s)))))

(bind! global "C-g" keyboard-quit)
(bind! global "C-u" universal-argument)
(bind! global "M--" negative-argument)
(for-each
  (lambda (d)
    (bind! global (string-append "M-" d) digit-argument)
    (bind! universal-arguments d digit-argument))
  '("0" "1" "2" "3" "4" "5" "6" "7" "8" "9"))
(bind! universal-arguments "-" negative-argument)

(table-set! web:scripts 'keys "keys/keys.js")

(advice-add! batch-ended
  (lambda (ended)
    (ended)
    (give-page-settings!)))

(on-unload (lambda () (end-owned! #f)))
