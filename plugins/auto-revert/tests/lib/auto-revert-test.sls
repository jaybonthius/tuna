#!tuna
;; files-test keeps the messages, which ask's own writer would report as
;; warnings.
(import (test-runner) (document) (buffers) (views) (layout) (modes) (files-test) (file-watch-test) (file-watch-test descriptors))

(define (text b) (document:text (buffers:document b)))

(define (wait-for-text b expected) (test-runner:wait-until (lambda () (equal? expected (text b)))))

(define (show! b)
  (let ([v (layout:selected-view)])
    (views:set-buffer! v b)
    v))

(define (lighters v) (map modes:lighter (filter modes:lighter (modes:active-minor-modes v))))

(define (inotify-watches) (apply + (file-watch-test/descriptors:inotify-watch-counts)))
