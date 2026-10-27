;;; What the echo area says for a notification, as ghostel-default-notify
;;; says it without the alert package.
(import :std/test
        :tuna/plugins/notifications/plugin)
(export text-test)

(def text-test
  (test-suite "tuna/plugins/notifications: the echo area's text"
    (test-case "the title, or the terminal's buffer when there is none, then the body"
      (check (notification-text "Build" "done" "*terminal*") => "Build: done")
      (check (notification-text "" "hello" "*terminal*") => "*terminal*: hello"))))
