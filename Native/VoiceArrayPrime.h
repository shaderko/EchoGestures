#ifndef PARALLAX_VOICE_ARRAY_PRIME_H
#define PARALLAX_VOICE_ARRAY_PRIME_H
#include <stdint.h>
typedef struct PVVoiceArray PVVoiceArray;
// Temporary input-only public VoiceProcessingIO session. No playback, files,
// private entitlements, driver changes or system default changes.
int32_t PVVoiceArrayStart(uint32_t device, PVVoiceArray **result, int32_t *stage);
void PVVoiceArrayStop(PVVoiceArray *session);
#endif
