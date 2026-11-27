(import (tuna) (test) (test-runner) (hooks) (tables) (buffers) (modes) (runs) (runs-test) (runs-test starter))

(define home runs-test:home)

(define ends '())

(hooks:add! runs:ended (lambda (b end) (set! ends (cons (list (buffers:name b) end (runs:status b)) ends))))

(define (taken-ends) (let ([e (reverse ends)]) (set! ends '()) e))

(define (shows? b text) (lambda () (string=? (runs-test:output b) text)))

(tables:define-table build-keymap)
(hooks:define-hook build-hook)
(modes:define-major-mode build (parent runs:mode) (keymap build-keymap) (hook build-hook))

(test "an own run stops when its owner unloads, ended stopped with its entries; the owner's next instance does the same"
  (let ([own (runs-test/starter:own!)])
    (test-runner:wait-until (shows? own "own\n"))
    (unload-owner! (module-owner '(runs-test starter)))
    (check-equal? '(stopped (("*own*" stopped stopped))) (list (runs:status own) (taken-ends))))
  (load-module! '(runs-test starter))
  (let ([own (runs-test/starter:own!)])
    (test-runner:wait-until (shows? own "own\n"))
    (unload-owner! (module-owner '(runs-test starter)))
    (check-equal? '(stopped (("*own*" stopped stopped))) (list (runs:status own) (taken-ends))))
  (load-module! '(runs-test starter)))

(test "the user's run goes on across a reload of the module that started it and of runs, and its output still arrives"
  (let ([users (runs-test/starter:users!)])
    (test-runner:wait-until (shows? users "users\n"))
    (reload-modules! '((runs-test starter)))
    (reload-modules! '((runs)))
    (check-equal? #f (runs:status users))
    (runs-test:touch! "go")
    (check-equal? 0 (runs-test:ended users))
    (check-equal? "users\nlater" (runs-test:output users)))
  (check-equal? '(("*users*" 0 0)) (taken-ends)))

(test "a renamed going run keeps its buffer across a reload of runs, and an ended one its command, status and g across a reload of processes"
  (let ([going (runs:start-for-user "*going*" "echo a; until [ -e went ]; do sleep 0.05; done; echo b" home)])
    (test-runner:wait-until (shows? going "a\n"))
    (buffers:rename! going "renamed going")
    (reload-modules! '((runs)))
    (check-equal? #f (runs:status going))
    (runs-test:touch! "went")
    (check-equal? 0 (runs-test:ended going))
    (check-equal? '("renamed going" "a\nb") (list (buffers:name going) (runs-test:output going)))
    (buffers:rename! going "renamed ended")
    (reload-modules! '((processes)))
    (check-equal? '("echo a; until [ -e went ]; do sleep 0.05; done; echo b" 0) (list (runs:command going) (runs:status going)))
    (check-equal? going (runs:run-again going))
    (check-equal? 0 (runs-test:ended going))
    (check-equal? "a\nb" (runs-test:output going)))
  (check-equal? '(("renamed going" 0 0) ("renamed ended" 0 0)) (taken-ends)))

(test "renamed while runs is off, a run keeps its buffer, and a plain buffer made under its old name stays plain"
  (let ([old (runs:start-for-user "*old*" "echo old" home)])
    (runs-test:ended old)
    (unload-owner! (module-owner '(runs)))
    (buffers:rename! old "*old, renamed*")
    (let ([plain (buffers:make "*old*" "plain\n")])
      (load-module! '(runs))
      (load-module! '(runs-test))
      (check-equal? '("echo old" #f "plain\n") (list (runs:command old) (runs:run-buffer? plain) (runs-test:text plain)))))
  (check-equal? '(("*old*" 0 0)) (taken-ends)))

(test "a reload of buffers makes a going run's buffer again, silent and in runs:mode, from the process's log, and the output goes on"
  (let ([going (runs:start-for-user "*log*" "echo a; until [ -e go-log ]; do sleep 0.05; done; echo b" home)])
    (test-runner:wait-until (shows? going "a\n"))
    (reload-modules! '((buffers)))
    (let ([again (buffers:find "*log*")])
      (check-equal? '(#f #f #t runs:mode) (list (buffers:live? going) (runs:status again) (buffers:silent? again) (modes:major-mode again)))
      (runs-test:touch! "go-log")
      (check-equal? 0 (runs-test:ended again))
      (check-equal? "a\nb" (runs-test:output again))))
  (taken-ends))

(test "after a reload of buffers an ended run's buffer holds its header, a line saying the output was lost, and its footer"
  (reload-modules! '((buffers)))
  (let ([after (buffers:find "*log*")])
    (check-equal? '("Run started at TIME in ~/" "" "echo a; until [ -e go-log ]; do sleep 0.05; done; echo b"
                    "Output lost when buffers reloaded" "" "Run finished at TIME, after S s")
                  (runs-test:lines after))
    (check-equal? '(0 "echo a; until [ -e go-log ]; do sleep 0.05; done; echo b") (list (runs:status after) (runs:command after)))))

(test "a run in a mode derived from runs:mode comes back in runs:mode, and g starts the next run in its own mode"
  (let ([built (runs:start-for-user "*build*" "echo built" home build)])
    (runs-test:ended built)
    (check-equal? build (modes:major-mode built))
    (reload-modules! '((buffers)))
    (let ([built (buffers:find "*build*")])
      (check-equal? 'runs:mode (modes:major-mode built))
      (check-equal? built (runs:run-again built))
      (runs-test:ended built)
      (check-equal? (list build "built") (list (modes:major-mode built) (runs-test:output built)))))
  (taken-ends))

(test "a buffer made again while a plain buffer holds its name takes the first free NAME<N>"
  (unload-owner! (module-owner '(runs)))
  (buffers:kill! (buffers:find "*build*"))
  (let ([plain (buffers:make "*build*" "plain\n")])
    (load-module! '(runs))
    (load-module! '(runs-test))
    (check-equal? '(#f "echo built") (list (runs:run-buffer? plain) (runs:command (buffers:find "*build*<2>"))))))


(test "a run whose buffer was killed while runs was off comes back with its header, the lost output's line and its footer"
  (let ([gone (runs:start-for-user "*gone*" "echo gone" home)])
    (runs-test:ended gone)
    (unload-owner! (module-owner '(runs)))
    (buffers:kill! gone)
    (load-module! '(runs))
    (load-module! '(runs-test))
    (let ([back (buffers:find "*gone*")])
      (check-equal? '("Run started at TIME in ~/" "" "echo gone" "Output lost when buffers reloaded" "" "Run finished at TIME, after S s")
                    (runs-test:lines back))
      (check-equal? '(0 "echo gone") (list (runs:status back) (runs:command back)))))
  (taken-ends))
