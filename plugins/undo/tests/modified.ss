(import (tuna) (test) (modes) (buffers) (document) (undo) (undo-test edits))

(test "undo restores the text buffers:document-at gives for the version"
  (let ([u (buffers:make "undone" "abc\n")])
    (undo-test/edits:run-in u undo-test/edits:insert 1 "x")
    (undo-test/edits:run-in u undo-test/edits:insert 3 "yz")
    (let ([then (document:text (buffers:document-at u 1))])
      (undo-test/edits:run-in u undo:undo 1)
      (check-equal? '("xabc\n" "xabc\n") (list then (undo-test/edits:text u)))))
  (undo-test/edits:take-said!))

(test "undo marks the buffer unmodified again when it reaches the state the buffer was unmodified at, and redo modified"
  (let ([m (buffers:make "flag" "\n")])
    (check-equal? '(#f 0) (list (buffers:modified? m) (buffers:save-stamp m)))
    (undo-test/edits:run-in m undo-test/edits:insert 1 "a")
    (undo-test/edits:run-in m undo-test/edits:insert 1 "b")
    (check-equal? '(#t (2 0 (0 #f) (1 0) (2 1))) (list (buffers:modified? m) (undo-test/edits:tree m)))
    (undo-test/edits:run-in m undo:undo 2)
    (check-equal? '("\n" #f) (list (undo-test/edits:text m) (buffers:modified? m)))
    (undo-test/edits:run-in m undo:redo 1)
    (check-equal? '("a\n" #t) (list (undo-test/edits:text m) (buffers:modified? m))))
  (undo-test/edits:take-said!))

(test "a mark at another state, as a save makes, makes that state the saved one; an edit after it, undone, comes back to it"
  (let ([m (buffers:make "saved" "\n")])
    (undo-test/edits:run-in m undo-test/edits:insert 1 "a")
    (buffers:set-modified! m #f)
    (check-equal? '(#f 1) (list (buffers:modified? m) (cadr (undo:history m))))
    (undo-test/edits:run-in m undo:undo 1)
    (check-equal? '("\n" #t 1) (list (undo-test/edits:text m) (buffers:modified? m) (cadr (undo:history m))))
    (undo-test/edits:run-in m undo:redo 1)
    (check-equal? '("a\n" #f) (list (undo-test/edits:text m) (buffers:modified? m)))
    (undo-test/edits:run-in m undo-test/edits:insert 1 "c")
    (undo-test/edits:run-in m undo:undo 1)
    (check-equal? '("a\n" #f) (list (undo-test/edits:text m) (buffers:modified? m))))
  (undo-test/edits:take-said!))

(test "marking the buffer modified moves the stamp off every version, so no state is saved until the next mark"
  (let ([m (buffers:make "marked" "\n")])
    (undo-test/edits:run-in m undo-test/edits:insert 1 "a")
    (buffers:set-modified! m #f)
    (buffers:set-modified! m #t)
    (check-equal? '(#t #f) (list (buffers:modified? m) (cadr (undo:history m))))
    (undo-test/edits:run-in m undo:undo 1)
    (undo-test/edits:run-in m undo:redo 1)
    (check (buffers:modified? m)))
  (undo-test/edits:take-said!))

(test "edits joined to a group a mark left open leave no saved state"
  (let ([m (buffers:make "open" "a\n")])
    (undo:with-edit-group m
      (buffers:replace! m 1 1 "x")
      (buffers:set-modified! m #f)
      (buffers:replace! m 1 1 "y"))
    (check-equal? '("yxa\n" #t #f) (list (undo-test/edits:text m) (buffers:modified? m) (cadr (undo:history m))))
    (check-raises (undo-test/edits:raised? 'buffers:set-modified! "not a buffer") (buffers:set-modified! 'm #f))))

(test "a buffer whose name starts with a space is silent: it keeps no history and stays unmodified, until its plugin makes it not silent"
  (let ([q (buffers:make " quiet" "\n")])
    (buffers:replace! q 1 1 "a")
    (check-equal? '(#t #f (0 0 (0 #f))) (list (buffers:silent? q) (buffers:modified? q) (undo-test/edits:tree q)))
    (check-equal? '((undo:undo "no further undo information")) (undo-test/edits:reports-during (lambda () (undo-test/edits:run-in q undo:undo 1))))
    (buffers:set-silent! q #f)
    (buffers:replace! q 1 1 "b")
    (undo-test/edits:run-in q undo:undo 1)
    (check-equal? '("a\n" #f) (list (undo-test/edits:text q) (buffers:modified? q))))
  (undo-test/edits:take-said!))

(test "a body that raises takes its edits back, and back at the unmodified state the buffer is unmodified again"
  (let ([c (buffers:make "cancelled" "\n")])
    (check-raises (undo-test/edits:raised? 'body "stops") (undo:with-edit-group c (buffers:replace! c 1 1 "a") (error 'body "stops")))
    (check-equal? '("\n" #f (0 0 (0 #f))) (list (undo-test/edits:text c) (buffers:modified? c) (undo-test/edits:tree c)))))

(test "silence is the buffer's own, so renaming it or setting its major mode keeps it"
  (let ([p (buffers:make " plain" "\n")])
    (buffers:rename! p "plain")
    (modes:set-major-mode modes:fundamental p)
    (buffers:replace! p 1 1 "b")
    (check-equal? '(#t #f (0 0 (0 #f))) (list (buffers:silent? p) (buffers:modified? p) (undo-test/edits:tree p)))))
