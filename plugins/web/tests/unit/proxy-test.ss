;;; The reverse-proxy boundary (ADR 10): loopback peers pass, others need
;;; the proxy secret.
(import :std/test
        :std/net/address
        :tuna/plugins/web/proxy)
(export proxy-test)

(def (secret-file (text : :string) (mode : :fixnum)) => :string
  (let (path (string-append "/tmp/tuna-proxy-secret-" (number->string (random-integer 1000000000))))
    (let (port (open-output-file [path: path permissions: mode]))
      (display text port)
      (close-port port))
    path))

(def proxy-test
  (test-suite "tuna/plugins/web: proxy boundary"
    (test-case "loopback peers are recognised; others are not"
      (check (loopback-peer? (string->address "inet4:127.0.0.1:5000")) => #t)
      (check (loopback-peer? (string->address "inet4:127.3.4.5:5000")) => #t)
      (check (loopback-peer? (string->address "inet6:::1:5000")) => #t)
      (check (loopback-peer? (string->address "inet4:172.23.0.5:5000")) => #f)
      (check (loopback-peer? (string->address "inet6:fe80::1:5000")) => #f)
      (check (loopback-peer? #f) => #f))
    (test-case "the secret must match exactly; no secret matches nothing"
      (let (secret (string->utf8 "correct horse battery"))
        (check (secret-matches? secret "correct horse battery") => #t)
        (check (secret-matches? secret "correct horse batterz") => #f)
        (check (secret-matches? secret "correct horse") => #f)
        (check (secret-matches? secret #f) => #f)
        (check (secret-matches? #f "correct horse battery") => #f)))
    (test-case "the secret file must be private and long enough; whitespace is trimmed"
      (let (good (secret-file "  0123456789abcdef0123\n" #o600))
        (check (read-proxy-secret good) => (string->utf8 "0123456789abcdef0123"))
        (delete-file good))
      (let (shared (secret-file "0123456789abcdef0123" #o644))
        (check-exception (read-proxy-secret shared) true)
        (delete-file shared))
      (let (short (secret-file "short" #o600))
        (check-exception (read-proxy-secret short) true)
        (delete-file short)))))
