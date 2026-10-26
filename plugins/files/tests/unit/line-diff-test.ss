;;; The line diff that reloading uses: its edits turn the old text into the
;;; new one and touch only the lines that changed.
(import :std/test
        :tuna/plugins/files/line-diff)
(export line-diff-test)

;; OLD with EDITS applied, last first as text-edits returns them.
(def (apply-edits (old : :string) (edits : :list)) => :string
  (foldl (lambda ((e : text-edit) (s : :string))
           (string-append (substring s 0 (fx1- (text-edit-start e)))
                          (text-edit-replacement e)
                          (substring s (fx1- (text-edit-end e)) (string-length s))))
         old edits))

(def (edits-as-lists (old : :string) (new : :string)) => :list
  (map (lambda ((e : text-edit)) [(text-edit-start e) (text-edit-end e) (text-edit-replacement e)])
       (text-edits old new)))

(def (round-trips? (old : :string) (new : :string)) => :boolean
  (equal? (apply-edits old (text-edits old new)) new))

(def line-diff-test
  (test-suite "line diff"
    (test-case "the same text needs no edit"
      (check (text-edits "a\nb\n" "a\nb\n") => []))
    (test-case "one changed line is one edit of that line"
      (check (edits-as-lists "one\ntwo\nthree\n" "one\nTWO\nthree\n") => [[5 9 "TWO\n"]]))
    (test-case "changes far apart are separate edits, last first"
      (check (edits-as-lists "a\nb\nc\nd\ne\n" "A\nb\nc\nd\nE\n") => [[9 11 "E\n"] [1 3 "A\n"]]))
    (test-case "inserted and deleted lines"
      (check (edits-as-lists "a\nc\n" "a\nb\nc\n") => [[3 3 "b\n"]])
      (check (edits-as-lists "a\nb\nc\n" "a\nc\n") => [[3 5 ""]]))
    (test-case "edits turn the old text into the new"
      (for-each (lambda ((pair : :pair)) (check (round-trips? (car pair) (cdr pair)) => #t))
                [(cons "" "x\n") (cons "x\n" "") (cons "a" "b") (cons "a\nb" "a\nb\n")
                 (cons "a\nb\nc\nd\n" "d\nc\nb\na\n") (cons "x\ny\nx\ny\n" "y\nx\ny\nx\nz")
                 (cons "same\nline\nsame\n" "line\nsame\nline\n")]))))
