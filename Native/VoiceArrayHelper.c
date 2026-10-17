#include "VoiceArrayPrime.h"
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <unistd.h>
int main(void){
    AudioObjectPropertyAddress p={kAudioHardwarePropertyTranslateUIDToDevice,kAudioObjectPropertyScopeGlobal,0};
    CFStringRef uid=CFSTR("BuiltInMicrophoneDevice");AudioDeviceID device=0;UInt32 bytes=sizeof(device);
    OSStatus error=AudioObjectGetPropertyData(kAudioObjectSystemObject,&p,sizeof(uid),&uid,&bytes,&device);
    if(error||!device){fprintf(stderr,"Built-in microphone unavailable (%d)\n",error);return 1;}
    PVVoiceArray *session=NULL;int32_t stage=0;
    error=PVVoiceArrayStart(device,&session,&stage);
    if(error){fprintf(stderr,"Voice array setup step %d failed (%d)\n",stage,error);return 2;}
    puts("READY");fflush(stdout);
    // Parent owns the sole writer. Stop, normal quit and parent-process death all
    // close it, so the helper releases the voice request even after an app crash.
    char byte;while(read(STDIN_FILENO,&byte,1)>0){}
    PVVoiceArrayStop(session);return 0;
}
