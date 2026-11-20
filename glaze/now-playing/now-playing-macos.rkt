#lang racket/base

;; macOS host-owned Now Playing backend (glaze#153): public
;; MediaPlayer.framework only — MPNowPlayingInfoCenter publication and
;; MPRemoteCommandCenter handlers. No private MediaRemote API (it drifts
;; across macOS releases and returns nothing on macOS 26 CI runners).
;;
;; Command callbacks arrive on the AppKit run loop; glaze's macOS pump
;; services it, so handlers run on the pump thread.

(require ffi/unsafe
         ffi/unsafe/objc
         glaze/ffi-discovery)

(provide supported? publish! os-info set-handler!)

;; Compile-time class binding for the ObjC subclass superclass; the
;; MediaPlayer classes below stay runtime-guarded so a missing framework
;; degrades to supported? = #f instead of a load-time crash.
(import-class NSObject)

(define mediaplayer
  (ffi-lib* "/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer" '(#f)))
(define foundation
  (ffi-lib* "/System/Library/Frameworks/Foundation.framework/Foundation" '(#f)))

(define (class name)
  (and mediaplayer foundation
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (objc-get-class name))))

(define center-class (class "MPNowPlayingInfoCenter"))
(define command-center-class (class "MPRemoteCommandCenter"))
(define dict-class (class "NSMutableDictionary"))
(define number-class (class "NSNumber"))
(define string-class (class "NSString"))

(define (supported?)
  (and center-class command-center-class dict-class number-class string-class #t))

(define state-box (box #f))
(define handler-box (box #f))

;; Public constant values from MPMediaItem.h / MPNowPlayingInfo.h.
(define key-title "title")
(define key-artist "artist")
(define key-album "albumTitle")
(define key-duration "playbackDuration")
(define key-elapsed "elapsedPlaybackTime")
(define key-rate "playbackRate")

(define (nsstring s)
  (tell (tell string-class alloc) initWithUTF8String: #:type _string s))

(define (nsnumber n)
  (tell number-class numberWithDouble: #:type _double n))

(define (center)
  (tell center-class defaultCenter))

(define (command-center)
  (tell command-center-class sharedCommandCenter))

;; One ObjC target; glazeCommand: distinguishes commands by sender identity.
(define command-table (make-hash)) ; command pointer -> symbol

(define-objc-class GlazeNowPlayingTarget
  NSObject
  ()
  (- _void
     (glazeCommand: [_id sender])
     ;; sender is an MPRemoteCommandEvent; the command object is its
     ;; `command` property, which is what the table is keyed by.
     (define cmd (hash-ref command-table (tell #:type _id sender command) #f))
     (define handler (unbox handler-box))
     (when (and cmd handler)
       (handler cmd #f))))

(define target #f)
(define (ensure-target!)
  (unless target
    (set! target (tell (tell GlazeNowPlayingTarget alloc) init))
    (define cc (command-center))
    (for ([pair (in-list (list (cons 'play (tell cc playCommand))
                             (cons 'pause (tell cc pauseCommand))
                             (cons 'stop (tell cc stopCommand))
                             (cons 'toggle (tell cc togglePlayPauseCommand))
                             (cons 'next (tell cc nextTrackCommand))
                             (cons 'previous (tell cc previousTrackCommand))))])
      (hash-set! command-table (cdr pair) (car pair))
      (tellv (cdr pair) addTarget: #:type _id target
             action: #:type _SEL (selector glazeCommand:)))))

(define (publish! info handler)
  (set-box! handler-box handler)
  (set-box! state-box info)
  (when (supported?)
    (ensure-target!)
    (cond
      [info
       (define d (tell (tell dict-class alloc) init))
       (tellv d setObject: #:type _id (nsstring (hash-ref info 'title ""))
              forKey: #:type _id (nsstring key-title))
       (tellv d setObject: #:type _id (nsstring (hash-ref info 'artist ""))
              forKey: #:type _id (nsstring key-artist))
       (tellv d setObject: #:type _id (nsstring (hash-ref info 'album ""))
              forKey: #:type _id (nsstring key-album))
       (tellv d setObject: #:type _id (nsnumber (hash-ref info 'duration 0.0))
              forKey: #:type _id (nsstring key-duration))
       (tellv d setObject: #:type _id (nsnumber (hash-ref info 'position 0.0))
              forKey: #:type _id (nsstring key-elapsed))
       (tellv d setObject: #:type _id (nsnumber (if (hash-ref info 'playing #f) 1.0 0.0))
              forKey: #:type _id (nsstring key-rate))
       (tellv (center) setNowPlayingInfo: #:type _id d)]
      [else
       (tellv (center) setNowPlayingInfo: #:type _id #f)])))

(define (set-handler! proc)
  (set-box! handler-box proc)
  (when (and proc (supported?)) (ensure-target!)))

(define (ns->string v)
  (and v (tell #:type _string v UTF8String)))

(define (ns->double v)
  (and v (tell #:type _double v doubleValue)))

;; Read back what the OS Now Playing center carries for this process.
(define (os-info)
  (and (supported?)
       (let ()
         (define d (tell (center) nowPlayingInfo))
         (and d
              (let ()
                (define (get key) (tell d objectForKey: #:type _id (nsstring key)))
                (define rate (ns->double (get key-rate)))
                (hash 'title (or (ns->string (get key-title)) "")
                      'artist (or (ns->string (get key-artist)) "")
                      'duration (or (ns->double (get key-duration)) 0.0)
                      'position (or (ns->double (get key-elapsed)) 0.0)
                      'playing (and rate (> rate 0.0) #t)))))))