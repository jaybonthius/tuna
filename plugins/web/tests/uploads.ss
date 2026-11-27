(import (tuna) (test) (test-runner) (web) (tables) (web-test http) (web-test tasks) (web-test handlers))

(web-test/http:use-url! (lambda () (web:url)))
(test-runner:wait-until (lambda () (web:url)))

(define p (web-test/http:page))

(define (upload name client body)
  (web-test/http:status
    (web-test/http:post (string-append "/upload/" name) (if client (list (cons "tuna-client" client)) '()) body)))

(define main (get-thread-id))

(define counted (box '()))

(define (taken!) (let ([l (reverse (unbox counted))]) (set-box! counted '()) l))

(tables:set! web:upload-handlers "count"
  (lambda (client bytes)
    (set-box! counted (cons (list client (bytevector-length bytes) (eqv? (get-thread-id) main)) (unbox counted)))))

(web-test/tasks:settle)

(test "an upload's handler gets the client its Tuna-Client header names and the body, off the main thread, and the upload gets 204 once it returns"
  (check-equal? '(204 204) (list (upload "count" (web-test/http:id p) (make-bytevector 6400 1)) (upload "count" (web-test/http:id p) #vu8())))
  (let ([uploads (taken!)])
    (check (for-all (lambda (u) (web:client? (car u))) uploads))
    (check (eq? (car (car uploads)) (car (cadr uploads))))
    (check-equal? '((6400 #f) (0 #f)) (map cdr uploads))))

(test "a name with no handler gets 404; an unknown client, or none, gets 204 and the body is dropped"
  (check-equal? '(404 404 404) (map (lambda (name) (upload name (web-test/http:id p) "x")) '("nothing" "count/more" "")))
  (check-equal? '(204 204) (list (upload "count" "nobody" "x") (upload "count" #f "x")))
  (check-equal? '() (taken!)))

(test "a handler runs as the module whose entry is in effect"
  (check-equal? 204 (upload "module-owner" (web-test/http:id p) "x"))
  (check-equal? (module-owner '(web-test handlers)) (web-test/handlers:upload-owner)))

(test "a handler that raises is reported as its module's, and the upload gets 500"
  (let ([reported (web-test/tasks:reports-during
                    (lambda () (check-equal? 500 (upload "module-fail" (web-test/http:id p) "x")))
                    1)])
    (check-equal? '(car "~s is not a pair") (list (condition-who (car reported)) (condition-message (car reported))))))

(test "an entry whose module has unloaded is no handler, also while the batch that unloads it lasts: 404, and nothing reported"
  (check-equal? '()
    (web-test/tasks:reports-during
      (lambda ()
        (check-equal? 404
          (begin
            (unload-owner! (module-owner '(web-test handlers)))
            (web-test/http:status
              (web-test/http:post-in-batch "/upload/module-owner" (list (cons "tuna-client" (web-test/http:id p))) "x"))))
        (check-equal? 404 (upload "module-owner" (web-test/http:id p) "x"))))))

(test "a removed client's uploads are dropped"
  (check-equal? 204 (web-test/http:goodbye! p))
  (check-equal? 204 (upload "count" (web-test/http:id p) "x"))
  (check-equal? '() (taken!)))

(define (refusals-of thunk)
  (map (lambda (c) (list (condition-who c) (condition-message c) (condition-irritants c)))
       (web-test/tasks:reports-during thunk)))

(test "an entry whose name is not 1 to 64 letters, digits and hyphens, or whose value is no procedure, is reported once and serves nothing"
  (check-equal? '((web:upload-handlers "not 1 to 64 letters, digits and hyphens" ("bad name")))
    (refusals-of (lambda () (tables:set! web:upload-handlers "bad name" (lambda (client bytes) (void))))))
  (check-equal? '((web:upload-handlers "not a procedure" (symbol)))
    (refusals-of (lambda () (tables:set! web:upload-handlers "not-one" 'symbol))))
  (check-equal? '() (refusals-of (lambda () (tables:set! web:upload-handlers "count" (lambda (client bytes) (void))))))
  (check-equal? 404 (upload "not-one" (web-test/http:id (web-test/http:page)) "x")))
