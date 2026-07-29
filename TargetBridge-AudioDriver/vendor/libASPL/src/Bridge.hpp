// Copyright (c) libASPL authors
// Licensed under MIT

#include <CoreAudio/AudioServerPlugIn.h>

namespace aspl {

class Bridge
{
public:
    // Dynamic property dispatch

    static Boolean HasProperty(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address);

    static OSStatus IsPropertySettable(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        Boolean* outIsSettable);

    static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32* outDataSize);

    static OSStatus GetPropertyData(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32 inDataSize,
        UInt32* outDataSize,
        void* outData);

    static OSStatus SetPropertyData(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32 inDataSize,
        const void* inData);

    // Device clients

    static OSStatus AddClient(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        const AudioServerPlugInClientInfo* clientInfo);

    static OSStatus RemoveClient(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        const AudioServerPlugInClientInfo* clientInfo);

    // Device I/O

    static OSStatus StartIO(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        UInt32 clientID);

    static OSStatus StopIO(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        UInt32 clientID);

    static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        UInt32 clientID,
        Float64* outSampleTime,
        UInt64* outHostTime,
        UInt64* outSeed);

    static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        UInt32 clientID,
        UInt32 operationID,
        Boolean* outWillDo,
        Boolean* outWillDoInPlace);

    static OSStatus BeginIOOperation(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        UInt32 clientID,
        UInt32 operationID,
        UInt32 ioBufferFrameSize,
        const AudioServerPlugInIOCycleInfo* ioCycleInfo);

    static OSStatus DoIOOperation(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        AudioObjectID inStreamObjectID,
        UInt32 clientID,
        UInt32 operationID,
        UInt32 ioBufferFrameSize,
        const AudioServerPlugInIOCycleInfo* ioCycleInfo,
        void* ioMainBuffer,
        void* ioSecondaryBuffer);

    static OSStatus EndIOOperation(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        UInt32 clientID,
        UInt32 operationID,
        UInt32 ioBufferFrameSize,
        const AudioServerPlugInIOCycleInfo* ioCycleInfo);

    // Device configuration

    static OSStatus PerformConfigurationChange(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        UInt64 changeAction,
        void* changeInfo);

    static OSStatus AbortConfigurationChange(AudioServerPlugInDriverRef driver,
        AudioObjectID objectID,
        UInt64 changeAction,
        void* changeInfo);
};

} // namespace aspl
