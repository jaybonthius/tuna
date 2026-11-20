#!tuna
(import (keys) (commands) (lossage) (buffers) (document) (views) (layout) (modes) (completion)
        (echo-area) (ui) (web) (haml) (syntax) (chez-scheme))

(define-option select-view? #f boolean?
  "Whether a describing command selects the view showing *Help*.")

(define-saved name-history '() (lambda (v) (and (list? v) (for-all string? v))))

(define-saved command-history '() (lambda (v) (and (list? v) (for-all string? v))))

(define-table keymap "The help commands, bound to C-h.")

(define-table mode-keymap "Keys in *Help*.")

(define-hook mode-hook "Called with *Help* current when a description makes it, or finds it for the first time after help loads.")

(modes:define-major-mode mode (parent modes:special) (lighter "Help") (keymap mode-keymap) (hook mode-hook))

(define (%draw-page node view) (haml (:div.help (views:draw-children view node))))

(define (%draw-title node view)
  (haml (:div.help-title ([role "heading"] [aria-level "1"]) (views:draw-children view node))))

(define (%draw-heading node view)
  (haml (:div.help-heading ([role "heading"] [aria-level "2"]) (views:draw-children view node))))

(define (%draw-text node view) (haml (:div.help-text (views:draw-children view node))))

(define (%draw-bindings node view) (haml (:div.help-bindings (views:draw-children view node))))

(define (%draw-key node view) (haml (:kbd.help-key (views:draw-children view node))))

(buffers:define-kind %page (content nodes) (draw %draw-page))
(buffers:define-kind %title (draw %draw-title))
(buffers:define-kind %heading (draw %draw-heading))
(buffers:define-kind %text (draw %draw-text))
(buffers:define-kind %bindings (draw %draw-bindings))
(buffers:define-kind %key (inline) (draw %draw-key))

;; Links take typed text by their kind, so one read-only span over the
;; whole buffer refuses every edit; help writes with splice!, which asks
;; no layer.
(buffers:define-layer %read-only (read-only) (sticky both))

;; A description keeps its view's number rather than the view, so a view
;; dropped since is found gone.
(define %current #f)
(define %earlier '())
(define %later '())

(define (%entry-view entry)
  (or (views:find (cdr entry)) (layout:selected-view)))

(define (%content-in entry)
  (let ([view (%entry-view entry)])
    (views:call-with-view view (lambda () ((car entry) view)))))

(define %buffer #f)

;; It holds nothing to save, so killing it never asks.
(define (%help-buffer)
  (unless (and %buffer (buffers:live? %buffer))
    (let ([b (or (buffers:find "*Help*") (buffers:make "*Help*" (%page '())))])
      (buffers:set-silent! b #t)
      (modes:set-major-mode mode b)
      (set! %buffer b)))
  %buffer)

(define (%show! datums)
  (let* ([b (%help-buffer)] [doc (buffers:document b)])
    (buffers:splice! b 0 (document:length doc) (document:from-datum (apply %page '() datums)))
    (let ([n (document:length (buffers:document b))])
      (buffers:set-spans! (buffers:layer b %read-only) 0 n (list (list 0 n '()))))
    ;; Inside the title's node, so the cursor shows on the title's line
    ;; rather than on a line of its own before it.
    (let ([v (layout:display-buffer b)])
      (views:set-point! v 2)
      (when (select-view?) (layout:select! v)))))

(define (%describe! content view)
  (let* ([entry (cons content (views:id view))] [datums (%content-in entry)])
    (set! %earlier (if %current (cons %current %earlier) %earlier))
    (set! %later '())
    (set! %current entry)
    (%show! datums)))

(define (%check-view who view)
  (unless (views:view? view)
    (assertion-violation who "not a view" view)))

(define (buffer? b)
  (unless (buffers:buffer? b)
    (assertion-violation 'help:buffer? "not a buffer" b))
  (eq? b %buffer))

(define (%title-datum text) (%title '() (string-append text "\n")))

(define (%heading-datum text) (%heading '() (string-append text "\n")))

(define (%link-to name) (%link (list (cons 'name name)) (symbol->string name)))

(define (%command-label command)
  (if (commands:command? command)
      (symbol->string (commands:command-name command))
      "a command that is not loaded"))

(define (%command-link command)
  (if (commands:command? command)
      (%link-to (commands:command-name command))
      "a command that is not loaded"))

(define (%named-command-link name)
  (if (commands:command-named name) (%link-to name) (symbol->string name)))

(define (%joined items separator)
  (if (null? items)
      '()
      (cons (car items)
            (let loop ([items (cdr items)])
              (if (null? items) '() (cons* separator (car items) (loop (cdr items))))))))

(define (%key-datum keys) (%key '() keys))

;; Spaces line up the second column, since bindings are drawn in the
;; code font.
(define (%rows-datum rows)
  (let ([width (fold-left (lambda (w row) (fxmax w (string-length (car row)))) 0 rows)])
    (apply %bindings '()
      (fold-right
        (lambda (row acc)
          (let ([pad (make-string (fx+ (fx- width (string-length (car row))) 2) #\space)])
            (if (string=? (car row) "")
                (cons* pad (cdr row) "\n" acc)
                (cons* (%key-datum (car row)) pad (cdr row) "\n" acc))))
        '() rows))))

(define (%binding-rows bindings)
  (map (lambda (b) (cons (car b) (%command-link (cdr b)))) bindings))

(define (%mode-label mode)
  (if (symbol? mode)
      (symbol->string mode)
      (or (modes:lighter mode) "a minor mode")))

(define (%keymap-heading keymap)
  (cond
    [(eq? keymap keys:global) "keys:global"]
    [(find (lambda (entry) (eq? (cdr entry) keymap)) (table-entries modes:keymaps))
     => (lambda (entry) (%mode-label (car entry)))]
    [(documentation keymap)]
    [else "A keymap with no documentation"]))

(define (%sections-datums sections)
  (fold-right
    (lambda (section acc)
      (if (null? (cdr section))
          acc
          (cons* (%heading-datum (%keymap-heading (car section))) (%rows-datum (%binding-rows (cdr section))) acc)))
    '() sections))

(define (%starts-with? s prefix)
  (and (fx<= (string-length prefix) (string-length s))
       (string=? (substring s 0 (string-length prefix)) prefix)))

(define (%after-prefix prefix sections)
  (let ([start (string-append prefix " ")])
    (map (lambda (section) (cons (car section) (filter (lambda (b) (%starts-with? (car b) start)) (cdr section))))
         sections)))

(define (%documentation-datum v)
  (%text '() (string-append (or (documentation v) "No documentation.") "\n")))

(define (%library-of name)
  (let ([names (chez-scheme:repl-names)])
    (let loop ([i 0])
      (cond
        [(fx= i (vector-length names)) #f]
        [(eq? (chez-scheme:name-export (vector-ref names i)) name) (chez-scheme:name-library (vector-ref names i))]
        [else (loop (fx+ i 1))]))))

(define (%environment library) (environment '(tuna) library))

;; A changeable definition's name is syntax to Chez, so its module's
;; definitions tell it from syntax.
(define (%changeable? name library)
  (exists (lambda (change) (and (eq? (car change) 'define) (eq? (cadr change) name)))
          (module-changes library)))

(define (%changes-datums name library)
  (let ([changes (filter (lambda (change) (memq (cadr change) '(override advice)))
                         (eval (list 'definition-changes name) (%environment library)))])
    (if (null? changes)
        '()
        (list (%heading-datum "Changes")
              (apply %text '()
                (map (lambda (change)
                       (format "~a by ~s\n" (if (eq? (cadr change) 'override) "Override" "Advice") (car change)))
                     changes))))))

(define (%entries n) (if (= n 1) "1 entry" (format "~a entries" n)))

(define (%written v)
  (parameterize ([print-graph #t]) (format "~s" v)))

(define (%command-body command view)
  (let* ([name (commands:command-name command)] [library (%library-of name)]
         [keys (keys:where-is (web:current-client) command)]
         [modes (table-ref commands:command-modes command #f)])
    (append
      (list (%text '() (%link-to name)
              (if library
                  (format " is a command in ~s.\n" library)
                  " is a command of the configuration or the REPL.\n"))
            (apply %text '()
              (if (null? keys)
                  (list "It is on no key; run it with " (%key-datum "M-x") " " (symbol->string name) ".\n")
                  (append (list "It is on ") (%joined (map %key-datum keys) ", ") (list ".\n")))))
      (cond
        [(not modes) '()]
        [(null? modes) (list (%text '() "It is for no mode.\n"))]
        [else
         (list (apply %text '()
                 (append (list "It is for ")
                         (%joined (map (lambda (m) (if (symbol? m) (%link-to m) (%mode-label m))) modes) ", ")
                         (list ".\n"))))])
      (list (%documentation-datum command))
      (if library (%changes-datums name library) '()))))

(define (%command-content name)
  (lambda (view)
    (let ([command (commands:command-named name)])
      (if command
          (cons (%title-datum (symbol->string name)) (%command-body command view))
          (list (%title-datum (format "~a is not a loaded command" name)))))))

(define (%option-datums v library)
  (let ([settings (option-settings v)])
    (append
      (list (%text '() (format "An option in ~s.\n" library))
            (%text '() (format "Its value here is ~a; its setting is ~a and its default ~a.\n"
                         (%written (v)) (%written (option-setting v)) (%written (option-default v)))))
      (if (null? settings)
          '()
          (list (%heading-datum "Settings")
                (apply %text '()
                  (map (lambda (s) (format "~s sets it to ~a.\n" (car s) (%written (cadr s)))) settings))))
      (list (%documentation-datum v)))))

(define (%value-datums name v library changeable? view)
  (append
    (cond
      [(commands:command? v) (%command-body v view)]
      [(option? v) (%option-datums v library)]
      [(hook? v)
       (list (%text '() (format "A hook in ~s with ~a.\n" library (%entries (length (hook-entries v)))))
             (%documentation-datum v))]
      [(table? v)
       (list (%text '() (format "A table in ~s with ~a.\n" library (%entries (length (table-entries v)))))
             (%documentation-datum v))]
      [(saved? v)
       (list (%text '() (format "Saved data in ~s.\n" library))
             (%text '() (format "Its value is ~a.\n" (%written (v)))))]
      [(procedure? v)
       (list (%text '() (format "A procedure in ~s.\n" library)) (%documentation-datum v))]
      [else
       (list (%text '() (format "A value in ~s.\n" library))
             (%text '() (format "Its value is ~a.\n" (%written v))))])
    (if (and changeable? (not (commands:command? v))) (%changes-datums name library) '())))

(define (%name-content name)
  (lambda (view)
    (let ([library (%library-of name)])
      (if library
          (let ([env (environment library)] [changeable? (%changeable? name library)])
            (cons (%title-datum (symbol->string name))
                  (if (or changeable? (top-level-bound? name env))
                      (%value-datums name (eval name env) library changeable? view)
                      (list (%text '() (format "Syntax in ~s, which keeps no documentation.\n" library))))))
          (list (%title-datum (format "~a is not an exported name" name)))))))

(define (%last-key keys)
  (let loop ([i (fx- (string-length keys) 1)])
    (cond
      [(fx< i 0) keys]
      [(char=? (string-ref keys i) #\space) (substring keys (fx+ i 1) (string-length keys))]
      [else (loop (fx- i 1))])))

(define (%sequence-of keys) (if (keys:event? keys) (keys:event-key keys) keys))

(define (%posn-of keys) (and (keys:event? keys) (keys:event-start keys)))

(define (%where keys)
  (if (keys:event? keys) (string-append (keys:event-key keys) " at that spot") keys))

;; The table that binds a sequence itself, rather than through
;; <printing-char>, shift or Meta, knows who bound it.
(define (%owner-in keymap seq)
  (if (table-ref keymap seq #f)
      (table-owner keymap seq)
      (let loop ([i 0])
        (cond
          [(fx= i (string-length seq)) #f]
          [(and (char=? (string-ref seq i) #\space) (table? (table-ref keymap (substring seq 0 i) #f)))
           (%owner-in (table-ref keymap (substring seq 0 i) #f) (substring seq (fx+ i 1) (string-length seq)))]
          [else (loop (fx+ i 1))]))))

(define (%binding-owner keys)
  (let ([seq (%sequence-of keys)])
    (exists (lambda (section) (and (assoc seq (cdr section)) (%owner-in (car section) seq)))
            (keys:active-bindings (web:current-client) (%posn-of keys)))))

(define (%key-content keys)
  (lambda (view)
    (let ([found (keys:lookup (web:current-client) keys)])
      (cond
        [(not found) (list (%title-datum (string-append (%where keys) " is undefined")))]
        [(table? found)
         (let ([prefix (%sequence-of keys)])
           (cons (%title-datum (string-append "Key bindings starting with " prefix))
                 (%sections-datums (%after-prefix prefix (keys:active-bindings (web:current-client) (%posn-of keys))))))]
        [else
         (let ([owner (%binding-owner keys)])
           (cons (%title-datum (format "~a runs the command ~a~a" (%where keys) (%command-label found)
                                 (if owner (format ", bound by ~s" owner) "")))
                 (if (commands:command? found) (%command-body found view) '())))]))))

(define %make-quit (record-constructor (record-constructor-descriptor &quit)))

;; A read returns quit keys as data, so a sequence ended by one cancels
;; here, and says so, as a quit key does outside a read.
(define (%read-keys)
  (let ([keys (keys:read-key-sequence "Describe the following key or mouse click: ")])
    (when (member (%last-key (%sequence-of keys)) (keys:quit-keys))
      (echo-area:message! "Quit")
      (raise (%make-quit)))
    keys))

(define (%check-keys who keys)
  (unless (or (string? keys) (keys:event? keys))
    (assertion-violation who "neither a key sequence nor an event" keys)))

(define (%described-export buffer spelling)
  (let ([name (chez-scheme:find-name buffer spelling)])
    (and name (member (chez-scheme:name-library name) (chez-scheme:tuna-libraries))
         (chez-scheme:name-export name))))

(define (%export-at buffer position)
  (let-values ([(start end) (syntax:symbol-bounds buffer position chez-scheme:mode)])
    (if start
        (values start (%described-export buffer (string->symbol (document:text (buffers:document buffer) start end))))
        (values #f #f))))

;; A list whose opening a space follows names no call, as Emacs's
;; function-called-at-point ignores one.
(define (%name-at-point)
  (let* ([view (views:current)] [buffer (and view (views:buffer view))])
    (and buffer
         (let ([point (views:point view)])
           (or (let-values ([(start export) (%export-at buffer point)]) export)
               (let ([openings (syntax:openings buffer point chez-scheme:mode)])
                 (and (pair? openings)
                      (let ([after (syntax:lexeme-end (list-ref openings (fx- (length openings) 1)))])
                        (let-values ([(start export) (%export-at buffer after)])
                          (and start (fx= start after) export))))))))))

(define %read-command
  (case-lambda
    [(question) (%read-command question #f)]
    [(question styles)
     (let* ([at (%name-at-point)]
            [default (and at (memq at (commands:public-command-names)) (symbol->string at))])
       (completion:read question
         (list (completion:source
                 (candidates (list->vector
                               (map (lambda (name) (cons (symbol->string name) (commands:command-named name)))
                                    (commands:public-command-names))))
                 (category completion:command-category)
                 (styles styles)))
         command-history default))]))

(define (%read-name)
  (let ([at (%name-at-point)])
    (completion:read "Describe name: "
      (list (completion:source
              (candidates (vector-map (lambda (name)
                                        (let ([export (chez-scheme:name-export name)])
                                          (vector (symbol->string export) export (chez-scheme:name-kind name))))
                                      (chez-scheme:repl-names)))
              (category completion:name-category)))
      name-history (and at (symbol->string at)))))

(commands:define-command (describe-key [keys (%read-keys)] [view (views:current)])
  "Shows in *Help* what KEYS, a key sequence or a mouse event, runs in VIEW, with that command's description; for a prefix, the bindings after it."
  (%check-keys 'help:describe-key keys)
  (%check-view 'help:describe-key view)
  (if (views:call-with-view view (lambda () (keys:lookup (web:current-client) keys)))
      (%describe! (%key-content keys) view)
      (echo-area:message! "~a is undefined" (%where keys))))

(commands:define-command (describe-key-briefly [keys (%read-keys)] [view (views:current)])
  "Shows in the echo area what KEYS, a key sequence or a mouse event, runs in VIEW."
  (%check-keys 'help:describe-key-briefly keys)
  (%check-view 'help:describe-key-briefly view)
  (let ([found (views:call-with-view view (lambda () (keys:lookup (web:current-client) keys)))])
    (echo-area:message! "~a"
      (cond
        [(not found) (string-append (%where keys) " is undefined")]
        [(table? found) (string-append (%where keys) " is a prefix")]
        [else (string-append (%where keys) " runs " (%command-label found))]))))

(commands:define-command (where-is [command (%read-command "Where is command: ")] [view (views:current)])
  "Shows in the echo area the key sequences that run COMMAND in VIEW."
  (unless (commands:command? command)
    (assertion-violation 'help:where-is "not a command" command))
  (%check-view 'help:where-is view)
  (let ([keys (views:call-with-view view (lambda () (keys:where-is (web:current-client) command)))]
        [name (commands:command-name command)])
    (if (null? keys)
        (echo-area:message! "~a is on no key" name)
        (echo-area:message! "~a is on ~{~a~^, ~}" name keys))))

(commands:define-command (describe-bindings [view (views:current)])
  "Shows in *Help* every key sequence bound in VIEW and the command it runs, one section per active keymap."
  (%check-view 'help:describe-bindings view)
  (%describe!
    (lambda (view)
      (cons (%title-datum "Key bindings") (%sections-datums (keys:active-bindings (web:current-client)))))
    view))

(commands:define-command (describe-command [command (%read-command "Describe command: ")] [view (views:current)])
  "Shows in *Help* COMMAND's module, the keys that run it in VIEW, its modes, its documentation, and its overrides and advice."
  (unless (commands:command? command)
    (assertion-violation 'help:describe-command "not a command" command))
  (%check-view 'help:describe-command view)
  (%describe! (%command-content (commands:command-name command)) view))

;; Apropos is a search by the words of a name in any order, whichever
;; styles a configuration chooses.
(commands:define-command (apropos-command [command (%read-command "Apropos command: " (list completion:any-order))] [view (views:current)])
  "Describes COMMAND in VIEW as help:describe-command does, reading it by words of its name in any order."
  (unless (commands:command? command)
    (assertion-violation 'help:apropos-command "not a command" command))
  (%check-view 'help:apropos-command view)
  (describe-command command view))

(commands:define-command (describe-name [name (%read-name)] [view (views:current)])
  "Shows in *Help* what the exported name NAME is, as seen from VIEW, with its module and documentation."
  (unless (symbol? name)
    (assertion-violation 'help:describe-name "not a symbol" name))
  (%check-view 'help:describe-name view)
  (unless (%library-of name)
    (assertion-violation 'help:describe-name "not an exported name" name))
  (%describe! (%name-content name) view))

(define (%keymap-own-bindings keymap)
  (let walk ([keymap keymap] [prefix #f] [path '()])
    (if (memq keymap path)
        '()
        (fold-right
          (lambda (b acc)
            (let ([seq (if prefix (string-append prefix " " (car b)) (car b))])
              (if (table? (cdr b))
                  (append (walk (cdr b) seq (cons keymap path)) acc)
                  (cons (cons seq (cdr b)) acc))))
          '() (keys:bindings keymap)))))

(define (%mode-datums mode)
  (let ([keymap (table-ref modes:keymaps mode #f)] [lighter (modes:lighter mode)])
    (append
      (list (%heading-datum (%mode-label mode)))
      (if (and lighter (symbol? mode)) (list (%text '() (format "Its lighter is ~a.\n" lighter))) '())
      (if (procedure? mode) (list (%documentation-datum mode)) '())
      (if keymap
          (let ([rows (%binding-rows (%keymap-own-bindings keymap))])
            (cons (%documentation-datum keymap) (if (null? rows) '() (list (%rows-datum rows)))))
          '()))))

(commands:define-command (describe-mode [view (views:current)])
  "Shows in *Help* the minor modes on in VIEW, then its major mode and the modes it derives from, with their keys."
  (%check-view 'help:describe-mode view)
  (%describe!
    (lambda (view)
      (let ([b (views:buffer view)])
        (cons (%title-datum "Modes")
              (fold-right (lambda (mode acc) (append (%mode-datums mode) acc))
                          '()
                          (append (modes:active-minor-modes view)
                                  (if b (modes:ancestry (modes:major-mode b)) '()))))))
    view))

(define (%lossage-rows record)
  (let loop ([record record] [keys '()] [acc '()])
    (cond
      [(null? record)
       (reverse (if (null? keys) acc (cons (cons (%keys-text keys) "") acc)))]
      [(string? (car record)) (loop (cdr record) (cons (car record) keys) acc)]
      [else (loop (cdr record) '() (cons (cons (%keys-text keys) (%named-command-link (car record))) acc))])))

(define (%keys-text keys) (apply string-append (%joined (reverse keys) " ")))

(commands:define-command (view-lossage)
  "Shows in *Help* the recent keys of every client, oldest first, each line the keys before a command and the command."
  (%describe!
    (lambda (view)
      (let ([rows (%lossage-rows (lossage:recent-keys))])
        (cons (%title-datum "Recent keys")
              (if (null? rows) '() (list (%rows-datum rows))))))
    (or (views:current) (layout:selected-view))))

(commands:define-command (back)
  "Describes again what *Help* showed before the current description, from its view."
  (when (null? %earlier)
    (error 'help:back "no earlier description"))
  (let* ([entry (car %earlier)] [datums (%content-in entry)])
    (set! %later (cons %current %later))
    (set! %earlier (cdr %earlier))
    (set! %current entry)
    (%show! datums)))

(commands:define-command (forward)
  "Describes again what *Help* showed after the current description."
  (when (null? %later)
    (error 'help:forward "no later description"))
  (let* ([entry (car %later)] [datums (%content-in entry)])
    (set! %earlier (cons %current %earlier))
    (set! %later (cdr %later))
    (set! %current entry)
    (%show! datums)))

(commands:define-command (refresh)
  "Describes the current description's subject again, as it is now."
  (unless %current
    (error 'help:refresh "no description"))
  (%show! (%content-in %current)))

(commands:define-command (%follow-link [link (ui:pushed-button)])
  "Describes the name LINK names, from the view of the description it is in."
  (let ([name (document:node-attribute link 'name #f)]
        [view (if %current (%entry-view %current) (layout:selected-view))])
    (let ([command (and (symbol? name) (commands:command-named name))])
      (if command (describe-command command view) (describe-name name view)))))

(ui:define-link %link %follow-link)

;; keys calls undefined for every sequence no keymap binds, so a prefix
;; followed by the key of the help commands lands here, whatever key the
;; user put them on.
(define (%describe-prefix undefined)
  (let* ([keys (keys:command-keys)] [view (views:current)] [last (and keys (%last-key keys))])
    (if (and view last (not (string=? last keys)) (eq? (keys:lookup (web:current-client) last) keymap))
        (describe-key (substring keys 0 (fx- (string-length keys) (fx+ (string-length last) 1))) view)
        (undefined))))

(define (%set-revert) (set-option-local! buffers:revert-function refresh))

(keys:bind! keys:global "C-h" keymap)
(keys:bind! keymap "a" apropos-command)
(keys:bind! keymap "b" describe-bindings)
(keys:bind! keymap "c" describe-key-briefly)
(keys:bind! keymap "f" describe-name)
(keys:bind! keymap "k" describe-key)
(keys:bind! keymap "l" view-lossage)
(keys:bind! keymap "m" describe-mode)
(keys:bind! keymap "o" describe-name)
(keys:bind! keymap "v" describe-name)
(keys:bind! keymap "w" where-is)
(keys:bind! keymap "x" describe-command)
(keys:bind! completion:command-action-keymap "h" describe-command)
(keys:bind! completion:name-action-keymap "h" describe-name)
(keys:bind! mode-keymap "l" back)
(keys:bind! mode-keymap "r" forward)
(keys:bind! modes:special-keymap "?" describe-mode)
(keys:bind! modes:special-keymap "h" describe-mode)
(add-hook! mode-hook %set-revert)
(table-set! web:stylesheets 'help "help/help.css")
(advice-add! keys:undefined %describe-prefix)
