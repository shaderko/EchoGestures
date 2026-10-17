# Enter and exit commands

A gesture can have an entry shortcut and an optional exit shortcut. Enable **Run another shortcut on exit** in its binding editor.

Entry runs once after verified recognition and lifecycle qualification. Holding does not repeat it. Release is debounced over three clear rest/other-gesture observations, with a 650 ms uncertainty fallback. Cancellation, capture loss, pausing, teaching, binding changes, stopping, and normal quit finish an active held action.

An exit is scheduled only after entry was successfully posted to macOS. The session retains that target's PID, bundle ID, and launch date. Exit returns to the original application, even if focus changes; it refuses a terminated or reused process identity. A failed or preview entry never schedules an exit.

Posting a keyboard event is not proof that the target application handled it. Focused text fields, application shortcuts, permissions, and playback state still matter. Sending a toggle key on entry and exit toggles twice; it is not an absolute pause/resume API. The binding editor includes a K-on-both-edges preset for YouTube.

A force-killed app cannot send cleanup. Revoked Accessibility or a terminated target can also prevent exit. Commands start paused on launch and never target EchoGestures itself.
