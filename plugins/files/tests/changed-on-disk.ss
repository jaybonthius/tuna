(import (tuna) (test) (test-runner) (hooks) (options) (ask) (commands) (timers) (jobs) (document) (buffers) (files) (files-test))

(define (canceled-by who) (lambda (c) (and (files:canceled-condition? c) (eq? who (condition-who c)))))

(files-test:write-text! "~/notes.txt" "notes\n")
(files-test:write-text! "~/todo.txt" "todo\n")

(define notes (files:visit "~/notes.txt"))
(define todo (files:visit "~/todo.txt"))

(define (edit-both!)
  (buffers:replace! notes 1 1 "mine ")
  (buffers:replace! todo 1 1 "mine ")
  (files-test:write-text! "~/notes.txt" "theirs\n"))

(test "files:save-buffer called from code on a buffer whose file changed on disk asks yes or no, naming the file as files:abbreviated-path writes it; no raises files:&canceled and writes nothing"
  (edit-both!)
  (options:set! ask:yes-or-no-reader (files-test:answer #f))
  (check-raises (canceled-by 'files:save-buffer) (files:save-buffer notes))
  (check-equal? '("~/notes.txt changed on disk since it was read; save anyway? ") (files-test:questions))
  (check-equal? '("theirs\n" #t) (list (files-test:read-text "~/notes.txt") (buffers:modified? notes))))

(test "yes writes over the file and marks the buffer unmodified; the next save asks nothing"
  (options:set! ask:yes-or-no-reader (files-test:answer #t))
  (files:save-buffer notes)
  (check-equal? '("~/notes.txt changed on disk since it was read; save anyway? ") (files-test:questions))
  (check-equal? '("mine notes\n" #f) (list (files-test:read-text "~/notes.txt") (buffers:modified? notes)))
  (buffers:replace! notes 1 1 "+")
  (files:save-buffer notes)
  (check-equal? '() (files-test:questions)))

(test "C-x s answered y for two buffers, the first stale: it asks save anyway; no ends the command, so the second is not offered"
  (files:save-buffer notes)
  (edit-both!)
  (options:set! ask:y-or-n-reader (files-test:answer #t))
  (options:set! ask:yes-or-no-reader (files-test:answer #f))
  (check-raises (canceled-by 'files:save-buffer) (files:save-some-buffers (lambda (buffer) #t)))
  (check-equal? '("Save file ~/notes.txt? " "~/notes.txt changed on disk since it was read; save anyway? ") (files-test:questions))
  (check-equal? '(#t #t) (map buffers:modified? (list notes todo))))

(test "with yes, it saves the stale one and offers the rest"
  (options:set! ask:yes-or-no-reader (files-test:answer #t))
  (files:save-some-buffers (lambda (buffer) #t))
  (check-equal? '("Save file ~/notes.txt? " "~/notes.txt changed on disk since it was read; save anyway? " "Save file ~/todo.txt? ")
    (files-test:questions))
  (check-equal? '("mine +mine notes\n" "mine mine todo\n") (map files-test:read-text '("~/notes.txt" "~/todo.txt")))
  (options:unset! ask:y-or-n-reader ask:yes-or-no-reader))

(test "a timer's save asks too, since the question belongs to every save"
  (buffers:replace! notes 1 1 "timer ")
  (files-test:write-text! "~/notes.txt" "theirs again\n")
  (let ([asked #f])
    (options:set! ask:yes-or-no-reader (lambda (question) (set! asked question) #f))
    (timers:run-after 0 (lambda () (guard (c [(files:canceled-condition? c) #f]) (files:save-buffer notes))))
    (test-runner:wait-until (lambda () asked))
    (check-equal? "~/notes.txt changed on disk since it was read; save anyway? " asked)
    (options:unset! ask:yes-or-no-reader)))

(define before-saves 0)

(define (count-before-save buffer) (set! before-saves (+ before-saves 1)))

(test "the question comes before files:before-save: no runs no entry, yes runs each once"
  (files:revert-from-file notes)
  (hooks:add! files:before-save count-before-save)
  (buffers:replace! notes 1 1 "again ")
  (files-test:write-text! "~/notes.txt" "theirs, again\n")
  (options:set! ask:yes-or-no-reader (files-test:answer #f))
  (check-raises (canceled-by 'files:save-buffer) (files:save-buffer notes))
  (check-equal? 0 before-saves)
  (options:set! ask:yes-or-no-reader (files-test:answer #t))
  (files:save-buffer notes)
  (check-equal? 1 before-saves)
  (check-equal? (make-list 2 "~/notes.txt changed on disk since it was read; save anyway? ") (files-test:questions))
  (hooks:remove! files:before-save count-before-save))

(define held '())
(define writes 0)
(define reads 0)

;; The write's job runs, but what it reports is held, so its save stays
;; under way with the file written and its fingerprint not yet recorded.
(define (hold-write next worker input on-result . on-end)
  (cond
    [(and (pair? input) (pair? (cdr input)) (document? (cadr input)))
     (set! writes (+ writes 1))
     (next worker input
       (lambda (v) (set! held (append held (list (lambda () (on-result v))))))
       (lambda (ended) (set! held (append held (list (lambda () ((car on-end) ended)))))))]
    [else
     (when (and (list? input) (equal? input (list (files:path notes)))) (set! reads (+ reads 1)))
     (apply next worker input on-result on-end)]))

(test "a second save while the first one writes reads the file only once the first is recorded, and asks nothing about Tuna's own write"
  (files:revert-from-file notes)
  (buffers:replace! notes 1 1 "twice ")
  (options:set! ask:yes-or-no-reader (files-test:answer #t))
  (advice-add! jobs:start hold-write)
  (let ([first (spawn-task (lambda (restore) (files:save-buffer notes)))])
    (test-runner:wait-until (lambda () (= 2 (length held))))
    (let ([second (spawn-task (lambda (restore) (files:save-buffer notes)))])
      (test-runner:wait-until (lambda () (eq? 'paused (task-state second))))
      (check-equal? 1 reads)
      (for-each (lambda (release) (release)) held)
      (test-runner:join first)
      (test-runner:join second)))
  (advice-remove! jobs:start hold-write)
  (check-equal? '(() 1 #f) (list (files-test:questions) writes (buffers:modified? notes)))
  (check-equal? (files-test:text notes) (files-test:read-text "~/notes.txt"))
  (options:unset! ask:yes-or-no-reader))

(test "a save that waited for one under way asks nothing when that one left the buffer unmodified, even if another program has changed the file since"
  (set! held '())
  (set! writes 0)
  (buffers:replace! notes 1 1 "thrice ")
  (options:set! ask:yes-or-no-reader (files-test:answer #t))
  (advice-add! jobs:start hold-write)
  (let ([first (spawn-task (lambda (restore) (files:save-buffer notes)))])
    (test-runner:wait-until (lambda () (= 2 (length held))))
    (let ([second (spawn-task (lambda (restore) (files:save-buffer notes)))])
      (test-runner:wait-until (lambda () (eq? 'paused (task-state second))))
      (files-test:write-text! "~/notes.txt" "theirs, after the save\n")
      (for-each (lambda (release) (release)) held)
      (test-runner:join first)
      (test-runner:join second)))
  (advice-remove! jobs:start hold-write)
  (check-equal? '(() 1 #f) (list (files-test:questions) writes (buffers:modified? notes)))
  (check-equal? "theirs, after the save\n" (files-test:read-text "~/notes.txt"))
  (options:unset! ask:yes-or-no-reader))
