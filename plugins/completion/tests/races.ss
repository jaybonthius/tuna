(import (tuna) (test) (test-user) (test-runner) (jobs) (buffers) (minibuffer) (completion) (editing) (completion-test sessions) (minibuffer-test reading))

(load-module! '(completion-list))

(define items (list->vector (map (lambda (i) (format "item-~a" i)) (iota 20000))))

(define (contains? text piece)
  (let loop ([i 0])
    (and (<= (+ i (string-length piece)) (string-length text))
         (or (string=? (substring text i (+ i (string-length piece))) piece) (loop (+ i 1))))))

(define (completions-buffers)
  (filter (lambda (name) (contains? name "*Completions")) (map buffers:name (buffers:all))))

(define (quit! r)
  (test-user:press! "C-g")
  (check-raises cancelled? (minibuffer-test/reading:result r)))

(test "keys typed faster than a job matches keep only the newest input's matches, exactly those of the final input"
  (let* ([r (minibuffer-test/reading:start! (lambda () (completion:read "Item: " (list (completion:source (candidates items) (styles (list completion:substring)))) #f)))]
         [s (completion-test/sessions:session)])
    (test-user:type! "1234")
    (completion-test/sessions:wait-matches s)
    (check-equal? '("item-1234" "item-11234" "item-12340" "item-12341" "item-12342" "item-12343" "item-12344" "item-12345"
                    "item-12346" "item-12347" "item-12348" "item-12349")
      (completion-test/sessions:texts s))
    (test-user:press! "DEL DEL")
    (test-user:type! "99")
    (completion-test/sessions:wait-matches s)
    (check-equal? 12 (length (completion-test/sessions:texts s)))
    (check (for-all (lambda (text) (contains? text "1299")) (completion-test/sessions:texts s)))
    (quit! r)))

(jobs:define-worker (one-at-a-time n emit)
  (do ([i 0 (+ i 1)]) ((= i n)) (emit (vector (format "item-~a" i)))))

(test "a job that emits its candidates one at a time has every one matched, in order once it ends, while typing keeps the newest input's"
  (let* ([r (minibuffer-test/reading:start! (lambda () (completion:read "Item: " (list (completion:source (job one-at-a-time 5000) (styles (list completion:substring)))) #f)))]
         [s (completion-test/sessions:session)])
    (test-user:type! "49")
    (completion-test/sessions:wait-matches s)
    (let ([found (completion-test/sessions:texts s)])
      (check-equal? 199 (length found))
      (check-equal? '("item-49" "item-149" "item-249" "item-349") (list-head found 4))
      (check-equal? found
        (list-sort (lambda (a b) (or (< (string-length a) (string-length b)) (and (= (string-length a) (string-length b)) (string<? a b)))) found)))
    (test-user:press! "DEL DEL")
    (completion-test/sessions:wait-matches s)
    (check-equal? 5000 (length (completion-test/sessions:texts s)))
    (quit! r)))

(test "reloading completion during a read quits the read and drops its list, and a read after it works"
  (let ([r (minibuffer-test/reading:start! (lambda () (completion:read "Item: " (list (completion:source (candidates items))) #f)))])
    (test-user:type! "5")
    (check-equal? 1 (length (completions-buffers)))
    (reload-modules! '((completion)))
    (test-user:settle)
    (check-raises cancelled? (minibuffer-test/reading:result r))
    (check-equal? #f (minibuffer:current-prompt))
    (check-equal? '() (completions-buffers)))
  (let ([r (minibuffer-test/reading:start! (lambda () (completion:read "Item: " (list (completion:source (candidates (vector "a" "b")))) #f)))])
    (test-user:press! "RET")
    (check-equal? "a" (minibuffer-test/reading:result r))))

(test "unloading completion-list during a read takes its list away and leaves the read going; loading it again gives its keys back"
  (let ([r (minibuffer-test/reading:start! (lambda () (completion:read "Item: " (list (completion:source (candidates (vector "a" "b")))) #f)))])
    (check-equal? 1 (length (test-user:elements (test-user:screen) "completion-list")))
    (unload-owner! (module-owner '(completion-list)))
    (test-user:settle)
    (check-equal? '() (test-user:elements (test-user:screen) "completion-list"))
    (check-equal? '() (completions-buffers))
    (check-equal? 'waiting (minibuffer-test/reading:result r))
    (load-module! '(completion-list))
    (test-user:press! "C-n RET")
    (check-equal? "b" (minibuffer-test/reading:result r))))

(test "a storm of quits while reads over a job start, match and end leaves no session, prompt or list behind"
  (let* ([stop #f]
         [askers (map (lambda (i)
                        (spawn-task
                          (lambda (restore)
                            (let loop ([n 0])
                              (unless (or stop (= n 100))
                                (guard (c [(cancelled? c) #f])
                                  (completion:read "Storm: " (list (completion:source (candidates items))) #f))
                                (loop (+ n 1)))))))
                      (iota 3))]
         [drop-quits (lambda (next c) (unless (cancelled? c) (next c)))])
    (advice-add! report drop-quits)
    (let loop ([n 0])
      (unless (= n 200)
        (test-user:type! (string (string-ref "0123456789" (mod n 10))))
        (when (= (mod n 3) 0) (for-each (lambda (t) (cancel-task t)) askers))
        (loop (+ n 1))))
    (set! stop #t)
    (for-each (lambda (t) (cancel-task t)) askers)
    (test-runner:wait-until (lambda () (for-all (lambda (t) (eq? (task-state t) 'done)) askers)))
    (test-user:settle)
    (advice-remove! report drop-quits)
    (check-equal? #f (completion-test/sessions:session))
    (check-equal? #f (minibuffer:current-prompt))
    (check-equal? '() (completions-buffers))
    (check-equal? '() (test-user:elements (test-user:screen) "completion-list"))))
