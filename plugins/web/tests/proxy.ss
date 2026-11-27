(import (tuna) (test) (test-runner) (web) (options) (web-test http))

(web-test/http:use-url! (lambda () (web:url)))
(test-runner:wait-until (lambda () (web:url)))

(define (status . headers) (web-test/http:status (web-test/http:get "/web/tuna.js" headers)))

;; The test's client binds 127.0.0.2 to be a peer other than 127.0.0.1.
(define (from-proxy thunk) (web-test/http:from-address "127.0.0.2" thunk))

(define (on-other-address thunk)
  (guard (e [(error? e) (condition-message e)]) (web-test/http:to-address "127.0.0.2" thunk)))

(define (write-secret! name text mode)
  (let ([path (string-append (getenv "HOME") "/" name)])
    (call-with-output-file path (lambda (p) (display text p)) 'replace)
    (chmod path mode)))

(define right '("tuna-proxy-secret" . "0123456789abcdef-secret"))

(define (described c)
  (list (condition-who c) (condition-message c) (if (irritants-condition? c) (condition-irritants c) '())))

;; A changed setting restarts the server in a task of web's, which runs
;; before the wait for the batch.
(define (reports-setting! . settings)
  (map described (test-runner:reports-during (lambda () (apply options:set! settings) (test-runner:wait-for-batch)))))

(write-secret! "proxy-secret" "0123456789abcdef-secret\n" #o600)

(test "a request from a peer other than 127.0.0.1 needs the proxy's secret, and one from 127.0.0.1 does not"
  (check-equal? '(200 200 403) (list (status) (status '("tuna-proxy-secret" . "wrong")) (from-proxy status))))

(test "without a secret file, a second address is not listened on, with a warning"
  (check-equal? '((web:listen-also "web:proxy-secret-file is not set, so only 127.0.0.1 is listened on" ()))
                (reports-setting! web:listen-also "127.0.0.2"))
  (check-equal? "cannot connect" (on-other-address status)))

(test "with a secret file, the proxy's secret, exactly, lets its requests through, on either address"
  (check-equal? '() (reports-setting! web:proxy-secret-file "~/proxy-secret"))
  (check-equal? '(403 403 200 403 403)
    (from-proxy
      (lambda ()
        (list (status) (status '("tuna-proxy-secret" . "wrong")) (status right)
              (status '("tuna-proxy-secret" . "0123456789abcdef-secre"))
              (status '("tuna-proxy-secret" . "0123456789abcdef-secrets"))))))
  (check-equal? '(403 200) (on-other-address (lambda () (from-proxy (lambda () (list (status) (status right))))))))

(test "the secret does not replace the Host and Origin checks; the proxy's name is one of web:hosts"
  (options:set! web:hosts '("tuna.example.org"))
  (check-equal? '(200 403 403)
    (from-proxy
      (lambda ()
        (list (status right '("host" . "tuna.example.org") '("origin" . "https://tuna.example.org"))
              (status right '("host" . "evil.example"))
              (status right '("host" . "tuna.example.org") '("origin" . "https://evil.example")))))))

(test "a secret file that others can open, that is short or that is missing is reported, never with its text, and only 127.0.0.1 is listened on"
  (write-secret! "open-secret" "0123456789abcdef-secret\n" #o644)
  (check-equal? '((web:proxy-secret-file "other users can open the file; make its mode 600" ("~/open-secret")))
                (reports-setting! web:proxy-secret-file "~/open-secret"))
  (check-equal? 403 (from-proxy (lambda () (status right))))
  (check-equal? "cannot connect" (on-other-address status))
  (write-secret! "short-secret" "short\n" #o600)
  (check-equal? '((web:proxy-secret-file "the secret is shorter than 16 characters" ("~/short-secret")))
                (reports-setting! web:proxy-secret-file "~/short-secret"))
  (check-equal? '((web:proxy-secret-file "cannot read the file" ("~/no-secret")))
                (reports-setting! web:proxy-secret-file "~/no-secret")))

(test "the secret file's path is absolute or starts with ~/, and the address is a string"
  (let ([refused-value? (lambda (c) (and (who-condition? c) (eq? 'options:set! (condition-who c))))])
    (check-raises refused-value? (options:set! web:proxy-secret-file "proxy-secret"))
    (check-raises refused-value? (options:set! web:proxy-secret-file "~nobody/proxy-secret"))
    (check-raises refused-value? (options:set! web:listen-also 'here))))

(test "an address that cannot be listened on is reported, and Tuna listens on 127.0.0.1 alone"
  (let ([reported (reports-setting! web:proxy-secret-file "~/proxy-secret" web:listen-also "192.0.2.1")])
    (check-equal? 1 (length reported))
    (check-equal? "192.0.2.1" (car (caddr (car reported)))))
  (check-equal? '(200 200) (list (status) (from-proxy (lambda () (status right '("host" . "tuna.example.org")))))))
