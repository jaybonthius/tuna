(import (tuna) (test) (test-runner) (test-user) (buffers) (document) (views) (terminal) (terminal-test))

(define t (terminal-test:shell!))

(define (screen-element)
  (test-user:settle)
  (car (test-user:elements (test-user:screen) "terminal-screen")))

(define (attribute e name) (test-user:element-attribute e name))

(define (marked name)
  (map (lambda (e) (list (test-user:element-text e) (attribute e name)))
       (test-user:elements-with (screen-element) name)))

(define (position-of part) (terminal-test:position-of t part))

(define (before-point n)
  (let ([p (views:point (terminal-test:view))]) (document:text (buffers:document t) (- p n) p)))

(define (browsed) (filter (lambda (call) (equal? "browse-url" (car call))) (test-user:take-page-calls!)))

(test "cell styles are drawn through ansi-colors, and each grapheme outside ASCII as wide as its cells"
  (terminal-test:show! t)
  (terminal:send! t "clear; printf '\\e[1;31mred\\e[0m \\e[38;2;1;2;3mrgb\\e[0m \\e[44;4mbg\\e[0m \\e[7minv\\e[0m 中文\\n'\r")
  (terminal-test:wait-for t "中文\n")
  (check-equal? '(("red" "ansi-colors.red")) (marked "data-face"))
  (check-equal? '(("red" "bold") ("rgb" "fg") ("bg" "bg-4 underline-single") ("inv" "fg-background bg-foreground"))
                (marked "data-ansi-colors"))
  (check-equal? '(("rgb" "--ansi-colors-fg:#010203;")) (marked "style"))
  (check-equal? '(("中" "2") ("文" "2")) (marked "data-cells")))

(test "with grapheme clustering a flag is one grapheme of two cells, and the rows keep that width after the program turns it off"
  (terminal:send! t "clear; printf '\\e[?2027h🇺🇸ab\\e]2;flag\\a'; read x; printf '\\e[?2027l'\r")
  (terminal-test:wait-for t "🇺🇸ab")
  (test-runner:wait-until (lambda () (equal? "flag" (terminal:title t))))
  (test-user:settle)
  (check-equal? '(("🇺🇸" "2")) (marked "data-cells"))
  (check-equal? "ab" (before-point 2))
  (terminal:send! t "\r")
  (terminal-test:wait-for t "\n$ ")
  (check-equal? '(("🇺🇸" "2")) (marked "data-cells")))

(test "the program's cursor is drawn at point, in the shape it asks for"
  (terminal:send! t "printf '\\e[6 q\\e]2;shaped\\a'\r")
  (test-runner:wait-until (lambda () (equal? "shaped" (terminal:title t))))
  (check-equal? "bar" (attribute (screen-element) "data-cursor")))

(test "links are OSC 8 hyperlinks, web addresses and references to files that exist, with a line and column"
  (call-with-output-file (terminal-test:home-file "notes.txt") (lambda (p) (put-string p "one\ntwo\nthree\n")))
  (terminal:send! t (string-append "clear; cd " (getenv "HOME")
                                   "; printf '\\e]8;;https://example.org\\e\\\\link\\e]8;;\\e\\\\ https://tuna.example/x. notes.txt:2:3 missing.txt:1\\n'\r"))
  (terminal-test:wait-for t "missing.txt:1\n")
  (let ([links (test-user:elements-with (screen-element) "data-terminal-link")])
    (check-equal? '("link" "https://tuna.example/x" "notes.txt:2:3") (map test-user:element-text links))
    (check-equal? '("clickable" "clickable" "clickable") (map (lambda (e) (attribute e "data-click")) links))))

(test "C-c C-p and C-c C-n enter copy mode and move to a link, and RET opens it: a URL in a new tab, a file at its line and column"
  (test-user:take-page-calls!)
  (test-user:press! "C-c C-p")
  (check-equal? 'copy (terminal-test:input-mode))
  (test-user:press! "C-c C-p C-c C-p RET")
  (check-equal? '(("browse-url" . "https://example.org")) (browsed))
  (test-user:press! "C-c C-n RET")
  (check-equal? '(("browse-url" . "https://tuna.example/x")) (browsed))
  (test-user:press! "C-c C-n RET")
  (check-equal? '("notes.txt" 7) (list (buffers:name (views:buffer (terminal-test:view))) (views:point (terminal-test:view)))))

(test "a click on a link opens it, and so does one with Control"
  (terminal-test:show! t)
  (test-user:press! "q")
  (test-user:click! (terminal-test:view) (+ (position-of "link ") 1))
  (check-equal? '(("browse-url" . "https://example.org")) (browsed))
  (test-user:click! (terminal-test:view) (+ (position-of "https://tuna") 1) "C-<mouse-1>")
  (check-equal? '(("browse-url" . "https://tuna.example/x")) (browsed)))

(test "while the program takes the mouse its screen carries the mouse keymap and names cells, and a click with Control still opens a link"
  (terminal:send! t "clear; printf '\\e[?1000h\\e]8;;https://example.org/m\\e\\\\mouse\\e]8;;\\e\\\\\\n\\e]2;mouse\\a'; read x; printf '\\e[?1000l'\r")
  (test-runner:wait-until (lambda () (equal? "mouse" (terminal:title t))))
  (let ([screen (screen-element)])
    (check-equal? (views:keymap-mark terminal:mouse-keymap) (attribute screen "data-keymap"))
    (check-equal? '("bar" "shift" "shift" "") (map (lambda (name) (attribute screen name)) '("data-cursor" "data-wheel" "data-grid" "data-body-cells")))
    (test-user:click-cell! screen 2 0 "C-<mouse-1>"))
  (check-equal? '(("browse-url" . "https://example.org/m")) (browsed))
  (terminal:send! t "\r")
  (terminal-test:wait-for t "\n$ "))

(test "on the alternate screen the screen takes the wheel but names characters, so a click on a link opens it"
  (terminal:send! t "clear; printf '\\e[?1049h\\e]8;;https://example.org/a\\e\\\\pager\\e]8;;\\e\\\\\\n\\e]2;pager\\a'; read x; printf '\\e[?1049l'\r")
  (test-runner:wait-until (lambda () (equal? "pager" (terminal:title t))))
  (let ([screen (screen-element)])
    (check-equal? '(#f "shift" #f) (map (lambda (name) (attribute screen name)) '("data-keymap" "data-wheel" "data-grid"))))
  (test-user:click! (terminal-test:view) (+ (position-of "pager") 1))
  (check-equal? '(("browse-url" . "https://example.org/a")) (browsed))
  (terminal:send! t "\r")
  (terminal-test:wait-for t "$ "))

(test "while the program holds synchronized output, the rows are written when it lets go"
  (terminal:send! t "clear; printf '\\e[?2026h%s%s\\e]2;held\\a' hel d; read x; printf '\\e[?2026l'; echo\r")
  (test-runner:wait-until (lambda () (equal? "held" (terminal:title t))))
  (check-equal? #f (terminal-test:screen-has? t "held"))
  (terminal:send! t "\r")
  (terminal-test:wait-for t "held"))

(test "the alternate screen replaces the screen, and the scrollback is hidden from every view until the program leaves it"
  (terminal-test:wait-for t "$ ")
  (terminal:send! t "seq 1 30; printf '\\e[?1049h\\e[Halt'; read x; printf '\\e[?1049l'\r")
  (terminal-test:wait-for t "alt\n")
  (check-equal? '("alt") (terminal-test:screen-lines t))
  (let-values ([(start end) (views:bounds (terminal-test:view))])
    (check-equal? 27 (string-length (document:text (document:slice (buffers:document t) start end)))))
  (terminal:send! t "\r")
  (test-runner:wait-until (lambda () (not (terminal-test:screen-has? t "alt"))))
  (test-user:settle)
  (let-values ([(start end) (views:bounds (terminal-test:view))])
    (check-equal? (list 0 (document:length (buffers:document t))) (list start end)))
  (check (member "30" (terminal-test:lines (terminal-test:text t)))))

(test "the program's clear of the scrollback empties the buffer's"
  (terminal:send! t "clear\r")
  (test-runner:wait-until (lambda () (not (member "30" (terminal-test:lines (terminal-test:text t))))))
  (check-equal? '("$ " "") (list-head (terminal-test:lines (terminal-test:text t)) 2)))
