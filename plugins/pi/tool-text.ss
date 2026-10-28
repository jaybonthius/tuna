;;; The text of a chat's tool blocks, from what Pi says of a tool call
;;; (after Pilish's tool rendering, agents/research/pi-chat/pilish.md §3):
;;; the key argument a header shows, a result's text with terminal escape
;;; sequences removed, its preview, an edit's diff, a duration. Plain
;;; strings and JSON values (hash tables, lists) in and out; no editor
;;; state.
prelude: :gerbil/core

(import :std/encoding/json
        ./jsonl)
(export strip-ansi
        tool-key-argument
        tool-path
        content-text
        text-preview
        text-capped
        edit-diff
        duration-text
        one-line)

;; S without terminal escape sequences (CSI, OSC, other ESC pairs) and
;; without control characters other than newline and tab; CR LF becomes LF.
(def (strip-ansi (s : :string)) => :string
  (let ((size (string-length s))
        (out (open-output-string)))
    (let lp ((i 0))
      (when (fx< i size)
        (let (c (string-ref s i))
          (cond
           ((char=? c #\escape)
            (let (next (and (fx< (fx1+ i) size) (string-ref s (fx1+ i))))
              (cond
               ((eqv? next #\[)
                ;; Parameters and intermediates, then one final byte.
                (let csi ((j (fx+ i 2)))
                  (cond
                   ((fx>= j size) (lp j))
                   ((let (n (char->integer (string-ref s j))) (and (fx>= n #x40) (fx<= n #x7e))) (lp (fx1+ j)))
                   (else (csi (fx1+ j))))))
               ((eqv? next #\])
                ;; Up to BEL or ESC \.
                (let osc ((j (fx+ i 2)))
                  (cond
                   ((fx>= j size) (lp j))
                   ((char=? (string-ref s j) (integer->char 7)) (lp (fx1+ j)))
                   ((and (char=? (string-ref s j) #\escape) (fx< (fx1+ j) size) (char=? (string-ref s (fx1+ j)) #\\))
                    (lp (fx+ j 2)))
                   (else (osc (fx1+ j))))))
               (next (lp (fx+ i 2)))
               (else (lp (fx1+ i))))))
           ((char=? c #\return)
            (unless (and (fx< (fx1+ i) size) (char=? (string-ref s (fx1+ i)) #\newline))
              (write-char #\newline out))
            (lp (fx1+ i)))
           ((or (char=? c #\newline) (char=? c #\tab) (fx>= (char->integer c) 32))
            (unless (fx= (char->integer c) 127) (write-char c out))
            (lp (fx1+ i)))
           (else (lp (fx1+ i)))))))
    (get-output-string out)))

;; S on one line: runs of white space as one space, at most LIMIT
;; characters, with an ellipsis when cut.
(def (one-line (s : :string) (limit : :fixnum := 120)) => :string
  (let ((out (open-output-string)))
    (let lp ((i 0) (space? #f))
      (when (fx< i (string-length s))
        (let (c (string-ref s i))
          (if (char-whitespace? c)
            (begin (unless space? (write-char #\space out)) (lp (fx1+ i) #t))
            (begin (write-char c out) (lp (fx1+ i) #f))))))
    (let* ((text (get-output-string out))
           (text (let trim ((t text))
                   (cond ((and (fx> (string-length t) 0) (char=? (string-ref t 0) #\space)) (trim (substring t 1 (string-length t))))
                         ((and (fx> (string-length t) 0) (char=? (string-ref t (fx1- (string-length t))) #\space))
                          (trim (substring t 0 (fx1- (string-length t)))))
                         (else t)))))
      (if (fx> (string-length text) limit)
        (string-append (substring text 0 (fx1- limit)) "…")
        text))))

;; The file a tool call of NAME with ARGS works on, or #f.
(def (tool-path (args : :t)) => (Maybe :string)
  (let (path (or (json-field args "path") (json-field args "file_path")))
    (and (string? path) (not (string-empty? path)) path)))

;; What a tool block's header shows after the tool's NAME: a bash
;; command, a read, write or edit path, else the arguments as JSON on one
;; line; "" for none.
(def (tool-key-argument (name : :string) (args : :t)) => :string
  (cond
   ((equal? name "bash")
    (let (command (json-field args "command"))
      (if (string? command) (one-line command) "")))
   ((tool-path args) => (lambda (path) path))
   ((and (hash-table? args) (fx> (hash-length args) 0))
    (one-line (with-catch (lambda (e) "") (lambda () (json->string args))) 80))
   (else "")))

;; The text of CONTENT, a message's content: a string, or a list of
;; blocks whose text blocks are joined; an image shows as [image].
(def (content-text (content : :t)) => :string
  (cond
   ((string? content) content)
   ((list? content)
    (string-join (filter-map (lambda (block)
                               (let (type (json-field block "type"))
                                 (cond
                                  ((equal? type "text") (let (t (json-field block "text")) (and (string? t) t)))
                                  ((equal? type "image") "[image]")
                                  (else #f))))
                             content)
                 "\n"))
   (else "")))

;; TEXT cut to at most BYTES characters, with a note of what was cut.
(def (text-capped (text : :string) (bytes : :fixnum)) => :string
  (if (fx<= (string-length text) bytes)
    text
    (string-append (substring text 0 bytes) "\n… (" (number->string (fx- (string-length text) bytes))
                   " more characters)")))

;; TEXT's preview: its first LINES lines, or its last with TAIL?, at
;; most BYTES characters, and how many lines were left out, as two
;; values. A final newline makes no line of its own.
(def (text-preview (text : :string) (lines : :fixnum) (tail? : :boolean) (bytes : :fixnum))
  (let* ((text (if (string-suffix? "\n" text) (substring text 0 (fx1- (string-length text))) text))
         (all (if (string-empty? text) [] (string-split text #\newline)))
         (count (length all))
         (kept (cond ((fx<= count lines) all)
                     (tail? (list-tail all (fx- count lines)))
                     (else (take all lines)))))
    (values (text-capped (string-join kept "\n") bytes) (fx- count (length kept)))))

;; The edits of an edit tool call's ARGS, as (OLD . NEW) strings: its
;; `edits` list, or one `oldText` and `newText`.
(def (edit-pairs (args : :t)) => :list
  (let ((edits (json-field args "edits"))
        (old (json-field args "oldText"))
        (new (json-field args "newText")))
    (append (if (list? edits)
              (filter-map (lambda (edit)
                            (let ((o (json-field edit "oldText")) (n (json-field edit "newText")))
                              (and (string? o) (string? n) (cons o n))))
                          edits)
              [])
            (if (and (string? old) (string? new)) [(cons old new)] []))))

;; An edit tool call's ARGS as a diff: each edit's old lines after "−",
;; its new ones after "+", edits apart by a blank line; and how many lines
;; it adds and removes. Three values; "" for no edits.
(def (edit-diff (args : :t))
  (let lp ((pairs (edit-pairs args)) (parts []) (added 0) (removed 0))
    (match pairs
      ([] (values (string-join (reverse parts) "\n\n") added removed))
      ([(cons old new) . more]
       (let ((old-lines (if (string-empty? old) [] (string-split old #\newline)))
             (new-lines (if (string-empty? new) [] (string-split new #\newline))))
         (lp more
             (cons (string-join (append (map (cut string-append "− " <>) old-lines)
                                        (map (cut string-append "+ " <>) new-lines))
                                "\n")
                   parts)
             (fx+ added (length new-lines))
             (fx+ removed (length old-lines))))))))

;; MS milliseconds, as a tool block shows how long it took.
(def (duration-text (ms : :real)) => :string
  (let (seconds (/ ms 1000.))
    (cond
     ((< seconds 10)
      (let (tenths (exact (round (* seconds 10))))
        (string-append (number->string (quotient tenths 10)) "." (number->string (remainder tenths 10)) " s")))
     ((< seconds 60) (string-append (number->string (exact (round seconds))) " s"))
     (else (let (whole (exact (round seconds)))
             (string-append (number->string (quotient whole 60)) " min "
                            (number->string (remainder whole 60)) " s"))))))
