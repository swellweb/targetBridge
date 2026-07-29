// THIS FILE IS AUTO-GENERATED. DO NOT EDIT!

// Generator: generate-bridge.py
// Source: Bridge.json
// Timestamp: Sun Apr 13 14:12:49 2025 UTC

// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/Driver.hpp>
#include <aspl/Tracer.hpp>

#include "Bridge.hpp"

namespace aspl {

Boolean Bridge::HasProperty(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* propertyAddress)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return {};
    }

    Boolean result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::HasProperty() objectID=%u object not registered",
             unsigned(objectID));
        goto end;
    }

    result = std::static_pointer_cast<Object>(object)->HasProperty(
        objectID,
        clientPID,
        propertyAddress);

end:
    return result;
}

OSStatus Bridge::IsPropertySettable(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* propertyAddress,
    Boolean* outData)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::IsPropertySettable() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Object>(object)->IsPropertySettable(
        objectID,
        clientPID,
        propertyAddress,
        outData);

end:
    return result;
}

OSStatus Bridge::GetPropertyDataSize(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* propertyAddress,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32* outDataSize)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::GetPropertyDataSize() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Object>(object)->GetPropertyDataSize(
        objectID,
        clientPID,
        propertyAddress,
        qualifierDataSize,
        qualifierData,
        outDataSize);

end:
    return result;
}

OSStatus Bridge::GetPropertyData(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* propertyAddress,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32 inDataSize,
    UInt32* outDataSize,
    void* outData)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::GetPropertyData() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Object>(object)->GetPropertyData(
        objectID,
        clientPID,
        propertyAddress,
        qualifierDataSize,
        qualifierData,
        inDataSize,
        outDataSize,
        outData);

end:
    return result;
}

OSStatus Bridge::SetPropertyData(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* propertyAddress,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32 inDataSize,
    const void* inData)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::SetPropertyData() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Object>(object)->SetPropertyData(
        objectID,
        clientPID,
        propertyAddress,
        qualifierDataSize,
        qualifierData,
        inDataSize,
        inData);

end:
    return result;
}

OSStatus Bridge::AddClient(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    const AudioServerPlugInClientInfo* clientInfo)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::AddClient() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Device>(object)->AddClient(
        objectID,
        clientInfo);

end:
    return result;
}

OSStatus Bridge::RemoveClient(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    const AudioServerPlugInClientInfo* clientInfo)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::RemoveClient() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Device>(object)->RemoveClient(
        objectID,
        clientInfo);

end:
    return result;
}

OSStatus Bridge::StartIO(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    UInt32 clientID)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::StartIO() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Device>(object)->StartIO(
        objectID,
        clientID);

end:
    return result;
}

OSStatus Bridge::StopIO(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    UInt32 clientID)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::StopIO() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Device>(object)->StopIO(
        objectID,
        clientID);

end:
    return result;
}

OSStatus Bridge::GetZeroTimeStamp(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    UInt32 clientID,
    Float64* outSampleTime,
    UInt64* outHostTime,
    UInt64* outSeed)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::GetZeroTimeStamp() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Device>(object)->GetZeroTimeStamp(
        objectID,
        clientID,
        outSampleTime,
        outHostTime,
        outSeed);

end:
    return result;
}

OSStatus Bridge::WillDoIOOperation(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    UInt32 clientID,
    UInt32 operationID,
    Boolean* outWillDo,
    Boolean* outWillDoInPlace)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::WillDoIOOperation() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Device>(object)->WillDoIOOperation(
        objectID,
        clientID,
        operationID,
        outWillDo,
        outWillDoInPlace);

end:
    return result;
}

OSStatus Bridge::BeginIOOperation(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    UInt32 clientID,
    UInt32 operationID,
    UInt32 ioBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* ioCycleInfo)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::BeginIOOperation() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Device>(object)->BeginIOOperation(
        objectID,
        clientID,
        operationID,
        ioBufferFrameSize,
        ioCycleInfo);

end:
    return result;
}

OSStatus Bridge::DoIOOperation(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    AudioObjectID streamID,
    UInt32 clientID,
    UInt32 operationID,
    UInt32 ioBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* ioCycleInfo,
    void* ioMainBuffer,
    void* ioSecondaryBuffer)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::DoIOOperation() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Device>(object)->DoIOOperation(
        objectID,
        streamID,
        clientID,
        operationID,
        ioBufferFrameSize,
        ioCycleInfo,
        ioMainBuffer,
        ioSecondaryBuffer);

end:
    return result;
}

OSStatus Bridge::EndIOOperation(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    UInt32 clientID,
    UInt32 operationID,
    UInt32 ioBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* ioCycleInfo)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::EndIOOperation() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Device>(object)->EndIOOperation(
        objectID,
        clientID,
        operationID,
        ioBufferFrameSize,
        ioCycleInfo);

end:
    return result;
}

OSStatus Bridge::PerformConfigurationChange(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    UInt64 changeAction,
    void* changeInfo)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::PerformConfigurationChange() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Device>(object)->PerformConfigurationChange(
        objectID,
        changeAction,
        changeInfo);

end:
    return result;
}

OSStatus Bridge::AbortConfigurationChange(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID,
    UInt64 changeAction,
    void* changeInfo)
{
    const auto driver = Driver::GetDriver(driverRef);
    if (!driver) {
        return kAudioHardwareUnspecifiedError;
    }

    OSStatus result = {};

    const auto object = driver->GetContext()->Dispatcher->FindObject(objectID);
    if (!object) {
        driver->GetContext()->Tracer->Message(
            "Bridge::AbortConfigurationChange() objectID=%u object not registered",
             unsigned(objectID));
        result = kAudioHardwareBadObjectError;
        goto end;
    }

    result = std::static_pointer_cast<Device>(object)->AbortConfigurationChange(
        objectID,
        changeAction,
        changeInfo);

end:
    return result;
}

} // namespace aspl
