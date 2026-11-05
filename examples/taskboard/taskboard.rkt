#lang racket/base

;; Pure Taskboard domain.
;;
;; The route layer owns JSON decoding and the store; these functions are total
;; over a task list and return #f for invalid input so a handler can answer
;; 400 without exceptions. A task is a hash with:
;;
;;   'id      exact non-negative integer, unique within the list
;;   'title   trimmed non-empty string, at most max-title-length characters
;;   'done    boolean
;;   'created exact integer, seconds since the Unix epoch

(require racket/list
         racket/string)

(provide max-title-length
         empty-tasks
         task?
         task-list?
         task-add
         task-toggle
         task-remove
         task-clear-done
         task-stats)

(define max-title-length 120)

(define empty-tasks '())

(define (task? value)
  (and (hash? value)
       (exact-integer? (hash-ref value 'id #f))
       (>= (hash-ref value 'id #f) 0)
       (string? (hash-ref value 'title #f))
       (boolean? (hash-ref value 'done #f))
       (exact-integer? (hash-ref value 'created #f))))

(define (task-list? value)
  (and (list? value) (andmap task? value)))

(define (clean-title value)
  (and (string? value)
       (let ([trimmed (string-trim value)])
         (and (not (string=? trimmed "")) (<= (string-length trimmed) max-title-length) trimmed))))

(define (next-id tasks)
  (add1 (for/fold ([highest -1]) ([task (in-list tasks)])
          (max highest (hash-ref task 'id)))))

;; Returns the extended task list, or #f when the title or timestamp is
;; invalid. The new task is the last element.
(define (task-add tasks title created)
  (define cleaned (clean-title title))
  (and cleaned
       (exact-integer? created)
       (append tasks (list (hasheq 'id (next-id tasks) 'title cleaned 'done #f 'created created)))))

;; Unknown ids are left untouched; the caller decides whether that is an
;; error. Rebuilding the hash keeps every task in the same hash equality
;; class after JSON round-trips.
(define (task-toggle tasks id)
  (for/list ([task (in-list tasks)])
    (if (equal? (hash-ref task 'id) id)
        (hasheq 'id
                (hash-ref task 'id)
                'title
                (hash-ref task 'title)
                'done
                (not (hash-ref task 'done))
                'created
                (hash-ref task 'created))
        task)))

(define (task-remove tasks id)
  (for/list ([task (in-list tasks)]
             #:unless (equal? (hash-ref task 'id) id))
    task))

(define (task-clear-done tasks)
  (for/list ([task (in-list tasks)]
             #:unless (hash-ref task 'done))
    task))

(define (task-stats tasks)
  (define total (length tasks))
  (define done (count (lambda (task) (hash-ref task 'done)) tasks))
  (hasheq 'total total 'done done 'open (- total done)))
