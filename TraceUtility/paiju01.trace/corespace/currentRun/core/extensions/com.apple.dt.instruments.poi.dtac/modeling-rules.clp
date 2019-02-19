;;;
;;; Points/Regions of Interest modeler
;;;

;; 
;; Templates
;;

(deftemplate interval-kdebug-signpost-start
    (slot time (type INTEGER))
    (slot thread (type EXTERNAL-ADDRESS))
    (slot name (type STRING))
    (slot backtrace (type EXTERNAL-ADDRESS))
    (slot arg1 (type INTEGER))
    (slot arg2 (type INTEGER))
    (slot arg3 (type INTEGER))
    (slot arg4 (type INTEGER))
)

(deftemplate interval-kdebug-signpost-end
    (slot time (type INTEGER))
    (slot thread (type EXTERNAL-ADDRESS))
    (slot name (type STRING))
    (slot backtrace (type EXTERNAL-ADDRESS))
    (slot arg1 (type INTEGER))
    (slot arg2 (type INTEGER))
    (slot arg3 (type INTEGER))
    (slot arg4 (type INTEGER))
)

(deftemplate interval-kdebug-match
    (slot start (type FACT-ADDRESS))
    (slot end   (type FACT-ADDRESS))
)

(deftemplate signpost-concept-choice
    (slot time (type INTEGER) (default ?NONE))
    (slot thread (type EXTERNAL-ADDRESS) (default ?NONE))
    (slot concept (type STRING) (default ?NONE))
)

(deftemplate kdebug-arg-to-color
    (slot color (type STRING))
    (slot arg (type INTEGER))
)

(deftemplate kdebug-matching-rule
    (slot rule (type SYMBOL) (allowed-symbols code code-thread code-arg1) (default ?NONE))
)

(deftemplate colorize-by-arg4) 

(deftemplate default-signpost-concept
    (slot concept (type STRING) (default ?NONE))
)

;; Constants (MODELER)
(deffacts constants
    (kdebug-arg-to-color (color "Blue") (arg 0))
    (kdebug-arg-to-color (color "Green") (arg 1))
    (kdebug-arg-to-color (color "Purple") (arg 2))
    (kdebug-arg-to-color (color "Orange") (arg 3))
    (kdebug-arg-to-color (color "Red") (arg 4))
    (kdebug-arg-to-color (color "Blue2") (arg 5))
    (kdebug-arg-to-color (color "Green2") (arg 6))
    (kdebug-arg-to-color (color "Purple2") (arg 7))
    (kdebug-arg-to-color (color "Orange2") (arg 8))
    (kdebug-arg-to-color (color "Red2") (arg 9))
    (default-signpost-concept (concept "Signpost")) ;; gets retracted if we're colorizing
)

;; Configuration Establishment Rules (MODELER)
(defrule MODELER::find-my-match-rule
    (table-attribute (table-id ?output) (has kdebug-match-rule ?rule))
    (table (table-id ?output) (side append))
    =>
    (assert (kdebug-matching-rule (rule (switch ?rule (case 0 then code) (case 1 then code-arg1) (case 2 then code-thread) (default code)))))
)

(defrule MODELER::create-default-matching-rule
    (not (table-attribute (table-id ?output) (has kdebug-match-rule ?rule)))
    =>
    (assert (kdebug-matching-rule (rule code)))
)

(defrule MODELER::remove-default-concept-when-colorizing
    ?f <- (default-signpost-concept)
    (table-attribute (table-id ?output) (has colorize-by-arg4 1))
    =>
    (retract ?f)
    (assert (colorize-by-arg4))
)

(defrule MODELER::bad-modeler-config
    (kdebug-matching-rule (rule ?rule))
    (kdebug-matching-rule (rule ~?rule))
    =>
    (log-narrative "Modeler has output tables bound to it with different rules, which points to a problem in the binding rules.")
)

;; Matching Rules (MODELER)
(defrule MODELER::kdebug-signpost-started
    (kdebug-signpost (time ?t) (thread ?thread) (name ?name) (type "Start") (arg1 ?arg1) (arg2 ?arg2) (arg3 ?arg3) (arg4 ?arg4) (backtrace ?bt))
    =>
    (assert (open-layout-reservation (start ?t) (category kdebug-signpost)))
    (assert (interval-kdebug-signpost-start (time ?t) (thread ?thread) (name ?name) (arg1 ?arg1) (arg2 ?arg2) (arg3 ?arg3) (arg4 ?arg4) (backtrace ?bt)))
)

(defrule MODELER::kdebug-signpost-ended
    (kdebug-signpost (time ?t) (thread ?thread) (name ?name) (type "End") (arg1 ?arg1) (arg2 ?arg2) (arg3 ?arg3) (arg4 ?arg4) (backtrace ?bt))
    =>
    (assert (interval-kdebug-signpost-end (time ?t) (thread ?thread) (name ?name) (arg1 ?arg1) (arg2 ?arg2) (arg3 ?arg3) (arg4 ?arg4) (backtrace ?bt)))
)

(defrule MODELER::kdebug-match-rule
    ?s <- (interval-kdebug-signpost-start (time ?t1) (name ?name) (thread ?thread) (arg1 ?arg1))
    (or (and (kdebug-matching-rule (rule code)) ?e <- (interval-kdebug-signpost-end (time ?t2) (name ?name)))
        (and (kdebug-matching-rule (rule code-thread)) ?e <- (interval-kdebug-signpost-end (time ?t2) (name ?name) (thread ?thread))) 
        (and (kdebug-matching-rule (rule code-arg1)) ?e <- (interval-kdebug-signpost-end (time ?t2) (name ?name) (arg1 ?arg1)))
    )
    (test (< ?t1 ?t2)) 
    =>
    (assert (interval-kdebug-match (start ?s) (end ?e)))
)

;; Integrity Rules (MODELER)
(defrule MODELER::eliminate-ambiguous-matches
    (declare (salience 100)) ;; it's more important to get rid of these as we detect them so other rules don't try to use them
    ?current <- (interval-kdebug-signpost-start (time ?t1))  ;; for some fact at ?t1
    ?stale <- (interval-kdebug-signpost-start (time ?t2&:(< ?t2 ?t1))) ;; if there is another fact at ?t2 where ?t2 is earlier
    (interval-kdebug-match (start ?current) (end ?end))   ;; and they both match the same end fact
    (interval-kdebug-match (start ?stale) (end ?end))
    =>
    (retract ?stale) ;; this is actually a normal side effect of processing nested firing within a rule
)

(defrule MODELER::clean-up-pairs
    (declare (salience 100)) ;; it's more important to get rid of these as we detect them so other rules don't try to use them
    ?e <- (interval-kdebug-signpost-end (time ?end-time))
    (clock (trace-relative ?now))
    ?m <- (interval-kdebug-match (start ?s) (end ?e))
    (test (> ?now ?end-time))
    =>
    (retract ?m ?e ?s)
)

(defrule MODELER::clean-up-unpaired-ends
    (declare (salience 100)) ;; it's more important to get rid of these as we detect them so other rules don't try to use them
    ?e <- (interval-kdebug-signpost-end (time ?end-time))
    (clock (trace-relative ?now))
    (test (> ?now ?end-time))
    (not (interval-kdebug-match (end ?e)))
    =>
    (retract ?e)
)

(defrule MODELER::clean-up-old-kdebug-sp-reservations
    (declare (salience 100))
    ?f <- (layout-reservation (id ?layout) (category kdebug-signpost) (start ?start))
    (not (interval-kdebug-signpost-start (time ?start)))
    =>
    (assert (close-layout-reservation (id ?layout) (category kdebug-signpost) (start ?start)))
)

;; Concept Choice Rules (MODELER)
(defrule MODELER::pick-interval-concept
    (logical    (colorize-by-arg4)
                ?e <- (interval-kdebug-signpost-end (time ?t) (thread ?thread) (arg4 ?arg4))
    )
    (kdebug-arg-to-color (color ?color) (arg ?color-num&:(= ?color-num (mod ?arg4 10))))
    =>
    (assert (signpost-concept-choice (time ?t) (thread ?thread) (concept ?color)))
)

(defrule MODELER::pick-open-interval-concept
    (logical    (colorize-by-arg4)
                ?s <- (interval-kdebug-signpost-start (time ?t) (thread ?thread) (arg4 ?arg4))
                (not (interval-kdebug-match (start ?s)))
    )
    (kdebug-arg-to-color (color ?color) (arg ?color-num&:(= ?color-num (mod ?arg4 10))))
    =>
    (assert (signpost-concept-choice (time ?t) (thread ?thread) (concept ?color)))
)

(defrule MODELER::pick-point-concept
    (logical    (colorize-by-arg4)
                (kdebug-signpost (time ?t) (thread ?thread) (type "Point") (arg4 ?arg4))
    )
    (kdebug-arg-to-color (color ?color) (arg ?color-num&:(= ?color-num (mod ?arg4 10))))
    =>
    (assert (signpost-concept-choice (time ?t) (thread ?thread) (concept ?color)))
)

(defrule MODELER::default-concept
    (logical    (not (colorize-by-arg4))
                (or (interval-kdebug-signpost-start (time ?t) (thread ?thread))
                    (interval-kdebug-signpost-end (time ?t) (thread ?thread))
                    (kdebug-signpost (time ?t) (thread ?thread) (type "Point"))
                )
    )
    =>
    (assert (signpost-concept-choice (time ?t) (thread ?thread) (concept "Signpost")))
)

;; Rules (RECORDER)

(defrule RECORDER::record-layout-kdebug-point-signpost
    (kdebug-signpost (time ?t) (thread ?thread) (name ?name) (type "Point") (arg1 ?arg1) (arg2 ?arg2) (arg3 ?arg3) (arg4 ?arg4))
    
    (table-attribute (table-id ?output) (has schema global-poi-layout))
    (signpost-concept-choice (time ?t) (thread ?thread) (concept ?concept))
    =>
    (create-new-row ?output)

    (set-column time ?t)
    (set-column concept ?concept)
    (set-column kind "KDebug Signpost")
    (set-column-narrative detail "%XRSignpostNameTypeID% (%kdebug-arg% %kdebug-arg% %kdebug-arg% %kdebug-arg%)" ?name ?arg1 ?arg2 ?arg3 ?arg4)
)

(defrule RECORDER::record-narrative-kdebug-point-signpost
    (kdebug-signpost (time ?t) (thread ?thread) (name ?name) (type "Point") (arg1 ?arg1) (arg2 ?arg2) (arg3 ?arg3) (arg4 ?arg4) (backtrace ?bt))
    
    (table-attribute (table-id ?output) (has schema region-of-interest)) 
    =>
    (create-new-row ?output) 

    (set-column start ?t)
    (set-column duration 1)
    (set-column kind "KDebug Signpost")
    (set-column concept "Signpost")
    (set-column stack ?bt)
    (set-column-narrative narrative "%XRSignpostNameTypeID% (KDebug Point Signpost), emitted by %thread%, with arguments: (%kdebug-arg% %kdebug-arg% %kdebug-arg% %kdebug-arg%)" ?name ?thread ?arg1 ?arg2 ?arg3 ?arg4)
)

(defrule RECORDER::record-roi-layout-kdebug-signpost
    ?s <- (interval-kdebug-signpost-start (time ?start-time) (thread ?start-thread) (name ?name) (arg1 ?start-arg1) (arg2 ?start-arg2) (arg3 ?start-arg3) (arg4 ?start-arg4) (backtrace ?start-bt))
    (layout-reservation (start ?start-time) (id ?layout) (category kdebug-signpost))
    ?e <- (interval-kdebug-signpost-end (time ?end-time) (thread ?end-thread) (name ?name) (arg1 ?end-arg1) (arg2 ?end-arg2) (arg3 ?end-arg3) (arg4 ?end-arg4) (backtrace ?end-bt))
    (interval-kdebug-match (start ?s) (end ?e))
    (signpost-concept-choice (time ?end-time) (thread ?thread) (concept ?concept))

    (table-attribute (table-id ?output) (has schema global-roi-layout))
    =>
    (create-new-row ?output)

    (set-column start ?start-time)
    (set-column duration (- ?end-time ?start-time))
    (set-column layout ?layout)
    (set-column kind "KDebug Signpost")
    (set-column concept ?concept)
    (set-column-narrative detail "%XRSignpostNameTypeID% Start: (%kdebug-arg% %kdebug-arg% %kdebug-arg% %kdebug-arg%), End: (%kdebug-arg% %kdebug-arg% %kdebug-arg% %kdebug-arg%)" ?name ?start-arg1 ?start-arg2 ?start-arg3 ?start-arg4 ?end-arg1 ?end-arg2 ?end-arg3 ?end-arg4)
)

(defrule RECORDER::record-ended-roi-as-poi-layout
    ?e <- (interval-kdebug-signpost-end (time ?end-time) (thread ?end-thread) (name ?name) (arg1 ?end-arg1) (arg2 ?end-arg2) (arg3 ?end-arg3) (arg4 ?end-arg4) (backtrace ?end-bt))
    (not (interval-kdebug-match (end ?e)))

    (table-attribute (table-id ?output) (has schema global-poi-layout))
    (signpost-concept-choice (time ?end-time) (thread ?end-thread) (concept ?concept))
    =>
    (create-new-row ?output)

    (set-column time ?end-time)
    (set-column concept ?concept)
    (set-column kind "KDebug Signpost")
    (set-column-narrative detail "End of %XRSignpostNameTypeID% (%kdebug-arg% %kdebug-arg% %kdebug-arg% %kdebug-arg%)" ?name ?end-arg1 ?end-arg2 ?end-arg3 ?end-arg4)
)

(defrule RECORDER::record-roi-kdebug-interval-signpost
    ?s <- (interval-kdebug-signpost-start (time ?start-time) (thread ?start-thread) (name ?name) (arg1 ?start-arg1) (arg2 ?start-arg2) (arg3 ?start-arg3) (arg4 ?start-arg4) (backtrace ?start-bt))
    ?e <- (interval-kdebug-signpost-end (time ?end-time) (thread ?end-thread) (name ?name) (arg1 ?end-arg1) (arg2 ?end-arg2) (arg3 ?end-arg3) (arg4 ?end-arg4) (backtrace ?end-bt))
    (interval-kdebug-match (start ?s) (end ?e))

    (kdebug-matching-rule (rule ?rule))
    (table-attribute (table-id ?output) (has schema region-of-interest))
    =>
    (create-new-row ?output)

    (bind ?dur (- ?end-time ?start-time))
    (set-column start ?start-time)
    (set-column duration ?dur)
    (set-column kind "KDebug Signpost")
    (set-column concept "Signpost")
    (set-column stack ?start-bt)
    (switch ?rule 
        (case code-thread then (set-column-narrative narrative "%XRSignpostNameTypeID% Start: (%kdebug-arg% %kdebug-arg% %kdebug-arg% %kdebug-arg%), End: (%kdebug-arg% %kdebug-arg% %kdebug-arg% %kdebug-arg%)" ?name ?start-arg1 ?start-arg2 ?start-arg3 ?start-arg4 ?end-arg1 ?end-arg2 ?end-arg3 ?end-arg4))
        (default (set-column-narrative narrative "%XRSignpostNameTypeID% (KDebug Interval Signpost), started by %thread%, with arguments: (%kdebug-arg% %kdebug-arg% %kdebug-arg% %kdebug-arg%), ended %XRDurationWaitingTypeID% later by %thread%, with arguments: (%kdebug-arg% %kdebug-arg% %kdebug-arg% %kdebug-arg%)" ?name ?start-thread ?start-arg1 ?start-arg2 ?start-arg3 ?start-arg4 ?dur ?end-thread ?end-arg1 ?end-arg2 ?end-arg3 ?end-arg4))
    )
)

(defrule RECORDER::record-roi-kdebug-interval-signpost-with-no-start
    ?e <- (interval-kdebug-signpost-end (time ?end-time) (thread ?end-thread) (name ?name) (arg1 ?end-arg1) (arg2 ?end-arg2) (arg3 ?end-arg3) (arg4 ?end-arg4) (backtrace ?end-bt))
    (not (interval-kdebug-match (end ?e)))

    (kdebug-matching-rule (rule ?rule))
    (table-attribute (table-id ?output) (has schema region-of-interest))
    =>
    (create-new-row ?output)

    (bind ?dur ?end-time)
    (set-column start 0)
    (set-column duration ?dur)
    (set-column kind "KDebug Signpost")
    (set-column concept "Signpost")
    (set-column stack ?end-bt)
    (switch ?rule 
        (case code-thread then (set-column-narrative narrative "%XRSignpostNameTypeID% End: (%kdebug-arg% %kdebug-arg% %kdebug-arg% %kdebug-arg%).  The interval can not be logged as an interval because the start could not be determined." ?name ?end-arg1 ?end-arg2 ?end-arg3 ?end-arg4))
        (default (set-column-narrative narrative "%XRSignpostNameTypeID% (KDebug Interval Signpost) ended by %thread%, with arguments: (%kdebug-arg% %kdebug-arg% %kdebug-arg% %kdebug-arg%).  The interval can not be logged as an interval because the start could not be determined." ?name ?end-thread ?end-arg1 ?end-arg2 ?end-arg3 ?end-arg4))
    )
)

(defrule RECORDER::record-kdebug-interval-signpost
    ?s <- (interval-kdebug-signpost-start (time ?start-time) (thread ?start-thread) (name ?name) (arg1 ?start-arg1) (arg2 ?start-arg2) (arg3 ?start-arg3) (arg4 ?start-arg4) (backtrace ?start-bt))
    ?e <- (interval-kdebug-signpost-end (time ?end-time) (thread ?end-thread) (name ?name) (arg1 ?end-arg1) (arg2 ?end-arg2) (arg3 ?end-arg3) (arg4 ?end-arg4) (backtrace ?end-bt))
    (interval-kdebug-match (start ?s) (end ?e))

    (table-attribute (table-id ?output) (has schema kdebug-signpost-interval))
    =>
    (create-new-row ?output)

    (bind ?dur (- ?end-time ?start-time))
    (set-column start ?start-time)
    (set-column duration ?dur)
    (set-column process (process-from-thread ?start-thread)) ; start process == end process
    (set-column name ?name)
    (set-column start-thread ?start-thread)
    (set-column start-arg1 ?start-arg1)
    (set-column start-arg2 ?start-arg2)
    (set-column start-arg3 ?start-arg3)
    (set-column start-arg4 ?start-arg4)
    (set-column start-backtrace ?start-bt)
    (set-column end-thread ?end-thread)
    (set-column end-arg1 ?end-arg1)
    (set-column end-arg2 ?end-arg2)
    (set-column end-arg3 ?end-arg3)
    (set-column end-arg4 ?end-arg4)
    (set-column end-backtrace ?end-bt)
)

;; Speculation Rules (RECORDER)
(defrule RECORDER::speculate-on-open-intervals
    (speculate (event-horizon ?horizon))
    ?s <- (interval-kdebug-signpost-start (time ?time) (thread ?thread) (name ?name) (backtrace ?start-bt) 
                                          (arg1 ?start-arg1) (arg2 ?start-arg2) (arg3 ?start-arg3) (arg4 ?start-arg4))
    (not (interval-kdebug-match (start ?s)))

    (table-attribute (table-id ?output) (has schema kdebug-signpost-interval))
    =>
    (create-new-row ?output)

    (bind ?dur (- ?horizon ?time))
    (set-column start ?time)
    (set-column duration ?dur)
    (set-column process (process-from-thread ?thread)) ; start process == end process
    (set-column name ?name)
    (set-column start-thread ?thread)
    (set-column start-arg1 ?start-arg1)
    (set-column start-arg2 ?start-arg2)
    (set-column start-arg3 ?start-arg3)
    (set-column start-arg4 ?start-arg4)
    (set-column start-backtrace ?start-bt)
 )

(defrule RECORDER::speculate-narrative-on-open-intervals
    (speculate (event-horizon ?horizon))
    ?s <- (interval-kdebug-signpost-start (time ?start-time) (thread ?thread) (name ?name) (arg1 ?start-arg1) (arg2 ?start-arg2) (arg3 ?start-arg3) (arg4 ?start-arg4) (backtrace ?start-bt))
    (not (interval-kdebug-match (start ?s)))

    (table-attribute (table-id ?output) (has schema region-of-interest))
    =>
    (create-new-row ?output)
    (bind ?dur (- ?horizon ?start-time))

    (set-column start ?start-time)
    (set-column duration ?dur)
    (set-column kind "KDebug Signpost")
    (set-column concept "Signpost")
    (set-column stack ?start-bt)
    (set-column-narrative narrative "%XRSignpostNameTypeID% (KDebug Interval Signpost), started by %thread%, with arguments: (%kdebug-arg% %kdebug-arg% %kdebug-arg% %kdebug-arg%)" ?name ?thread ?start-arg1 ?start-arg2 ?start-arg3 ?start-arg4)
)

(defrule RECORDER::speculate-layout-kdebug-interval-signpost
    (speculate (event-horizon ?horizon))
    ?s <- (interval-kdebug-signpost-start (time ?start-time) (thread ?thread) (name ?name) (arg1 ?start-arg1) (arg2 ?start-arg2) (arg3 ?start-arg3) (arg4 ?start-arg4) (backtrace ?start-bt))
    (not (interval-kdebug-match (start ?s)))
    (layout-reservation (start ?start-time) (id ?layout) (category kdebug-signpost))
    (signpost-concept-choice (time ?end-time) (thread ?thread) (concept ?concept))

    (table-attribute (table-id ?output) (has schema global-roi-layout))
    =>
    (create-new-row ?output)

    (set-column start ?start-time)
    (set-column duration (- ?horizon ?start-time))
    (set-column layout ?layout)
    (set-column kind "KDebug Signpost")
    (set-column concept ?concept)
    (set-column-narrative detail "%XRSignpostNameTypeID% Start: (%kdebug-arg% %kdebug-arg% %kdebug-arg% %kdebug-arg%)" ?name ?start-arg1 ?start-arg2 ?start-arg3 ?start-arg4)
)
