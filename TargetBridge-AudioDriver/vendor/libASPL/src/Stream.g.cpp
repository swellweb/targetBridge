// THIS FILE IS AUTO-GENERATED. DO NOT EDIT!

// Generator: generate-accessors.py
// Source: Stream.json
// Timestamp: Sun Apr 13 14:12:49 2025 UTC

// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/Stream.hpp>

#include "Compare.hpp"
#include "Convert.hpp"
#include "Traits.hpp"

#include <algorithm>

namespace aspl {

AudioClassID Stream::GetClass() const
{
    return kAudioStreamClassID;
}

AudioClassID Stream::GetBaseClass() const
{
    return kAudioObjectClassID;
}

bool Stream::IsInstance(AudioClassID classID) const
{
    switch (classID) {
    case kAudioStreamClassID:
    case kAudioObjectClassID:
        return true;
    default:
        return false;
    }
}

OSStatus Stream::SetIsActive(bool value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Stream::SetIsActive()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetIsActive()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    GetContext()->Tracer->Message("setting value to %s",
        Convert::ToString(value).c_str());

    status = SetIsActiveImpl(value);
    if (status != kAudioHardwareNoError) {
        GetContext()->Tracer->Message("setter failed");
        goto end;
    }

    NotifyPropertyChanged(kAudioStreamPropertyIsActive);

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Stream::SetLatencyAsync(UInt32 value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Stream::SetLatencyAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetLatency()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    RequestConfigurationChange([this, value = std::move(value)]() mutable {
        std::lock_guard writeLock(writeMutex_);

        Tracer::Operation op;
        op.Name = "Stream::SetLatencyImpl()";
        op.ObjectID = GetID();

        GetContext()->Tracer->OperationBegin(op);

        OSStatus status = kAudioHardwareNoError;

        if (value == GetLatency()) {
            GetContext()->Tracer->Message("value not changed");
        } else {
            GetContext()->Tracer->Message("setting value to %s",
                Convert::ToString(value).c_str());

            status = SetLatencyImpl(std::move(value));
        }

        GetContext()->Tracer->OperationEnd(op, status);
    });

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Stream::SetPhysicalFormatAsync(AudioStreamBasicDescription value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Stream::SetPhysicalFormatAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetPhysicalFormat()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    status = CheckPhysicalFormat(value);
    if (status != kAudioHardwareNoError) {
        GetContext()->Tracer->Message("value is invalid");
        goto end;
    }

    RequestConfigurationChange([this, value = std::move(value)]() mutable {
        std::lock_guard writeLock(writeMutex_);

        Tracer::Operation op;
        op.Name = "Stream::SetPhysicalFormatImpl()";
        op.ObjectID = GetID();

        GetContext()->Tracer->OperationBegin(op);

        OSStatus status = kAudioHardwareNoError;

        if (value == GetPhysicalFormat()) {
            GetContext()->Tracer->Message("value not changed");
        } else {
            GetContext()->Tracer->Message("setting value to %s",
                Convert::ToString(value).c_str());

            status = SetPhysicalFormatImpl(std::move(value));
        }

        GetContext()->Tracer->OperationEnd(op, status);
    });

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Stream::SetVirtualFormatAsync(AudioStreamBasicDescription value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Stream::SetVirtualFormatAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetVirtualFormat()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    status = CheckVirtualFormat(value);
    if (status != kAudioHardwareNoError) {
        GetContext()->Tracer->Message("value is invalid");
        goto end;
    }

    RequestConfigurationChange([this, value = std::move(value)]() mutable {
        std::lock_guard writeLock(writeMutex_);

        Tracer::Operation op;
        op.Name = "Stream::SetVirtualFormatImpl()";
        op.ObjectID = GetID();

        GetContext()->Tracer->OperationBegin(op);

        OSStatus status = kAudioHardwareNoError;

        if (value == GetVirtualFormat()) {
            GetContext()->Tracer->Message("value not changed");
        } else {
            GetContext()->Tracer->Message("setting value to %s",
                Convert::ToString(value).c_str());

            status = SetVirtualFormatImpl(std::move(value));
        }

        GetContext()->Tracer->OperationEnd(op, status);
    });

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Stream::SetAvailablePhysicalFormatsAsync(std::vector<AudioStreamRangedDescription> value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Stream::SetAvailablePhysicalFormatsAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetAvailablePhysicalFormats()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    RequestConfigurationChange([this, value = std::move(value)]() mutable {
        std::lock_guard writeLock(writeMutex_);

        Tracer::Operation op;
        op.Name = "Stream::SetAvailablePhysicalFormatsImpl()";
        op.ObjectID = GetID();

        GetContext()->Tracer->OperationBegin(op);

        OSStatus status = kAudioHardwareNoError;

        if (value == GetAvailablePhysicalFormats()) {
            GetContext()->Tracer->Message("value not changed");
        } else {
            GetContext()->Tracer->Message("setting value to %s",
                Convert::ToString(value).c_str());

            status = SetAvailablePhysicalFormatsImpl(std::move(value));
        }

        GetContext()->Tracer->OperationEnd(op, status);
    });

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Stream::SetAvailableVirtualFormatsAsync(std::vector<AudioStreamRangedDescription> value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Stream::SetAvailableVirtualFormatsAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetAvailableVirtualFormats()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    RequestConfigurationChange([this, value = std::move(value)]() mutable {
        std::lock_guard writeLock(writeMutex_);

        Tracer::Operation op;
        op.Name = "Stream::SetAvailableVirtualFormatsImpl()";
        op.ObjectID = GetID();

        GetContext()->Tracer->OperationBegin(op);

        OSStatus status = kAudioHardwareNoError;

        if (value == GetAvailableVirtualFormats()) {
            GetContext()->Tracer->Message("value not changed");
        } else {
            GetContext()->Tracer->Message("setting value to %s",
                Convert::ToString(value).c_str());

            status = SetAvailableVirtualFormatsImpl(std::move(value));
        }

        GetContext()->Tracer->OperationEnd(op, status);
    });

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

Boolean Stream::HasProperty(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address) const
{
    Boolean result = false;

    Tracer::Operation op;
    op.Name = "Stream::HasProperty()";
    op.Flags = Tracer::Flags::Readonly;
    op.ObjectID = objectID;
    op.ClientPID = clientPID;
    op.PropertyAddress = address;

    GetContext()->Tracer->OperationBegin(op);

    if (!address) {
        GetContext()->Tracer->Message("address is null");
        result = false;
        goto end;
    }

    if (objectID == GetID()) {
        switch (address->mSelector) {
        case kAudioStreamPropertyIsActive:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioStreamPropertyDirection:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioStreamPropertyTerminalType:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioStreamPropertyStartingChannel:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioStreamPropertyLatency:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioStreamPropertyPhysicalFormat:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioStreamPropertyVirtualFormat:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioStreamPropertyAvailablePhysicalFormats:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioStreamPropertyAvailableVirtualFormats:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        }
    }

    result = Object::HasProperty(objectID, clientPID, address);

end:
    GetContext()->Tracer->OperationEnd(op, kAudioHardwareNoError);
    return result;
}

OSStatus Stream::IsPropertySettable(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    Boolean* outIsSettable) const
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "Stream::IsPropertySettable()";
    op.Flags = Tracer::Flags::Readonly;
    op.ObjectID = objectID;
    op.ClientPID = clientPID;
    op.PropertyAddress = address;

    GetContext()->Tracer->OperationBegin(op);

    if (!address) {
        GetContext()->Tracer->Message("address is null");
        status = kAudioHardwareIllegalOperationError;
        goto end;
    }

    if (objectID == GetID()) {
        switch (address->mSelector) {
        case kAudioStreamPropertyIsActive:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=true");
                    *outIsSettable = true;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyDirection:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyTerminalType:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyStartingChannel:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyLatency:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyPhysicalFormat:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=true");
                    *outIsSettable = true;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyVirtualFormat:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=true");
                    *outIsSettable = true;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyAvailablePhysicalFormats:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyAvailableVirtualFormats:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        }
    }

    status = Object::IsPropertySettable(objectID, clientPID, address, outIsSettable);

end:
    GetContext()->Tracer->OperationEnd(op, status);
    return status;
}

OSStatus Stream::GetPropertyDataSize(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32* outDataSize) const
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "Stream::GetPropertyDataSize()";
    op.Flags = Tracer::Flags::Readonly;
    op.ObjectID = objectID;
    op.ClientPID = clientPID;
    op.PropertyAddress = address;
    op.QualifierDataSize = qualifierDataSize;
    op.QualifierData = qualifierData;
    op.OutDataSize = outDataSize;

    GetContext()->Tracer->OperationBegin(op);

    if (!address) {
        GetContext()->Tracer->Message("address is null");
        status = kAudioHardwareIllegalOperationError;
        goto end;
    }

    if (objectID == GetID()) {
        switch (address->mSelector) {
        case kAudioStreamPropertyIsActive:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(UInt32);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyDirection:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(UInt32);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyTerminalType:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(UInt32);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyStartingChannel:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(UInt32);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyLatency:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(UInt32);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyPhysicalFormat:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyVirtualFormat:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyAvailablePhysicalFormats:
            {
                if (outDataSize) {
                    const auto values = GetAvailablePhysicalFormats();
                    *outDataSize = UInt32(values.size()
                        * sizeof(AudioStreamRangedDescription));
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyAvailableVirtualFormats:
            {
                if (outDataSize) {
                    const auto values = GetAvailableVirtualFormats();
                    *outDataSize = UInt32(values.size()
                        * sizeof(AudioStreamRangedDescription));
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        }
    }

    status = Object::GetPropertyDataSize(
        objectID, clientPID, address, qualifierDataSize, qualifierData, outDataSize);

end:
    GetContext()->Tracer->OperationEnd(op, status);
    return status;
}

OSStatus Stream::GetPropertyData(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32 inDataSize,
    UInt32* outDataSize,
    void* outData) const
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "Stream::GetPropertyData()";
    op.Flags = Tracer::Flags::Readonly;
    op.ObjectID = objectID;
    op.ClientPID = clientPID;
    op.PropertyAddress = address;
    op.QualifierDataSize = qualifierDataSize;
    op.QualifierData = qualifierData;
    op.InDataSize = inDataSize;
    op.OutDataSize = outDataSize;
    op.OutData = outData;

    GetContext()->Tracer->OperationBegin(op);

    if (!address) {
        GetContext()->Tracer->Message("address is null");
        status = kAudioHardwareIllegalOperationError;
        goto end;
    }

    if (objectID == GetID()) {
        switch (address->mSelector) {
        case kAudioStreamPropertyIsActive:
            {
                if (inDataSize < sizeof(UInt32)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(UInt32)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(UInt32);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetIsActive();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning IsActive=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyDirection:
            {
                if (inDataSize < sizeof(UInt32)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(UInt32)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(UInt32);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetDirection();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning Direction=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyTerminalType:
            {
                if (inDataSize < sizeof(UInt32)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(UInt32)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(UInt32);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetTerminalType();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning TerminalType=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyStartingChannel:
            {
                if (inDataSize < sizeof(UInt32)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(UInt32)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(UInt32);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetStartingChannel();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning StartingChannel=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyLatency:
            {
                if (inDataSize < sizeof(UInt32)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(UInt32)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(UInt32);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetLatency();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning Latency=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyPhysicalFormat:
            {
                if (inDataSize < sizeof(AudioStreamBasicDescription)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(AudioStreamBasicDescription)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetPhysicalFormat();
                    Convert::ToFoundation(
                        value,
                        *static_cast<AudioStreamBasicDescription*>(outData));
                    GetContext()->Tracer->Message(
                        "returning PhysicalFormat=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyVirtualFormat:
            {
                if (inDataSize < sizeof(AudioStreamBasicDescription)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(AudioStreamBasicDescription)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetVirtualFormat();
                    Convert::ToFoundation(
                        value,
                        *static_cast<AudioStreamBasicDescription*>(outData));
                    GetContext()->Tracer->Message(
                        "returning VirtualFormat=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyAvailablePhysicalFormats:
            {
                const auto values = GetAvailablePhysicalFormats();
                const size_t valuesCount = std::min(
                    inDataSize / sizeof(AudioStreamRangedDescription),
                    values.size());
                if (outDataSize) {
                    *outDataSize = UInt32(valuesCount
                        * sizeof(AudioStreamRangedDescription));
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    for (size_t i = 0; i < valuesCount; i++) {
                        Convert::ToFoundation(
                            values[i],
                            static_cast<AudioStreamRangedDescription*>(outData)[i]);
                    }
                    GetContext()->Tracer->Message(
                        "returning AvailablePhysicalFormats=%s (%u/%u)",
                        Convert::ToString(values).c_str(),
                        unsigned(valuesCount),
                        unsigned(values.size()));
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioStreamPropertyAvailableVirtualFormats:
            {
                const auto values = GetAvailableVirtualFormats();
                const size_t valuesCount = std::min(
                    inDataSize / sizeof(AudioStreamRangedDescription),
                    values.size());
                if (outDataSize) {
                    *outDataSize = UInt32(valuesCount
                        * sizeof(AudioStreamRangedDescription));
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    for (size_t i = 0; i < valuesCount; i++) {
                        Convert::ToFoundation(
                            values[i],
                            static_cast<AudioStreamRangedDescription*>(outData)[i]);
                    }
                    GetContext()->Tracer->Message(
                        "returning AvailableVirtualFormats=%s (%u/%u)",
                        Convert::ToString(values).c_str(),
                        unsigned(valuesCount),
                        unsigned(values.size()));
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        }
    }

    status = Object::GetPropertyData(
        objectID, clientPID, address, qualifierDataSize, qualifierData,
        inDataSize, outDataSize, outData);

end:
    GetContext()->Tracer->OperationEnd(op, status);
    return status;
}

OSStatus Stream::SetPropertyData(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32 inDataSize,
    const void* inData)
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "Stream::SetPropertyData()";
    op.ObjectID = objectID;
    op.ClientPID = clientPID;
    op.PropertyAddress = address;
    op.QualifierDataSize = qualifierDataSize;
    op.QualifierData = qualifierData;
    op.InDataSize = inDataSize;
    op.InData = inData;

    GetContext()->Tracer->OperationBegin(op);

    if (!address) {
        GetContext()->Tracer->Message("address is null");
        status = kAudioHardwareIllegalOperationError;
        goto end;
    }

    if (objectID == GetID()) {
        switch (address->mSelector) {
        case kAudioStreamPropertyIsActive:
            {
                if (inDataSize != sizeof(UInt32)) {
                    GetContext()->Tracer->Message("invalid size: should be %u, got %u",
                        unsigned(sizeof(UInt32)), unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (!inData) {
                    GetContext()->Tracer->Message("input buffer is null");
                    status = kAudioHardwareIllegalOperationError;
                    goto end;
                }
                std::remove_cv_t<std::remove_reference_t<
                    decltype(GetIsActive())>> value;
                Convert::FromFoundation(
                    *static_cast<const UInt32*>(inData),
                    value);
                GetContext()->Tracer->Message(
                    "setting IsActive=%s",
                    Convert::ToString(value).c_str());
                status = SetIsActive(std::move(value));
                if (status != kAudioHardwareNoError) {
                    GetContext()->Tracer->Message("setter failed");
                    goto end;
                }
            }
            goto end;
        case kAudioStreamPropertyPhysicalFormat:
            {
                if (inDataSize != sizeof(AudioStreamBasicDescription)) {
                    GetContext()->Tracer->Message("invalid size: should be %u, got %u",
                        unsigned(sizeof(AudioStreamBasicDescription)), unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (!inData) {
                    GetContext()->Tracer->Message("input buffer is null");
                    status = kAudioHardwareIllegalOperationError;
                    goto end;
                }
                std::remove_cv_t<std::remove_reference_t<
                    decltype(GetPhysicalFormat())>> value;
                Convert::FromFoundation(
                    *static_cast<const AudioStreamBasicDescription*>(inData),
                    value);
                GetContext()->Tracer->Message(
                    "setting PhysicalFormat=%s",
                    Convert::ToString(value).c_str());
                status = SetPhysicalFormatAsync(std::move(value));
                if (status != kAudioHardwareNoError) {
                    GetContext()->Tracer->Message("setter failed");
                    goto end;
                }
            }
            goto end;
        case kAudioStreamPropertyVirtualFormat:
            {
                if (inDataSize != sizeof(AudioStreamBasicDescription)) {
                    GetContext()->Tracer->Message("invalid size: should be %u, got %u",
                        unsigned(sizeof(AudioStreamBasicDescription)), unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (!inData) {
                    GetContext()->Tracer->Message("input buffer is null");
                    status = kAudioHardwareIllegalOperationError;
                    goto end;
                }
                std::remove_cv_t<std::remove_reference_t<
                    decltype(GetVirtualFormat())>> value;
                Convert::FromFoundation(
                    *static_cast<const AudioStreamBasicDescription*>(inData),
                    value);
                GetContext()->Tracer->Message(
                    "setting VirtualFormat=%s",
                    Convert::ToString(value).c_str());
                status = SetVirtualFormatAsync(std::move(value));
                if (status != kAudioHardwareNoError) {
                    GetContext()->Tracer->Message("setter failed");
                    goto end;
                }
            }
            goto end;
        }
    }

    status = Object::SetPropertyData(
        objectID, clientPID, address, qualifierDataSize, qualifierData, inDataSize, inData);

end:
    GetContext()->Tracer->OperationEnd(op, status);
    return status;
}

} // namespace aspl
