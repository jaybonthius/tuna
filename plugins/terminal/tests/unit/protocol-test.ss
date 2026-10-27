;;; The frames a terminal helper and the terminal plugin exchange.
(import :std/test
        :tuna/plugins/terminal/protocol)
(export protocol-test)

(def protocol-test
  (test-suite "tuna/plugins/terminal: protocol"
    (test-case "frames split anywhere arrive whole, in order"
      (let* ((bytes (u8vector-append (frame-bytes 'output (string->utf8 "hello"))
                                     (frame-bytes 'exit-ack)
                                     (frame-bytes 'input (string->utf8 "é\r"))))
             (reader (new-frame-reader))
             (frames (apply append (map (lambda (i) (frame-reader-feed! reader bytes i (+ i 1)))
                                        (iota (u8vector-length bytes))))))
        (check (map frame-type frames) => '(output exit-ack input))
        (check (map (lambda (f) (utf8->string (frame-payload f))) frames) => '("hello" "" "é\r"))))

    (test-case "payloads round-trip"
      (let (h (parse-helper-hello (helper-hello-payload (make-helper-hello protocol-version 70000 4242 132 43))))
        (check (list (helper-hello-version h) (helper-hello-helper-pid h) (helper-hello-child-pid h)
                     (helper-hello-columns h) (helper-hello-rows h))
               => [protocol-version 70000 4242 132 43]))
      (let (r (parse-resize (resize-payload (make-resize-request 100 30 9 18))))
        (check (list (resize-request-columns r) (resize-request-rows r)
                     (resize-request-cell-width r) (resize-request-cell-height r))
               => '(100 30 9 18)))
      (check (parse-resize (resize-payload (make-resize-request 0 30 9 18))) => #f)
      (check (parse-exit (exit-payload 130)) => 130)
      (check (parse-hello (hello-payload)) => protocol-version)
      (let (c (parse-colors (colors-payload (make-theme-colors #x102030 #f #xffffff (vector #x010203 #xa0b0c0)))))
        (check (list (theme-colors-foreground c) (theme-colors-background c) (theme-colors-cursor c)
                     (theme-colors-palette c))
               => [#x102030 #f #xffffff (vector #x010203 #xa0b0c0)]))
      (check (parse-colors (u8vector 1 0)) => #f))

    (test-case "a frame of no known type is refused"
      (check (with-catch (lambda (e) 'refused)
                         (lambda () (frame-reader-feed! (new-frame-reader) (u8vector 99 0 0 0 0))))
             => 'refused))))
