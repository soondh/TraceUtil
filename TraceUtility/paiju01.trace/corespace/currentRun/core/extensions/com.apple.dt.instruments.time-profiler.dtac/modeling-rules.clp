;
; Template to keep track of previous backtraces, which is needed for PET mode handling
;
(deftemplate last-recorded-backtrace
    (slot thread (type EXTERNAL-ADDRESS) (default ?NONE))
    (slot backtrace (type EXTERNAL-ADDRESS) (default ?NONE))
)

;
; A recordable event, with fixed up backtraces and PET mode accounted for
;
(deftemplate recordable-sample
    (slot time (type INTEGER) (default ?NONE))
    (slot thread (type EXTERNAL-ADDRESS) (default ?NONE))
    (slot backtrace (type EXTERNAL-ADDRESS) (default ?NONE))
    (slot thread-state (type STRING) (default ?NONE))
    (slot core (type INTEGER) (default ?NONE))
    (slot weight (type INTEGER) (default ?NONE))
    (slot table-id (type INTEGER) (default ?NONE))
)


;;;
;;; MODELING RULES
;;;

; Create a normal record if we have all necessary pieces
(defrule MODELER::create-normal-sample
    (time-sample 
        (time ?time)
        (thread ?thread)
        (thread-state ?thread-state)
        (cp-kernel-callstack ?kern-cp-stack)
        (cp-user-callstack ?user-cp-stack&~sentinel) 
        (core-index ?core)
        (table-id ?input))
    (table-attribute (table-id ?output) (has schema time-profile))
    (thread-instance (instance ?thread) (pid ?pid&~0))  ; non-kernel pid
    (table-attribute (table-id ?output) (has target-pid ?pid|ALL))
    (table-attribute (table-id ?input) (has sample-rate-micro-seconds ?sample-rate))
    (fixed-cp-backtrace (cp-backtrace ?user-cp-stack) (backtrace ?user-stack))
    (fixed-cp-backtrace (cp-backtrace ?kern-cp-stack) (backtrace ?kern-stack))
    =>
    (assert (recordable-sample (time ?time) (thread ?thread) (backtrace (backtrace-cat ?kern-stack ?user-stack)) 
                               (thread-state ?thread-state) (core ?core) (weight (* ?sample-rate 1000)) (table-id ?output)))
)

(defrule MODELER::create-kernel-only-sample
    (time-sample 
        (time ?time)
        (thread ?thread)
        (thread-state ?thread-state)
        (cp-kernel-callstack ?kern-cp-stack&~sentinel)
        (cp-user-callstack sentinel)  ; kernel task samples can't have user callstack
        (core-index ?core)
        (table-id ?input))
    (table-attribute (table-id ?output) (has schema time-profile))
    (thread-instance (instance ?thread) (pid 0))  ; kernel pid
    (table-attribute (table-id ?output) (has target-pid 0|ALL))
    (table-attribute (table-id ?input) (has sample-rate-micro-seconds ?sample-rate))
    (fixed-cp-backtrace (cp-backtrace ?kern-cp-stack) (backtrace ?kern-stack))
    =>
    (assert (recordable-sample (time ?time) (thread ?thread) (backtrace (backtrace-cat ?kern-stack)) 
                               (thread-state ?thread-state) (core ?core) (weight (* ?sample-rate 1000)) (table-id ?output)))
)


; Synthesize a missing backtrace in PET mode by substituting in the last backtrace
(defrule MODELER::create-continuation-sample
    (time-sample 
        (time ?time)
        (thread ?thread)
        (thread-state ?thread-state)
        (cp-kernel-callstack sentinel)
        (cp-user-callstack sentinel)
        (core-index ?core)
        (table-id ?input))
    (table-attribute (table-id ?output) (has schema time-profile))
    (thread-instance (instance ?thread) (pid ?pid))    
    (table-attribute (table-id ?output) (has target-pid ?pid|ALL))    
    (table-attribute (table-id ?input) (has sample-rate-micro-seconds ?sample-rate))
    (table-attribute (table-id ?input) (has all-thread-states YES))
    (last-recorded-backtrace (thread ?thread) (backtrace ?last-stack))
    =>
    ;; (log-narrative "Synthesized an event for thread %thread%" ?thread)
    (assert (recordable-sample (time ?time) (thread ?thread) (backtrace ?last-stack) 
                               (thread-state ?thread-state) (core ?core) (weight (* ?sample-rate 1000)) (table-id ?output)))
)


; Record the last backtrace for this thread if we don't have a record
(defrule MODELER::set-last-backtrace
    (recordable-sample (thread ?thread) (backtrace ?stack))  ; if there is a recordable sample
    (table-attribute (table-id ?input) (has all-thread-states YES)) ; if we have at least one table bound that needs PET
    (table (table-id ?input) (side read)) ; and that bound table is on the input side
    =>
    (assert (last-recorded-backtrace (thread ?thread) (backtrace ?stack)))  ; assert the "last" record
)

; Retire an old obsolete last backtrace
(defrule MODELER::retire-last-backtrace
    (recordable-sample (thread ?thread) (backtrace ?stack))  ; if there is a recordable backtrace for a thread
    ?f <- (last-recorded-backtrace (thread ?thread) (backtrace ~?stack)) ; and there is an old record out there that doesn't match
    =>
    (retract ?f)  ; remove that old record that doesn't match because we must have a new one that does
)

;;;
;;; RECORDING RULES
;;;

(defrule RECORDER::record-profile-record
    ?f <- (recordable-sample
            (time ?time)
            (thread ?thread)
            (backtrace ?stack)        
            (thread-state ?thread-state)
            (core ?core)        
            (weight ?weight)
            (table-id ?output))
    =>
    (retract ?f)
    (create-new-row ?output)
    (set-column time ?time)
    (set-column weight ?weight) 
    (set-column thread ?thread)
    (set-column stack (engineering-type backtrace ?stack))
    (set-column thread-state ?thread-state)
    (set-column core ?core)
    (set-column process (process-from-thread ?thread))
)


