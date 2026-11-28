(import (tuna) (test) (test-runner) (test-user) (web) (views) (buffers) (document) (layout) (layout-split) (modes) (hooks) (options)
        (tables) (commands) (keys) (editing) (help) (help-test) (help-test harpo))

(define (report-messages thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons (if (cancelled? c) 'cancelled (condition-message c)) reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(define (help-buffer) (buffers:find "*Help*"))

(define (shown)
  (map (lambda (v) (list (buffers:name (views:buffer v)) (eq? v (layout:selected-view))))
       (filter (lambda (v) (not (buffers:internal-name? (buffers:name (views:buffer v))))) (layout:views))))

(test "before the first description there is nothing to refresh"
  (check-raises (test-runner:raised-with 'help:refresh "no description") (help:refresh)))

(test-user:show! "|help-test/harpo:honk\n")

(define notes (views:buffer (layout:selected-view)))

(define notes-view (layout:selected-view))

(modes:set-major-mode help-test/harpo:mode notes)

(test "the first description makes *Help* in help:mode, with the lighter Help, running its hook; it keeps no undo history and never reads as modified"
  (let ([hooked 0])
    (hooks:add! help:mode-hook (lambda () (set! hooked (+ hooked 1))))
    (test-user:press! "C-h m")
    (check-equal? (list 1 help:mode "Help" #t #f)
                  (list hooked (modes:major-mode (help-buffer)) (modes:lighter help:mode) (buffers:silent? (help-buffer))
                        (buffers:modified? (help-buffer))))))

(test "C-h m shows the minor modes on, each with its documentation and its keymap's, then the major mode and its ancestry, walking prefix keymaps"
  (let ([lines (help-test:lines)])
    (check-equal? "# Modes" (car lines))
    (check-equal? '("## help-test/harpo:mode" "Its lighter is Harpo." "Harpo's keys." "[C-c h]  <help-test/harpo:honk>")
                  (member "## help-test/harpo:mode" lines)))
  (tables:set! modes:minor-modes help-test/harpo:horn-mode? 10)
  (tables:set! modes:keymaps help-test/harpo:horn-mode? help-test/harpo:minor-keymap)
  (tables:set! modes:lighters help-test/harpo:horn-mode? "Horn")
  (keys:bind! help-test/harpo:keymap "C-c p" help-test/harpo:minor-keymap)
  (test-user:press! "C-h m")
  (let ([lines (help-test:lines)])
    (check-equal? '("## Horn" "Whether the horn is out." "Keys of the horn mode." "[C-c q]  <help-test/harpo:quiet>")
                  (list-head (member "## Horn" lines) 4))
    (check-equal? '("## help-test/harpo:mode" "Its lighter is Harpo." "Harpo's keys." "[C-c h]        <help-test/harpo:honk>"
                    "[C-c p C-c q]  <help-test/harpo:quiet>")
                  (member "## help-test/harpo:mode" lines))))

(test "C-h b shows one section per active keymap that decides a sequence, in lookup order, a sequence an earlier keymap decides not listed again"
  (keys:bind! keys:global "C-c h" help-test/harpo:quiet)
  (test-user:press! "C-h b")
  (let ([outline (help-test:outline)] [lines (help-test:lines)])
    (check-equal? "# Key bindings" (car outline))
    (check (member "## Horn" outline))
    (check (member "## help-test/harpo:mode" outline))
    (check-equal? "## keys:global" (car (last-pair outline)))
    (check (< (length (member "## keys:global" outline)) (length (member "## help-test/harpo:mode" outline))
              (length (member "## Horn" outline))))
    (check-equal? '("[C-c h]        <help-test/harpo:honk>") (filter (lambda (l) (string=? "[C-c h]  " (substring l 0 (min 9 (string-length l))))) lines)))
  (tables:remove! keys:global "C-c h"))

(test "going back, going forward and refreshing describe from the view first described, not from *Help*"
  (layout:select! (help-test:help-view))
  (test-user:press! "C-h m")
  (check (member "## help:mode" (help-test:outline)))
  (test-user:press! "l")
  (check-equal? "Key bindings" (help-test:title))
  (test-user:press! "l")
  (check-equal? '("Modes" #t) (list (help-test:title) (and (member "## help-test/harpo:mode" (help-test:outline)) #t)))
  (test-user:press! "l")
  (check-equal? '("no earlier description") (report-messages (lambda () (test-user:press! "l"))))
  (test-user:press! "r r r")
  (check-equal? '("no later description") (report-messages (lambda () (test-user:press! "r"))))
  (check (member "## help:mode" (help-test:outline)))
  (test-user:press! "g")
  (check (member "## help:mode" (help-test:outline))))

(test "a view that is gone gives way to the selected view"
  (test-user:press! "l l")
  (layout:select! notes-view)
  (test-user:press! "C-x 3")
  (layout:select! notes-view)
  (test-user:press! "C-x 0")
  (check-equal? #f (memq notes-view (views:showing notes)))
  (layout:select! (help-test:help-view))
  (test-user:press! "g")
  (check (member "## help:mode" (help-test:outline))))

(test "names in *Help* are links: RET or a click follows one, describing what it names from the view of the description"
  (let ([view (car (views:showing notes))])
    (layout:select! view)
    (help:describe-key "C-c h" view)
    (test-user:settle)
    (layout:select! (help-test:help-view))
    (views:set-point! (help-test:help-view) (+ (help-test:link-token "help-test/harpo:mode") 1))
    (test-user:press! "RET")
    (check-equal? "help-test/harpo:mode" (help-test:title))
    (help:describe-key "C-c h" view)
    (test-user:settle)
    (help-test:click-link! "help-test/harpo:honk")
    (check-equal? '("# help-test/harpo:honk" "<help-test/harpo:honk> is a command in (help-test harpo)." "It is on [C-c h]."
                    "It is for <help-test/harpo:mode>." "Honks once.")
                  (help-test:lines))))

(test "printing keys are undefined in *Help*, and q quits its view"
  (layout:select! (help-test:help-view))
  (views:set-point! (help-test:help-view) 3)
  (check-equal? '("x is undefined") (report-messages (lambda () (test-user:press! "x"))))
  (check-equal? "help-test/harpo:honk" (help-test:title))
  (test-user:press! "q")
  (check-equal? '(("*test*" #t)) (shown)))

(test "help:select-view? selects the view showing *Help*"
  (options:set! help:select-view? #t)
  (test-user:press! "C-h l")
  (check-equal? '(("*test*" #f) ("*Help*" #t)) (shown))
  (options:unset! help:select-view?))

(test "a killed *Help* is made again by the next description, which runs help:mode-hook again"
  (let ([hooked 0])
    (hooks:add! help:mode-hook (lambda () (set! hooked (+ hooked 1))))
    (buffers:kill! (help-buffer))
    (test-user:press! "C-h l")
    (check-equal? '("Recent keys" 1) (list (help-test:title) hooked))))

(test "C-h l shows the recent keys, oldest first, a line per command, a link while it is a loaded command; g shows the keys typed since"
  (keys:bind! keys:global "<f5>" help-test/harpo:honk)
  (test-user:press! "<f5>")
  (let ([view (car (views:showing (help-buffer)))])
    (layout:select! view)
    (for-each (lambda (table) (tables:remove! table help-test/harpo:horn-mode?)) (list modes:minor-modes modes:keymaps modes:lighters))
    (unload-owner! (module-owner '(help-test harpo)))
    (test-user:press! "g")
    (let ([lines (help-test:lines)])
      (check (member "[<f5>]            help-test/harpo:honk" lines))
      (check (member "[g]               <buffers:revert-buffer>" lines)))))

(test "going back to a command or a name that is gone says so, and the history goes on past it"
  (let loop ([seen '()] [n 0])
    (if (< n 8)
        (begin (report-messages (lambda () (test-user:press! "l"))) (loop (cons (help-test:title) seen) (+ n 1)))
        (begin
          (check (member "help-test/harpo:honk is not a loaded command" seen))
          (check (member "help-test/harpo:mode is not an exported name" seen))))))

(test "*Help* draws as a div.help with its title, its keys and its links, and its headings and bindings"
  (help:describe-key "C-x o" (car (views:showing (buffers:find "*test*"))))
  (test-user:settle)
  (let ([help (car (test-user:elements (test-user:screen) "help"))])
    (let ([title (car (test-user:elements help "help-title"))])
      (check-equal? '("heading" "1") (list (test-user:element-attribute title "role") (test-user:element-attribute title "aria-level"))))
    (check-equal? '(kbd) (map car (test-user:elements help "help-key")))
    (check (pair? (test-user:elements help "help-text")))
    (check (pair? (test-user:elements help "ui-link"))))
  (help:describe-bindings (car (views:showing (buffers:find "*test*"))))
  (test-user:settle)
  (let ([help (car (test-user:elements (test-user:screen) "help"))])
    (check-equal? "2" (test-user:element-attribute (car (test-user:elements help "help-heading")) "aria-level"))
    (check (pair? (test-user:elements help "help-bindings"))))
  (check-equal? "help/help.css" (tables:ref web:stylesheets 'help #f)))

(test "*Help* derives from modes:special, whose keymap gives the keys for reading, and g refreshes through buffers:revert-buffer"
  (layout:select! (help-test:help-view))
  (check-equal? (list #t (list help:mode modes:special)) (list (modes:derived? help:mode modes:special) (modes:ancestry help:mode)))
  (check-equal? (list layout:quit-view views:scroll-up views:scroll-down views:scroll-down help:describe-mode help:describe-mode
                      keys:digit-argument keys:negative-argument buffers:revert-buffer help:back help:forward)
                (views:call-with-view (help-test:help-view)
                  (lambda () (map (lambda (k) (keys:lookup (test-user:client) k)) '("q" "SPC" "S-SPC" "DEL" "?" "h" "3" "-" "g" "l" "r")))))
  (check (eq? help:refresh (buffers:with-buffer (help-buffer) (buffers:revert-function))))
  (test-user:press! "?")
  (check-equal? "Modes" (help-test:title))
  (let* ([refreshed 0] [count (lambda (refresh) (set! refreshed (+ refreshed 1)) (refresh))])
    (advice-add! help:refresh count)
    (test-user:press! "g")
    (advice-remove! help:refresh count)
    (check-equal? '(1 "Modes") (list refreshed (help-test:title)))))

(test "help:buffer? is true of *Help* only, for a display rule"
  (check-equal? '(#t #f) (list (help:buffer? (help-buffer)) (help:buffer? notes)))
  (tables:set! layout:display-rules help:buffer? layout-split:display-below)
  (test-user:press! "q")
  (layout:select! (car (views:showing notes)))
  (help:describe-key "C-x o" (layout:selected-view))
  (test-user:settle)
  (check-equal? '("*Help*" #f) (assoc "*Help*" (shown)))
  (check (eq? notes (views:buffer (layout:selected-view))))
  (tables:remove! layout:display-rules help:buffer?))

(test "unloading help takes back its keys, advice and stylesheet and leaves *Help*; a new instance finds *Help* and starts with no history"
  (let ([old (module-owner '(help))])
    (unload-owner! old)
    (check-equal? '(#f #f) (list (owner-live? old) (exists (lambda (c) (eq? (car c) old)) (definition-changes keys:undefined))))
    (check-equal? #f (tables:ref web:stylesheets 'help #f))
    (check (buffers:live? (help-buffer)))
    (load-module! '(help))
    (test-user:press! "C-x C-h")
    (check-equal? "Key bindings starting with C-x" (help-test:title))
    (layout:select! (help-test:help-view))
    (check-equal? '("no earlier description") (report-messages (lambda () (test-user:press! "l"))))))
