(cl:defpackage :mgl-example-util
  (:use #:common-lisp #:mgl-util #:mgl-train #:mgl-bm #:mgl-bp)
  (:export #:*example-dir*
           #:time->string
           #:log-msg
           #:logging-trainer
           #:log-training-error
           #:log-training-period
           #:log-test-error
           #:log-test-period
           #:base-trainer
           #:training-counters-and-measurers
           #:prepend-name-to-counters
           #:tack-cross-entropy-softmax-error-on
           #:load-weights
           #:save-weights
           #:maximally-likely-node
           #:maximally-likely-in-cross-entropy-softmax-lump
           #:cross-entropy-softmax-max-likelihood-classification-error))

(cl:defpackage :mgl-example-spiral
  (:use #:common-lisp #:mgl-util #:mgl-train #:mgl-gd #:mgl-bm #:mgl-bp
        #:mgl-unroll #:mgl-example-util))

(cl:defpackage :mgl-example-mnist
  (:use #:common-lisp #:mgl-util #:mgl-train #:mgl-gd #:mgl-bm #:mgl-bp
        #:mgl-unroll #:mgl-example-util)
  (:export #:*mnist-dir*
           #:train-mnist))

(cl:defpackage #:mgl-example-movie-review
  (:use #:common-lisp #:mgl-util #:mgl-train #:mgl-gd #:mgl-bm #:mgl-bp
        #:mgl-unroll #:mgl-example-util))
