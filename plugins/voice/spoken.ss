;;; Spoken commands, the parts that need no editor: commands' spoken
;;; names, the grammar of them the speech worker listens with, and how
;;; sure a recognized unit is of each command.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable))
(export spoken-name
        spoken-names
        spoken-names-grammar
        spoken-names-starting-with
        unit-candidates
        candidate-confidence
        command-decision)

;; NAME as plain spoken words: lowercase, hyphens as spaces, words of the
;; letters a to z separated by single spaces; #f when anything else is
;; left, as in "split-view-2" or "c++-mode".
(def (spoken-name (name : :string)) => (Maybe :string)
  (let (words (filter (lambda ((word : :string)) (not (string-empty? word)))
                      (string-split (string-map (lambda (c) (if (char=? c #\-) #\space c))
                                                (string-downcase name))
                                    #\space)))
    (and (pair? words)
         (andmap (lambda ((word : :string))
                   (string-every (lambda (c) (and (char>=? c #\a) (char<=? c #\z))) word))
                 words)
         (string-join words " "))))

(def (string-every (ok? : :procedure) (s : :string)) => :boolean
  (let lp ((i 0))
    (or (fx= i (string-length s))
        (and (ok? (string-ref s i)) (lp (fx1+ i))))))

;; The spoken names of COMMANDS, as (spoken . commands) pairs sorted by
;; spoken name, commands in the order given: each command's OVERRIDES
;; entry (command . string) when it has one, else its name. A command
;; whose spoken form is not plain words (spoken-name) is left out. Two
;; commands can share a spoken name; saying it then offers both.
(def (spoken-names (commands : :list) (overrides : :list)) => :list
  (let (table (make-hash-table))
    (for-each (lambda ((command : :symbol))
                (let* ((override (assq command overrides))
                       (spoken (spoken-name (if (and override (string? (cdr override)))
                                              (cdr override)
                                              (symbol->string command)))))
                  (when spoken
                    (hash-update! table spoken (lambda (others) (cons command others)) []))))
              commands)
    (list-sort (lambda ((a : :pair) (b : :pair)) (string<? (car a) (car b)))
               (hash-map (lambda (spoken commands) (cons spoken (reverse commands))) table))))

;; NAMES's grammar, in parakeet's grammar syntax: the root accepts exactly
;; one spoken name.
(def (spoken-names-grammar (names : :list)) => :string
  (string-append "root ::= "
                 (string-join (map (lambda ((pair : :pair)) (grammar-literal (car pair))) names) " | ")
                 "\n"))

;; TEXT as a quoted grammar literal.
(def (grammar-literal (text : :string)) => :string
  (call-with-output-string
   (lambda (port)
     (write-char #\" port)
     (string-for-each (lambda (c)
                        (when (memv c '(#\\ #\" #\[ #\] #\-))
                          (write-char #\\ port))
                        (write-char c port))
                      text)
     (write-char #\" port))))

;; The spoken names in NAMES that begin with PREFIX.
(def (spoken-names-starting-with (names : :list) (prefix : :string)) => :list
  (filter (lambda ((pair : :pair)) (string-prefix? prefix (car pair))) names))

;; (append (F X) ...) for each X in XS.
(def (append-map* (f : :procedure) (xs : :list)) => :list
  (foldr (lambda (x out) (append (f x) out)) [] xs))

;; How little the grammar forced a text, from 0 to 1: exp of how much
;; worse than the free transcription its score is, per encoder frame,
;; clamped to 1 (a bounded search can score a constrained path slightly
;; above the free one). An exact match scores 1.
(def (candidate-confidence (score : :real) (free-score : :real) (frames : :real)) => :real
  (if (> frames 0)
    (min 1.0 (exp (/ (- score free-score) frames)))
    (if (>= score free-score) 1.0 0.0)))

;; The commands a recognized UNIT (the worker's JSON unit, as a hash
;; table) may mean, as (command . confidence) pairs, most confident first,
;; each command once: its text and its alternatives, looked up in NAMES.
;; A text that is no spoken name is left out.
(def (unit-candidates (unit : HashTable) (names : :list)) => :list
  (let* ((free-score (hash-ref unit "free_score" 0))
         (frames (hash-ref unit "frames" 0))
         (texts (cons (cons (hash-ref unit "text" "") (hash-ref unit "score" 0))
                      (map (lambda (alternative)
                             (cons (hash-ref alternative "text" "") (hash-ref alternative "score" 0)))
                           (let (alternatives (hash-ref unit "alternatives" []))
                             (if (list? alternatives) alternatives [])))))
         (scored
          (append-map*
           (lambda ((pair : :pair))
             (let* ((text (car pair))
                    (spoken (and (string? text) (spoken-name text)))
                    (entry (and spoken (assoc spoken names)))
                    (score (cdr pair)))
               (if (and entry (real? score) (real? free-score) (real? frames))
                 (map (lambda (command) (cons command (candidate-confidence score free-score frames)))
                      (cdr entry))
                 [])))
           texts))
         (sorted (list-sort (lambda ((a : :pair) (b : :pair)) (> (cdr a) (cdr b))) scored)))
    (let lp ((rest sorted) (seen []) (out []))
      (cond
       ((null? rest) (reverse out))
       ((memq (caar rest) seen) (lp (cdr rest) seen out))
       (else (lp (cdr rest) (cons (caar rest) seen) (cons (car rest) out)))))))
;; What to do with CANDIDATES, (command . confidence) pairs most confident
;; first: (run command confidence) when the best is at least RUN
;; confident, at least MARGIN more than the next, and not in ALWAYS-ASK;
;; otherwise (ask candidates) with the at most COUNT candidates at least
;; OFFER confident; #f when there are none.
(def (command-decision (candidates : :list)
                       run: (run : :real) margin: (margin : :real) offer: (offer : :real)
                       count: (count : :fixnum) always-ask: (always-ask : :list)) => :t
  (let (offered (let lp ((rest candidates) (n 0))
                  (if (or (null? rest) (fx>= n count) (< (cdar rest) offer))
                    []
                    (cons (car rest) (lp (cdr rest) (fx1+ n))))))
    (cond
     ((null? offered) #f)
     ((and (>= (cdar offered) run)
           (or (null? (cdr candidates)) (>= (- (cdar offered) (cdadr candidates)) margin))
           (not (memq (caar offered) always-ask)))
      (list 'run (caar offered) (cdar offered)))
     (else (list 'ask offered)))))
