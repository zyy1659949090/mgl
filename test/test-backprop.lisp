(in-package :mgl-test)

(defclass test-base-bp-optimizer ()
  ())

(defclass test-bp-optimizer (test-base-bp-optimizer segmented-gd-optimizer)
  ())

(defclass test-cg-bp-optimizer (test-base-bp-optimizer cg-optimizer)
  ())

(defclass test-bpn (bpn)
  ((clamper :initarg :clamper :accessor clamper)))

(defmethod set-input (samples (bpn test-bpn))
  (funcall (clamper bpn) samples bpn))

(defun make-bpn-cost-monitors ()
  (list
   (make-instance 'monitor
                  :measurer (lambda (instances bpn)
                              (declare (ignore instances))
                              (mgl-bp:cost bpn))
                  :counter (make-instance
                            'basic-counter
                            :attributes '(:dataset "train" :type "cost")))))

(defun make-bp-learner (bpn)
  (make-instance 'bp-learner
                 :bpn bpn
                 :monitors (make-bpn-cost-monitors)))

(defun monitor-training-periodically (optimizer)
  (monitor-optimization-periodically
   optimizer
   '((:fn reset-optimization-monitors :period 100 :last-eval 0))))

;; (test-simple :cg nil :max-n-stripes 10)

(defun bpn-error (sampler bpn)
  (let ((counter (make-instance 'basic-counter))
        (n-stripes (max-n-stripes bpn)))
    (while (not (finishedp sampler))
      (set-input (list-samples sampler n-stripes) bpn)
      (forward-bpn bpn)
      (multiple-value-call #'add-to-counter counter (cost bpn)))
    (values (counter-values counter) counter)))

(defun bpn-nodes (bpn stripe)
  (apply #'concatenate 'list
         (map 'list (lambda (lump)
                      (let ((size (size lump)))
                        (with-facets ((nodes ((nodes lump) 'backing-array
                                              :direction :input
                                              :type flt-vector)))
                          (subseq nodes
                                  (* stripe size) (* (1+ stripe) size)))))
              (lumps bpn))))

(defun bpn-derivatives (bpn stripe)
  (apply #'concatenate 'list
         (map 'list (lambda (lump)
                      (let ((size (size lump)))
                        (with-facets ((derivatives ((derivatives lump)
                                                    'backing-array
                                                    :direction :input
                                                    :type flt-vector)))
                          (subseq derivatives
                                  (* stripe size) (* (1+ stripe) size)))))
              (lumps bpn))))

(defun test-simple (&key cg (max-n-stripes 1))
  (let* ((net (build-bpn (:class 'test-bpn :max-n-stripes max-n-stripes)
                (weights (->weight :size 1))
                (inputs (->input :size 1))
                (my-linear (->linear :x inputs :y weights :size 1))
                (sse (->sum-squared-error :x inputs :y my-linear))
                (my-error (->error :x sse))))
         (nodes (map 'list #'nodes (lumps net))))
    (setf (n-stripes net) 1)
    (with-facets ((nodes-0 ((elt nodes 0) 'backing-array :direction :output
                            :type flt-vector))
                  (nodes-1 ((elt nodes 1) 'backing-array :direction :output
                            :type flt-vector)))
      (setf (aref nodes-0 0) #.(flt 2))
      (setf (aref nodes-1 0) #.(flt 3)))
    (forward-bpn net)
    (assert (every #'~= (bpn-nodes net 0) '(2 3 6 9)))
    (backward-bpn net)
    (assert (every #'~= (bpn-derivatives net 0) (list 18 (- 12 6) 6 1)))
    (flet ((sample ()
             (flt (random 5.0)))
           (clamper (samples bpn1)
             (assert (eq bpn1 net))
             (let* ((inputs (find-lump 'inputs bpn1))
                    (nodes (nodes inputs)))
               (with-facets ((nodes (nodes 'backing-array :direction :output
                                           :type flt-vector)))
                 (loop for sample in samples
                       for stripe upfrom 0
                       do
                          (with-stripes ((stripe inputs start))
                            (setf (aref nodes start) sample)))))))
      (setf (clamper net) #'clamper)
      (minimize (if cg
                    (make-instance 'test-cg-bp-optimizer
                                   :batch-size 100
                                   :on-cg-batch-done '(log-cg-batch-done))
                    (monitor-training-periodically
                     (make-instance 'test-bp-optimizer
                                    :segmenter
                                    (repeatedly
                                      (make-instance 'batch-gd-optimizer
                                                     :learning-rate (flt 0.01)
                                                     :momentum (flt 0.9)
                                                     :batch-size 10)))))
                (make-bp-learner net)
                :dataset
                (make-instance 'function-sampler
                               :max-n-samples 1000
                               :generator #'sample))
      (bpn-error (make-instance 'function-sampler
                                :max-n-samples 1000
                                :generator #'sample)
                 net))))

(defun test-softmax (&key cg (max-n-stripes 1))
  (let* ((net (build-bpn (:class 'test-bpn :max-n-stripes max-n-stripes)
                (inputs (->input :size 12))
                (weights (->weight :size (* 12 12)))
                (linear (->activation :weights weights :x inputs))
                (exp (->exp :x linear))
                (norm (->normalized :group-size 3 :x exp))
                (expectations (->input :size 12))
                (sse (->sum-squared-error :x norm :y expectations))
                (my-error (->error :x sse)))))
    (let* ((inputs (find-lump 'inputs net))
           (inputs-nodes (nodes inputs))
           (expectations (find-lump 'expectations net))
           (expectations-nodes (nodes expectations)))
      (flet ((sample ()
               (loop repeat 4
                     collect (loop repeat 3 collect (random (flt 5)))))
             (clamper (samples bpn1)
               (assert (eq bpn1 net))
               (with-facets ((inputs-nodes (inputs-nodes 'backing-array
                                                         :direction :output
                                                         :type flt-vector))
                             (expectations-nodes
                              (expectations-nodes 'backing-array
                                                  :direction :output
                                                  :type flt-vector)))
                 (loop
                   for sample in samples
                   for stripe upfrom 0
                   do (with-stripes ((stripe inputs input-start input-end)
                                     (stripe expectations
                                             expectations-start
                                             expectations-end))
                        (loop
                          for s in sample
                          for si upfrom 0 do
                            (let* ((expectations
                                     (make-array 12 :initial-element (flt 0)))
                                   (inputs
                                     (loop
                                       for i below 4
                                       append
                                       (let* ((s (elt sample i))
                                              (max (loop for x in s
                                                         maximizing x))
                                              (pos (position max s :test #'=)))
                                         (setf (aref expectations
                                                     (+ (* i 3) pos))
                                               (flt 1))
                                         s))))
                              (loop for i upfrom input-start below input-end
                                    for j upfrom 0
                                    do (setf (aref inputs-nodes i)
                                             (elt inputs j)))
                              (loop for i upfrom expectations-start
                                      below expectations-end
                                    for j upfrom 0
                                    do (setf (aref expectations-nodes i)
                                             (aref expectations j))))))))))
        (setf (clamper net) #'clamper)
        (minimize (if cg
                      (make-instance 'test-cg-bp-optimizer
                                     :cg-args '(:max-n-line-searches 3)
                                     :batch-size 100
                                     :on-cg-batch-done '(log-cg-batch-done))
                      (monitor-training-periodically
                       (make-instance 'test-bp-optimizer
                                      :segmenter
                                      (repeatedly
                                        ;; Small learning rate and huge decay
                                        ;; because the network is constructed in
                                        ;; such a way that pushes all weights up
                                        ;; towards infinity.
                                        (make-instance 'batch-gd-optimizer
                                                       :learning-rate (flt 0.01)
                                                       :momentum (flt 0.9)
                                                       :weight-decay (flt 0)
                                                       :batch-size 10)))))
                  (make-bp-learner net)
                  :dataset
                  (make-instance 'function-sampler
                                 :max-n-samples 100000
                                 :generator #'sample))
        (bpn-error (make-instance 'function-sampler
                                  :max-n-samples 1000
                                  :generator #'sample)
                   net)))))

(defun init-lump (name bpn deviation)
  (gaussian-random! (segment-weights (find-lump name bpn :errorp t))
                    :stddev deviation))

(defun test-cross-entropy (&key cg (max-n-stripes 1))
  (let* ((net (build-bpn (:class 'test-bpn :max-n-stripes max-n-stripes)
                (inputs (->input :size 3))
                (weights (->weight :size (* 3 3)))
                (linear (->activation :x inputs :weights weights))
                (expectations (->input :size 3))
                (output (->cross-entropy-softmax :group-size 3
                                                 :x linear
                                                 :target expectations))
                (my-error (->error :x output)))))
    (let* ((inputs (find-lump 'inputs net))
           (inputs-nodes (nodes inputs))
           (expectations (find-lump 'expectations net))
           (expectations-nodes (nodes expectations)))
      (flet ((sample ()
               (loop repeat 3 collect (random (flt 5))))
             (clamper (samples bpn1)
               (assert (eq bpn1 net))
               (with-facets ((inputs-nodes (inputs-nodes 'backing-array
                                                         :direction :output
                                                         :type flt-vector))
                             (expectations-nodes
                              (expectations-nodes 'backing-array
                                                  :direction :output
                                                  :type flt-vector)))
                 (loop
                   for sample in samples
                   for stripe upfrom 0
                   do (with-stripes ((stripe inputs inputs-start inputs-end)
                                     (stripe expectations
                                             expectations-start
                                             expectations-end))
                        (let* ((expectations
                                 (make-array 3 :initial-element (flt 0)))
                               (inputs (let* ((max (loop for x in sample
                                                         maximizing x))
                                              (pos (position max sample
                                                             :test #'=)))
                                         (setf (aref expectations pos) (flt 1))
                                         sample)))
                          (loop for i upfrom inputs-start below inputs-end
                                for j upfrom 0
                                do (setf (aref inputs-nodes i) (elt inputs j)))
                          (loop for i upfrom expectations-start
                                  below expectations-end
                                for j upfrom 0
                                do (setf (aref expectations-nodes i)
                                         (aref expectations j)))))))))
        (setf (clamper net) #'clamper)
        (init-lump 'weights net 0.01)
        (minimize (if cg
                      (make-instance 'test-cg-bp-optimizer
                                     :cg-args (list :max-n-line-searches 3)
                                     :batch-size 1000
                                     :on-cg-batch-done '(log-cg-batch-done))
                      (monitor-training-periodically
                       (make-instance 'test-bp-optimizer
                                      :segmenter
                                      (repeatedly
                                        (make-instance 'batch-gd-optimizer
                                                       :learning-rate (flt 0.1)
                                                       :momentum (flt 0.9)
                                                       :batch-size 100)))))
                  (make-bp-learner net)
                  :dataset
                  (make-instance 'function-sampler
                                 :max-n-samples 100000
                                 :generator #'sample))
        (bpn-error (make-instance 'function-sampler
                                  :max-n-samples 1000
                                  :generator #'sample)
                   net)))))

(defun lump-start (lump)
  (nth-value 1 (segment-weights lump)))

(defun lump-end (lump)
  (nth-value 2 (segment-weights lump)))

(defun test-activation (&key transposep cg (max-n-stripes 1))
  (let* ((net (build-bpn (:class 'test-bpn :max-n-stripes max-n-stripes)
                (inputs (->input :size 2))
                (biases (->weight :size 2))
                (biased-input (->+ :size 2 :args (list inputs biases)))
                (weights (->weight :size (* 3 2)))
                (activations (->activation :size 3
                                           :transpose-weights-p transposep
                                           :x biased-input
                                           :weights weights))
                (expectations (->input :size 3))
                (sse (->sum-squared-error :x expectations :y activations))
                (my-error (->error :x sse)))))
    ;; Set weights
    (let ((nodes (segment-weights (find-lump 'biases net))))
      (setf (row-major-mref nodes 0) (flt 2))
      (setf (row-major-mref nodes 1) (flt 3)))
    (let ((inputs (segment-weights (find-lump 'weights net))))
      (with-shape-and-displacement (inputs (mat-size inputs))
        (replace! inputs (if transposep
                             (mapcar #'flt '(0 1 2 3 4 5))
                             (mapcar #'flt '(0 2 4 1 3 5))))))
    ;; Clamp input
    (let ((nodes (segment-weights (find-lump 'inputs net))))
      (setf (row-major-mref nodes 0) (flt -1))
      (setf (row-major-mref nodes 1) (flt -4)))
    ;; Check foward pass
    (forward-bpn net)
    (assert (every #'= (bpn-nodes net 0)
                   (if transposep
                       #(-1 -4 2 3 1 -1 0 1 2 3 4 5 -1 -1 -1 0 0 0 3 3)
                       #(-1 -4 2 3 1 -1 0 2 4 1 3 5 -1 -1 -1 0 0 0 3 3))))
    ;; Check backward pass
    (backward-bpn net)
    (assert
     (every #'= (bpn-derivatives net 0)
            (if transposep
                #(-12 -18 -12 -18 -12 -18 -2 2 -2 2 -2 2 -2 -2 -2 2 2 2 1 1)
                #(-12 -18 -12 -18 -12 -18 -2 -2 -2 2 2 2 -2 -2 -2 2 2 2 1 1))))
    ;; Train. Error typically goes down to 0.0025 - 0.005
    (init-lump 'biases net 0.01)
    (init-lump 'weights net 0.01)
    (let* ((inputs (find-lump 'inputs net))
           (input-nodes (nodes inputs))
           (expectations (find-lump 'expectations net))
           (expectations-nodes (nodes expectations)))
      (flet ((sample ()
               (list (random (flt 1)) (random (flt 1))))
             (clamper (samples bpn1)
               (assert (eq bpn1 net))
               (with-facets ((input-nodes
                              (input-nodes 'backing-array
                                           :direction :output
                                           :type flt-vector))
                             (expectations-nodes
                              (expectations-nodes 'backing-array
                                                  :direction :output
                                                  :type flt-vector)))
                 (loop for sample in samples
                       for stripe upfrom 0
                       do (with-stripes ((stripe inputs input-start)
                                         (stripe expectations
                                                 expectations-start))
                            (destructuring-bind (x y) sample
                              (setf (aref input-nodes input-start) x)
                              (setf (aref input-nodes (1+ input-start)) y)
                              (setf (aref expectations-nodes expectations-start)
                                    (+ (* 3 (+ x 2))
                                       (* 2 (+ y -1))))
                              (setf (aref expectations-nodes
                                          (1+ expectations-start))
                                    (+ (* -3 (+ x 2))
                                       (* -2 (+ y -1))))
                              (setf (aref expectations-nodes
                                          (+ 2 expectations-start))
                                    (+ (* -0.8 (+ x 2))
                                       (* 1.3 (+ y -1))))))))))
        (setf (clamper net) #'clamper)
        (minimize (if cg
                      (make-instance 'test-cg-bp-optimizer
                                     :cg-args '(:max-n-line-searches 3)
                                     :batch-size 1000
                                     :on-cg-batch-done '(log-cg-batch-done))
                      (monitor-training-periodically
                       (make-instance 'test-bp-optimizer
                                      :segmenter
                                      (repeatedly
                                        (make-instance 'batch-gd-optimizer
                                                       :learning-rate (flt 0.01)
                                                       :momentum (flt 0.9)
                                                       :batch-size 10)))))
                  (make-bp-learner net)
                  :dataset
                  (make-instance 'function-sampler
                                 :max-n-samples (if cg 30000 100000)
                                 :generator #'sample))
        (bpn-error (make-instance 'function-sampler
                                  :max-n-samples 1000
                                  :generator #'sample)
                   net)))))

(defun test-bp ()
  (declare (optimize (debug 3)))
  (do-cuda ()
    (dolist (max-n-stripes '(10 100))
      (dolist (cg '(nil t))
        (log-msg "max-n-stripes: ~S, cg: ~S~%" max-n-stripes cg)
        (assert (> 0.01 (test-simple :cg cg :max-n-stripes max-n-stripes)))
        (dolist (transposep '(nil t))
          (assert (> 0.01 (test-activation :transposep transposep :cg cg
                                           :max-n-stripes max-n-stripes))))
        (assert (> 0.3 (test-softmax :cg cg :max-n-stripes max-n-stripes)))
        (assert (> 0.1 (test-cross-entropy :cg cg
                                           :max-n-stripes max-n-stripes)))))))
