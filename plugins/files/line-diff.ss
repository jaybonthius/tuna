;;; The changes between two versions of a text, line by line (Myers' diff),
;;; so that reloading a file replaces only the lines that changed, and
;;; cursors, marks and highlights elsewhere stay where they were.
prelude: :gerbil/core

(export (struct-out text-edit)
        text-edits)

;; Replace START..END (1-based character positions) of the old text with
;; REPLACEMENT.
(defstruct text-edit ((start       : :fixnum)
                      (end         : :fixnum)
                      (replacement : :string))
  final: #t)

;; How many steps the diff may take before it gives up and replaces
;; everything between the first and last changed line at once.
(def diff-work-limit 4000000)

;; The edits that turn OLD into NEW, last first, so each can be applied in
;; turn without moving the positions of the ones after it. Whole lines are
;; compared, each with its line break.
(def (text-edits (old : :string) (new : :string)) => :list
  (if (string=? old new)
    []
    (let* ((old-lines (string-lines old))
           (new-lines (string-lines new))
           (old-ids (make-vector (vector-length old-lines) 0))
           (new-ids (make-vector (vector-length new-lines) 0)))
      (number-lines! old-lines new-lines old-ids new-ids)
      (let* ((n (vector-length old-ids))
             (m (vector-length new-ids))
             (prefix (let lp ((i 0))
                       (if (and (fx< i n) (fx< i m) (fx= (vector-ref old-ids i) (vector-ref new-ids i)))
                         (lp (fx1+ i))
                         i)))
             (suffix (let lp ((i 0))
                       (if (and (fx< (fx+ prefix i) n) (fx< (fx+ prefix i) m)
                                (fx= (vector-ref old-ids (fx- n (fx1+ i))) (vector-ref new-ids (fx- m (fx1+ i)))))
                         (lp (fx1+ i))
                         i)))
             (a (subvector old-ids prefix (fx- n suffix)))
             (b (subvector new-ids prefix (fx- m suffix)))
             (matches (or (matching-lines a b) []))
             ;; Line pairs that stay, with sentinels before and after.
             (kept (append [(cons (fx1- prefix) (fx1- prefix))]
                           (map (lambda ((pair : :pair)) (cons (fx+ prefix (car pair)) (fx+ prefix (cdr pair))))
                                matches)
                           [(cons (fx- n suffix) (fx- m suffix))]))
             (starts (line-starts old-lines)))
        (let lp ((rest kept) (edits []))
          (match rest
            ([(cons i j) (cons i2 j2) . _]
             (lp (cdr rest)
                 (if (and (fx= i2 (fx1+ i)) (fx= j2 (fx1+ j)))
                   edits
                   (cons (make-text-edit (fx1+ (vector-ref starts (fx1+ i)))
                                         (fx1+ (vector-ref starts i2))
                                         (lines-string new-lines (fx1+ j) j2))
                         edits))))
            (else edits)))))))

;; S's lines, each with its line break; the last may have none.
(def (string-lines (s : :string)) => :vector
  (let ((size (string-length s)))
    (let lp ((start 0) (lines []))
      (if (fx= start size)
        (list->vector (reverse lines))
        (let (break (let find ((i start))
                      (cond
                       ((fx= i size) size)
                       ((char=? (string-ref s i) #\newline) (fx1+ i))
                       (else (find (fx1+ i))))))
          (lp break (cons (substring s start break) lines)))))))

;; Give each distinct line a number, so lines compare as fixnums.
(def (number-lines! (old-lines : :vector) (new-lines : :vector) (old-ids : :vector) (new-ids : :vector)) => :void
  (let (numbers (make-hash-table))
    (def (number! (lines : :vector) (ids : :vector)) => :void
      (let lp ((i 0))
        (when (fx< i (vector-length lines))
          (let* ((line (vector-ref lines i))
                 (id (or (hash-get numbers line)
                         (let (id (hash-length numbers))
                           (hash-put! numbers line id)
                           id))))
            (vector-set! ids i id)
            (lp (fx1+ i))))))
    (number! old-lines old-ids)
    (number! new-lines new-ids)))

;; Where each of LINES starts in their text, from 0, and the text's length
;; last.
(def (line-starts (lines : :vector)) => :vector
  (let* ((n (vector-length lines))
         (starts (make-vector (fx1+ n) 0)))
    (let lp ((i 0) (at 0))
      (vector-set! starts i at)
      (when (fx< i n)
        (lp (fx1+ i) (fx+ at (string-length (vector-ref lines i))))))
    starts))

(def (lines-string (lines : :vector) (start : :fixnum) (end : :fixnum)) => :string
  (let lp ((i (fx1- end)) (parts []))
    (if (fx< i start)
      (apply string-append parts)
      (lp (fx1- i) (cons (vector-ref lines i) parts)))))

;; The pairs (i . j) of A's and B's elements that a shortest edit script
;; keeps, in order (Myers 1986, "An O(ND) difference algorithm"), or #f
;; when that takes more than diff-work-limit steps.
(def (matching-lines (a : :vector) (b : :vector)) => (Maybe :list)
  (let* ((n (vector-length a))
         (m (vector-length b))
         (most (fx+ n m))
         (v (make-vector (fx+ (fx* 2 most) 3) 0))
         (at (lambda ((k : :fixnum)) (fx+ k most 1))))
    ;; TRACE holds, for each D, V's slice -D..D after step D, newest first.
    (let step ((d 0) (trace []) (work 0))
      (let diagonal ((k (fx- d)) (work work))
        (cond
         ((fx> work diff-work-limit) #f)
         ((fx> k d)
          (step (fx1+ d) (cons (subvector v (at (fx- d)) (fx1+ (at d))) trace) work))
         (else
          (let* ((x0 (if (or (fx= k (fx- d))
                             (and (fx< k d) (fx< (vector-ref v (at (fx1- k))) (vector-ref v (at (fx1+ k))))))
                       (vector-ref v (at (fx1+ k)))
                       (fx1+ (vector-ref v (at (fx1- k))))))
                 (x (let slide ((x x0))
                      (let (y (fx- x k))
                        (if (and (fx< x n) (fx< y m) (fx= (vector-ref a x) (vector-ref b y)))
                          (slide (fx1+ x))
                          x)))))
            (vector-set! v (at k) x)
            (if (and (fx>= x n) (fx>= (fx- x k) m))
              (backtrack a b (cons (subvector v (at (fx- d)) (fx1+ (at d))) trace) d)
              (diagonal (fx+ k 2) (fx+ work 1 (fx- x x0)))))))))))

;; Walk TRACE back from the end of A and B to the pairs kept.
(def (backtrack (a : :vector) (b : :vector) (trace : :list) (d : :fixnum)) => :list
  (let lp ((d d) (trace trace) (x (vector-length a)) (y (vector-length b)) (kept []))
    (let (diagonal (lambda ((stop-x : :fixnum) (kept : :list))
                     (let back ((x x) (y y) (kept kept))
                       (if (fx> x stop-x)
                         (back (fx1- x) (fx1- y) (cons (cons (fx1- x) (fx1- y)) kept))
                         kept))))
      (if (fx= d 0)
        (diagonal 0 kept)
        (let* ((previous (cadr trace))              ; V after step D-1: k from -(D-1)
               (ref (lambda ((k : :fixnum)) (vector-ref previous (fx+ k (fx1- d)))))
               (k (fx- x y))
               (from-k (if (or (fx= k (fx- d)) (and (fx< k d) (fx< (ref (fx1- k)) (ref (fx1+ k)))))
                         (fx1+ k)
                         (fx1- k)))
               (from-x (ref from-k))
               (from-y (fx- from-x from-k))
               ;; The step from (from-x, from-y) went down (an insertion)
               ;; or right (a deletion), then diagonally to (x, y).
               (start-x (if (fx= from-k (fx1+ k)) from-x (fx1+ from-x))))
          (lp (fx1- d) (cdr trace) from-x from-y (diagonal start-x kept)))))))
