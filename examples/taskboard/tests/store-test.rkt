#lang racket/base

;; Persistence test for the Taskboard example: the same store API the app
;; uses, against a temporary directory instead of the user's data directory.

(require rackunit
         racket/file
         racket/list
         glaze/store
         "../taskboard.rkt")

(define root (make-temporary-file "taskboard-store-~a" 'directory))
(define store-path (build-path root "tasks.json"))
(define now 1730000000)

(define (open)
  (load-store store-path #:defaults (hasheq 'tasks '()) #:auto-save #f))

(dynamic-wind void
              (lambda ()
                (define first-store (open))
                (check-equal? (store-get first-store 'tasks '()) '())
                (check-equal? (store-count first-store) 1)

                (define tasks (task-add empty-tasks "Persist me" now))
                (store-set! first-store 'tasks tasks)
                (store-save! first-store)
                (store-close! first-store)
                (check-true (file-exists? store-path))

                ;; A fresh load reads the file rather than the in-memory box.
                (define second-store (open))
                (define loaded (store-get second-store 'tasks '()))
                (check-true (task-list? loaded))
                (check-equal? (map (lambda (task) (hash-ref task 'title)) loaded) '("Persist me"))
                (check-equal? (task-stats loaded) (hasheq 'total 1 'done 0 'open 1))

                ;; Mutations survive another close/open cycle.
                (store-set! second-store 'tasks (task-toggle loaded 0))
                (store-save! second-store)
                (store-close! second-store)

                (define third-store (open))
                (check-true (hash-ref (first (store-get third-store 'tasks '())) 'done))
                (store-close! third-store))
              (lambda ()
                (when (directory-exists? root)
                  (delete-directory/files root))))
