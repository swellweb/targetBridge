// THIS FILE IS AUTO-GENERATED. DO NOT EDIT!

// Generator: generate-accessors.py
// Source: MuteControl.json
// Timestamp: Sun Apr 13 14:12:48 2025 UTC

// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/MuteControl.hpp>

#include "Compare.hpp"
#include "Convert.hpp"
#include "Traits.hpp"

#include <algorithm>

namespace aspl {

AudioClassID MuteControl::GetClass() const
{
    return kAudioMuteControlClassID;
}

AudioClassID MuteControl::GetBaseClass() const
{
    return kAudioBooleanControlClassID;
}

bool MuteControl::IsInstance(AudioClassID classID) const
{
    switch (classID) {
    case kAudioMuteControlClassID:
    case kAudioBooleanControlClassID:
    case kAudioControlClassID:
    case kAudioObjectClassID:
        return true;
    default:
        return false;
    }
}

OSStatus MuteControl::SetIsMuted(bool value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "MuteControl::SetIsMuted()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetIsMuted()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    GetContext()->Tracer->Message("setting value to %s",
        Convert::ToString(value).c_str());

    status = SetIsMutedImpl(value);
    if (status != kAudioHardwareNoError) {
        GetContext()->Tracer->Message("setter failed");
        goto end;
    }

    NotifyPropertyChanged(kAudioBooleanControlPropertyValue, GetScope(), GetElement());

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

Boolean MuteControl::HasProperty(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address) const
{
    Boolean result = false;

    Tracer::Operation op;
    op.Name = "MuteControl::HasProperty()";
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
        case kAudioControlPropertyScope:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioControlPropertyElement:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioBooleanControlPropertyValue:
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

OSStatus MuteControl::IsPropertySettable(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    Boolean* outIsSettable) const
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "MuteControl::IsPropertySettable()";
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
        case kAudioControlPropertyScope:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioControlPropertyElement:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioBooleanControlPropertyValue:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=true");
                    *outIsSettable = true;
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

OSStatus MuteControl::GetPropertyDataSize(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32* outDataSize) const
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "MuteControl::GetPropertyDataSize()";
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
        case kAudioControlPropertyScope:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioControlPropertyElement:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioBooleanControlPropertyValue:
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
        }
    }

    status = Object::GetPropertyDataSize(
        objectID, clientPID, address, qualifierDataSize, qualifierData, outDataSize);

end:
    GetContext()->Tracer->OperationEnd(op, status);
    return status;
}

OSStatus MuteControl::GetPropertyData(AudioObjectID objectID,
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
    op.Name = "MuteControl::GetPropertyData()";
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
        case kAudioControlPropertyScope:
            {
                if (inDataSize < sizeof(AudioObjectPropertyScope)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(AudioObjectPropertyScope)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetScope();
                    Convert::ToFoundation(
                        value,
                        *static_cast<AudioObjectPropertyScope*>(outData));
                    GetContext()->Tracer->Message(
                        "returning Scope=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioControlPropertyElement:
            {
                if (inDataSize < sizeof(AudioObjectPropertyElement)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(AudioObjectPropertyElement)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetElement();
                    Convert::ToFoundation(
                        value,
                        *static_cast<AudioObjectPropertyElement*>(outData));
                    GetContext()->Tracer->Message(
                        "returning Element=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioBooleanControlPropertyValue:
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
                    const auto value = GetIsMuted();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning IsMuted=%s",
                        Convert::ToString(value).c_str());
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

OSStatus MuteControl::SetPropertyData(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32 inDataSize,
    const void* inData)
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "MuteControl::SetPropertyData()";
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
        case kAudioBooleanControlPropertyValue:
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
                    decltype(GetIsMuted())>> value;
                Convert::FromFoundation(
                    *static_cast<const UInt32*>(inData),
                    value);
                GetContext()->Tracer->Message(
                    "setting IsMuted=%s",
                    Convert::ToString(value).c_str());
                status = SetIsMuted(std::move(value));
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
