(import (test))

(test "a #!lang/chez library in lib/ is compiled into the cache with the language from Tuna's boot file"
  (check-equal? "tuna" (library-object-filename '(lang chez lang)))
  (check-equal? "Hello, Harpo!" ((eval 'greeting (environment '(hello))) "Harpo"))
  (check (file-exists? (string-append (getenv "HOME") "/.cache/tuna/lib/hello.so"))))
