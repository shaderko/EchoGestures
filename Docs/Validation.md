# Validation boundary

The current source passes 277 synthetic core checks on the development Mac. Optimized app packaging, strict code-signature verification, and SwiftPM debug builds pass locally. A fresh-checkout build is part of publication verification.

The suite covers feature layout, background subtraction, automatic/partial lessons, pose/movement competition, sequence direction, unknown and ignored examples, burst boundaries, entry/exit lifecycle, repeat suppression, capture freshness, and validated local persistence. These are implementation checks, not physical accuracy measurements.

## Observed hardware behavior

Three distinct 48 kHz microphone streams and all six speaker/receiver responses were observed on a 14-inch M4 MacBook Pro (Mac16,1), running macOS 27.0.1. Gesture teaching, local saves, preview events, modifiers, and shortcut delivery were exercised during development. Other hardware and OS versions remain unverified. HAL metadata did not provide calibrated microphone coordinates.

## Recognition remains experimental

Saved examples and same-session development replay contain misses and false triggers. Some gestures show strong frame-level similarity but fail completed-sequence checks; some quick motions never establish a burst. A recent three-gesture leave-one-repetition-out replay produced correct events for 0/4, 1/4, and 1/4 performances. Rest remained in training. These are intended labels and repeated development data, not independent physical validation.

Two relaxed-onset experiments recovered some missed recordings but lost an existing event and introduced a rest event. They were rejected before publication; the shipped detector and acceptance thresholds remain unchanged. The preview now retains the completed candidate's reason and distinguishes resemblance from a verified event.

The guided workspace experiment completed with stable constrained timing and 1,094 usable frames. Leading responses matched two of six instructed hand locations, plus the shoulder and rest trials. Repeated locations were poorly repeatable in the current feature representation. This does not establish precise XYZ, capsule geometry, finger tracking, or general hand/body discrimination.

A useful future evaluation needs separate recording sessions, known positions/orientations, labeled body-only negatives, unseen gesture repetitions, and false-trigger exposure during ordinary activity. Synthetic checks and locally posted keyboard events cannot substitute for that evidence.

Personal recordings, diagnostic sessions, research snapshots, and local builds are intentionally excluded from this public source repository.
