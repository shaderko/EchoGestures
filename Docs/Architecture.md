# Architecture

## One capture and recognition path

Built-in stereo speakers → three synchronized microphone channels → six matched-filter responses → frozen background subtraction → 402 echo features → learned gesture evidence → sequence verification → command lifecycle.

A separate input-only VoiceProcessingIO helper requests native microphone-array access. Its mono callback output is discarded. The main process reads the three native HAL channels through a temporary private aggregate device, alongside built-in speaker playback. The helper ends when its parent pipe closes. No driver changes or administrator access are used.

At 48 kHz, a 4096-sample period produces approximately 11.7 observations per second. The two speakers emit sequential 512-sample 20.2–22.8 kHz sweeps, separated by 2048 samples. Three receivers observe each speaker probe together; the two speaker measurements are not simultaneous.

## Recognition

The fixed-delay features cover 12–90 cm equivalent excess-path/2, not measured hand range. Each frame has six 67-value blocks. Microphone-pair energy normalization removes common gain; no anatomical hand segmentation is performed.

An 822-value temporal representation combines recent shape, signed changes over six observations, and per-path activity. Class-balanced ridge regression compares rest, optional ignored movement, and each enabled gesture. Scores are logistic evidence differences, not calibrated probabilities. Both strongest-background and strongest-rival checks must pass.

Recorded-example support bounds unknown patterns. Movement lessons retain complete recordings and derive active bursts using the same detector as live capture. Two changing observations establish onset; two quieter observations close a candidate. A two-second cap bounds continuous movement. DTW checks recorded sequence shape against the selected class, other movements, and ignored examples. Derived variants remain grouped by their original repetition when calibrating tolerance.

A verified movement is delivered for two fresh predictions to the event gate. Poses need four qualifying observations and are suppressed during movement. The command lifecycle handles entry, held state, release, repeat suppression, and cooldown independently of the UI similarity bar.

## Runtime and storage

DSP and model fitting run off the main thread. Four in-flight audio/delivery buffers bound backlog. Frames with missing, stale, out-of-order, or invalid timestamps do not reach learning or recognition. Gaps reset history. Background remains frozen during a capture session.

Original numeric examples are retained in the bounded live library and independent lesson archives. Saves validate schema and use atomic writes. No raw microphone waveform is persisted and the app implements no networking.

Recognition diagnostics retain a bounded 360-prediction history. They distinguish model evidence, completed-candidate acceptance, lifecycle entry, and historical command status. A repeated historical status does not represent a repeated event.

## Array inspector

The inspector observes the same capture path while commands and gesture inference are paused. It records shared-origin/phase/scale complex profiles for each speaker across all receivers, input RMS/correlation checks, and HAL metadata. Raw analytic correlation arrays remain transient.

A rigid-array clock estimates initial timing origins from 36 qualified frames, then holds receiver offsets fixed. Only supported common shifts advance the clock; interruptions create a new epoch. These are timing constraints, not known microphone capsule coordinates.

The 94-second workspace lesson uses a still reference, two teaching rounds at six approximate hand marks plus shoulder-only trials, then a separate reordered check with the response map frozen. It uses 198 signed complex/strength features. The map is a current-session diagnostic preview; it neither updates old gesture examples nor drives commands. Stable shared timing does not establish reliable spatial localization.
