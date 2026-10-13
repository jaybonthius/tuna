(import :std/test
        :tuna/services/text-store
        :tuna/plugins/rope
        "../test-support/string-text-store")
(export rope-test)

(def rope rope-text-store)
(def oracle string-text-store)

;; Pieces of inserted text: ASCII, newlines, accented letters, CJK, emoji.
(def pieces
  ["a" "bc" "\n" "é" "日本語" "😀" "x\ny" "\n\n" "🐟 tuna" "ñ\n😀\n"])

(def (random-text (n : :fixnum)) => :string
  (call-with-output-string ""
    (lambda (port)
      (let lp ((i 0))
        (when (< i n)
          (write-string (list-ref pieces (random-integer (length pieces))) port)
          (lp (+ i 1)))))))

;; 1 <= start <= end <= size + 1.
(def (random-range size)
  (let* ((a (+ 1 (random-integer (+ size 1))))
         (b (+ 1 (random-integer (+ size 1)))))
    (values (min a b) (max a b))))

(def (chunks store version start end)
  (call-with-output-string ""
    (lambda (port)
      (TextStore-for-each-chunk store version start end (cut write-string <> port)))))

;; Every query on the rope version R agrees with the string version S.
(def (check-agree r s)
  (let ((size (TextStore-size oracle s))
        (lines (TextStore-line-count oracle s)))
    (check (TextStore-size rope r) => size)
    (check (TextStore-line-count rope r) => lines)
    (check (TextStore-slice rope r 1 (+ size 1)) => (TextStore-slice oracle s 1 (+ size 1)))
    (check (rope-balanced? r) => #t)
    (let lp ((i 0))
      (when (< i 8)
        (let-values (((start end) (random-range size)))
          (check (TextStore-slice rope r start end) => (TextStore-slice oracle s start end))
          (check (chunks rope r start end) => (TextStore-slice oracle s start end))
          (check (TextStore-line-at rope r start) => (TextStore-line-at oracle s start)))
        (let (line (+ 1 (random-integer lines)))
          (check (TextStore-line-start rope r line) => (TextStore-line-start oracle s line)))
        (lp (+ i 1))))))

(def (random-edits seed initial-size steps)
  (random-source-pseudo-randomize! default-random-source seed 0)
  (let* ((initial (random-text initial-size))
         (r0 (TextStore-from-string rope initial))
         (s0 (TextStore-from-string oracle initial)))
    (check-agree r0 s0)
    (let lp ((i 0) (r r0) (s s0))
      (when (< i steps)
        (let-values (((start end) (random-range (TextStore-size oracle s))))
          ;; Mostly short local edits, sometimes large insertions.
          (let* ((text (random-text (if (zero? (random-integer 20)) 400 (random-integer 4))))
                 (r2 (TextStore-replace rope r start end text))
                 (s2 (TextStore-replace oracle s start end text)))
            (check-agree r2 s2)
            (lp (+ i 1) r2 s2)))))
    ;; Old versions are untouched by later edits.
    (check (TextStore-slice rope r0 1 (+ 1 (TextStore-size rope r0))) => initial)))

(def rope-test
  (test-suite "tuna/plugins/rope"
    (test-case "an empty rope has one empty line"
      (let (r (TextStore-from-string rope ""))
        (check (TextStore-size rope r) => 0)
        (check (TextStore-line-count rope r) => 1)
        (check (TextStore-line-at rope r 1) => 1)
        (check (TextStore-line-start rope r 1) => 1)
        (check (TextStore-slice rope r 1 1) => "")))

    (test-case "positions count characters from 1, not bytes"
      (let (r (TextStore-from-string rope "é😀\nb"))
        (check (TextStore-size rope r) => 4)
        (check (TextStore-slice rope r 2 3) => "😀")
        (check (TextStore-line-at rope r 3) => 1)
        (check (TextStore-line-at rope r 4) => 2)
        (check (TextStore-line-start rope r 2) => 4)
        (check (TextStore-slice rope (TextStore-replace rope r 2 3 "🐟🐟") 1 6) => "é🐟🐟\nb")))

    (test-case "random edits agree with the plain-string store"
      (for-each (lambda (seed) (random-edits seed 0 200)) [1 2 3])
      (for-each (lambda (seed) (random-edits seed 3000 200)) [4 5]))))
