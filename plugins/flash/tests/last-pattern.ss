(import (tuna) (test) (test-user) (test-runner) (flash) (flash-test))

(define start "foo fob for\nbar |foo\nfox\nFoo\n")

(test "a jump that ends without reaching a target leaves no pattern for the jump's key to repeat"
  (flash-test:show! start)
  (flash-test:press! "C-c ; f o x DEL DEL")
  (check (flash-test:quitting! "C-g"))
  (flash-test:press! "C-c ; C-c ;")
  (check-equal? "Flash: " (flash-test:prompt))
  (check (flash-test:quitting! "C-g")))

(test "the jump's key, with nothing typed, repeats the pattern of the last jump that reached a target"
  (flash-test:show! start)
  (flash-test:press! "C-c ; f o a")
  (flash-test:press! "C-c ; C-c ;")
  (check-equal? "Flash [fo] (6): " (flash-test:prompt))
  (flash-test:press! "C-c ;")
  (check-equal? "Flash [fo] (6): " (flash-test:prompt))
  (check (flash-test:quitting! "C-g")))
