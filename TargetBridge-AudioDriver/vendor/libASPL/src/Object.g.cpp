// THIS FILE IS AUTO-GENERATED. DO NOT EDIT!

// Generator: generate-accessors.py
// Source: Object.json
// Timestamp: Sun Apr 13 14:12:48 2025 UTC

// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/Object.hpp>

#include "Compare.hpp"
#include "Convert.hpp"
#include "Traits.hpp"

#include <algorithm>

namespace aspl {

AudioClassID Object::GetClass() const
{
    return kAudioObjectClassID;
}

AudioClassID Object::GetBaseClass() const
{
    return kAudioObjectClassID;
}

bool Object::IsInstance(AudioClassID classID) const
{
    switch (classID) {
    case kAudioObjectClassID:
        return true;
    default:
        return false;
    }
}

Boolean Object::HasProperty(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address) const
{
    Boolean result = false;

    Tracer::Operation op;
    op.Name = "Object::HasProperty()";
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
        case kAudioObjectPropertyClass:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioObjectPropertyBaseClass:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioObjectPropertyOwner:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioObjectPropertyOwnedObjects:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioObjectPropertyCustomPropertyInfoList:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        }
    }

    result = HasPropertyFallback(objectID, clientPID, address);

end:
    GetContext()->Tracer->OperationEnd(op, kAudioHardwareNoError);
    return result;
}

OSStatus Object::IsPropertySettable(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    Boolean* outIsSettable) const
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "Object::IsPropertySettable()";
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
        case kAudioObjectPropertyClass:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyBaseClass:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyOwner:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyOwnedObjects:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyCustomPropertyInfoList:
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

    status = IsPropertySettableFallback(objectID, clientPID, address, outIsSettable);

end:
    GetContext()->Tracer->OperationEnd(op, status);
    return status;
}

OSStatus Object::GetPropertyDataSize(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32* outDataSize) const
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "Object::GetPropertyDataSize()";
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
        case kAudioObjectPropertyClass:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(AudioClassID);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyBaseClass:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(AudioClassID);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyOwner:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(AudioObjectID);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyOwnedObjects:
            {
                if (outDataSize) {
                    const auto values = GetOwnedObjectIDs(address->mScope);
                    *outDataSize = UInt32(values.size()
                        * sizeof(AudioObjectID));
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyCustomPropertyInfoList:
            {
                if (outDataSize) {
                    const auto values = GetCustomProperties();
                    *outDataSize = UInt32(values.size()
                        * sizeof(AudioServerPlugInCustomPropertyInfo));
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        }
    }

    status = GetPropertyDataSizeFallback(
        objectID, clientPID, address, qualifierDataSize, qualifierData, outDataSize);

end:
    GetContext()->Tracer->OperationEnd(op, status);
    return status;
}

OSStatus Object::GetPropertyData(AudioObjectID objectID,
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
    op.Name = "Object::GetPropertyData()";
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
        case kAudioObjectPropertyClass:
            {
                if (inDataSize < sizeof(AudioClassID)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(AudioClassID)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(AudioClassID);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetClass();
                    Convert::ToFoundation(
                        value,
                        *static_cast<AudioClassID*>(outData));
                    GetContext()->Tracer->Message(
                        "returning Class=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyBaseClass:
            {
                if (inDataSize < sizeof(AudioClassID)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(AudioClassID)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(AudioClassID);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetBaseClass();
                    Convert::ToFoundation(
                        value,
                        *static_cast<AudioClassID*>(outData));
                    GetContext()->Tracer->Message(
                        "returning BaseClass=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyOwner:
            {
                if (inDataSize < sizeof(AudioObjectID)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(AudioObjectID)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(AudioObjectID);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetOwnerID();
                    Convert::ToFoundation(
                        value,
                        *static_cast<AudioObjectID*>(outData));
                    GetContext()->Tracer->Message(
                        "returning OwnerID=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyOwnedObjects:
            {
                const auto values = GetOwnedObjectIDs(address->mScope);
                const size_t valuesCount = std::min(
                    inDataSize / sizeof(AudioObjectID),
                    values.size());
                if (outDataSize) {
                    *outDataSize = UInt32(valuesCount
                        * sizeof(AudioObjectID));
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    for (size_t i = 0; i < valuesCount; i++) {
                        Convert::ToFoundation(
                            values[i],
                            static_cast<AudioObjectID*>(outData)[i]);
                    }
                    GetContext()->Tracer->Message(
                        "returning OwnedObjectIDs=%s (%u/%u)",
                        Convert::ToString(values).c_str(),
                        unsigned(valuesCount),
                        unsigned(values.size()));
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyCustomPropertyInfoList:
            {
                const auto values = GetCustomProperties();
                const size_t valuesCount = std::min(
                    inDataSize / sizeof(AudioServerPlugInCustomPropertyInfo),
                    values.size());
                if (outDataSize) {
                    *outDataSize = UInt32(valuesCount
                        * sizeof(AudioServerPlugInCustomPropertyInfo));
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    for (size_t i = 0; i < valuesCount; i++) {
                        Convert::ToFoundation(
                            values[i],
                            static_cast<AudioServerPlugInCustomPropertyInfo*>(outData)[i]);
                    }
                    GetContext()->Tracer->Message(
                        "returning CustomProperties=%s (%u/%u)",
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

    status = GetPropertyDataFallback(
        objectID, clientPID, address, qualifierDataSize, qualifierData,
        inDataSize, outDataSize, outData);

end:
    GetContext()->Tracer->OperationEnd(op, status);
    return status;
}

OSStatus Object::SetPropertyData(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32 inDataSize,
    const void* inData)
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "Object::SetPropertyData()";
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
        }
    }

    status = SetPropertyDataFallback(
        objectID, clientPID, address, qualifierDataSize, qualifierData, inDataSize, inData);

end:
    GetContext()->Tracer->OperationEnd(op, status);
    return status;
}

} // namespace aspl
