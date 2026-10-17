#include "VoiceArrayPrime.h"
#include <AudioToolbox/AudioToolbox.h>
#include <stdlib.h>
struct PVVoiceArray {AudioUnit unit;float scratch[8192];};
static OSStatus consume(void *context,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *output){
    (void)bus;(void)output;
    PVVoiceArray *session=context;
    if(frames>8192)return kAudioUnitErr_TooManyFramesToProcess;
    AudioBufferList data={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=1,.mDataByteSize=frames*4,.mData=session->scratch}}};
    // The mono voice-client result is discarded. EchoGestures separately reads the
    // three native HAL channels; this callback only keeps the array request alive.
    return AudioUnitRender(session->unit,flags,time,1,frames,&data);
}
void PVVoiceArrayStop(PVVoiceArray *session){
    if(!session)return;
    if(session->unit){AudioOutputUnitStop(session->unit);AudioUnitUninitialize(session->unit);AudioComponentInstanceDispose(session->unit);}
    free(session);
}
int32_t PVVoiceArrayStart(uint32_t device,PVVoiceArray **result,int32_t *stage){
    if(!result||!stage)return -50;
    *result=NULL;*stage=1;
    PVVoiceArray *s=calloc(1,sizeof(*s));if(!s)return -108;
    AudioComponentDescription description={kAudioUnitType_Output,kAudioUnitSubType_VoiceProcessingIO,kAudioUnitManufacturer_Apple,0,0};
    AudioComponent component=AudioComponentFindNext(NULL,&description);
    OSStatus error=component?AudioComponentInstanceNew(component,&s->unit):kAudioUnitErr_InvalidProperty;
    if(error)goto failure;
    UInt32 yes=1,no=0;
#define SET(STAGE,PROPERTY,SCOPE,BUS,VALUE) do{*stage=STAGE;error=AudioUnitSetProperty(s->unit,PROPERTY,SCOPE,BUS,&VALUE,sizeof(VALUE));if(error)goto failure;}while(0)
    SET(2,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,yes);
    SET(3,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,no);
    SET(4,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,1,device);
    SET(5,kAUVoiceIOProperty_BypassVoiceProcessing,kAudioUnitScope_Global,0,yes);
    SET(6,kAUVoiceIOProperty_VoiceProcessingEnableAGC,kAudioUnitScope_Global,0,no);
    // Preserve the voice client format. The separate native array reader remains 48 kHz.
    AudioStreamBasicDescription format={0};UInt32 formatBytes=sizeof(format);
    *stage=7;error=AudioUnitGetProperty(s->unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,1,&format,&formatBytes);
    if(error)goto failure;
    if(format.mChannelsPerFrame!=1 || format.mBytesPerFrame!=4){error=kAudioUnitErr_FormatNotSupported;goto failure;}
    AURenderCallbackStruct callback={consume,s};
    SET(8,kAudioOutputUnitProperty_SetInputCallback,kAudioUnitScope_Global,1,callback);
    *stage=9;error=AudioUnitInitialize(s->unit);if(error)goto failure;
    *stage=10;error=AudioOutputUnitStart(s->unit);if(error)goto failure;
    *stage=0;*result=s;return noErr;
failure:
    PVVoiceArrayStop(s);return error;
#undef SET
}
