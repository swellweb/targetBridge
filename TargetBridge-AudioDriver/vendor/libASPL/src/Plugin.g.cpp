// THIS FILE IS AUTO-GENERATED. DO NOT EDIT!

// Generator: generate-accessors.py
// Source: Plugin.json
// Timestamp: Sun Apr 13 14:12:48 2025 UTC

// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/Plugin.hpp>

#include "Compare.hpp"
#include "Convert.hpp"
#include "Traits.hpp"

#include <algorithm>

namespace aspl {

AudioClassID Plugin::GetClass() const
{
    return kAudioPlugInClassID;
}

AudioClassID Plugin::GetBaseClass() const
{
    return kAudioObjectClassID;
}

bool Plugin::IsInstance(AudioClassID classID) const
{
    switch (classID) {
    case kAudioPlugInClassID:
    case kAudioObjectClassID:
        return true;
    default:
        return false;
    }
}

Boolean Plugin::HasProperty(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address) const
{
    Boolean result = false;

    Tracer::Operation op;
    op.Name = "Plugin::HasProperty()";
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
        case kAudioObjectPropertyManufacturer:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioPlugInPropertyResourceBundle:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioPlugInPropertyDeviceList:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioPlugInPropertyTranslateUIDToDevice:
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

OSStatus Plugin::IsPropertySettable(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    Boolean* outIsSettable) const
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "Plugin::IsPropertySettable()";
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
        case kAudioObjectPropertyManufacturer:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioPlugInPropertyResourceBundle:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioPlugInPropertyDeviceList:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioPlugInPropertyTranslateUIDToDevice:
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

OSStatus Plugin::GetPropertyDataSize(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32* outDataSize) const
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "Plugin::GetPropertyDataSize()";
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
        case kAudioObjectPropertyManufacturer:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(CFStringRef);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioPlugInPropertyResourceBundle:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(CFStringRef);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioPlugInPropertyDeviceList:
            {
                if (outDataSize) {
                    const auto values = GetDeviceIDs();
                    *outDataSize = UInt32(values.size()
                        * sizeof(AudioObjectID));
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioPlugInPropertyTranslateUIDToDevice:
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
        }
    }

    status = Object::GetPropertyDataSize(
        objectID, clientPID, address, qualifierDataSize, qualifierData, outDataSize);

end:
    GetContext()->Tracer->OperationEnd(op, status);
    return status;
}

OSStatus Plugin::GetPropertyData(AudioObjectID objectID,
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
    op.Name = "Plugin::GetPropertyData()";
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
        case kAudioObjectPropertyManufacturer:
            {
                if (inDataSize < sizeof(CFStringRef)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(CFStringRef)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(CFStringRef);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetManufacturer();
                    Convert::ToFoundation(
                        value,
                        *static_cast<CFStringRef*>(outData));
                    GetContext()->Tracer->Message(
                        "returning Manufacturer=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioPlugInPropertyResourceBundle:
            {
                if (inDataSize < sizeof(CFStringRef)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(CFStringRef)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(CFStringRef);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetResourceBundlePath();
                    Convert::ToFoundation(
                        value,
                        *static_cast<CFStringRef*>(outData));
                    GetContext()->Tracer->Message(
                        "returning ResourceBundlePath=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioPlugInPropertyDeviceList:
            {
                const auto values = GetDeviceIDs();
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
                        "returning DeviceIDs=%s (%u/%u)",
                        Convert::ToString(values).c_str(),
                        unsigned(valuesCount),
                        unsigned(values.size()));
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioPlugInPropertyTranslateUIDToDevice:
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
                    if (qualifierDataSize != sizeof(CFStringRef)) {
                        GetContext()->Tracer->Message(
                            "invalid qualifier size: should be %u, got %u",
                            unsigned(sizeof(CFStringRef)),
                            unsigned(qualifierDataSize));
                        status = kAudioHardwareBadPropertySizeError;
                        goto end;
                    }
                    std::remove_cv_t<std::remove_reference_t<method_argument_type_t<
                        decltype(&Plugin::GetDeviceIDByUID), 0>>> qualifierValue;
                    Convert::FromFoundation(
                        *static_cast<const CFStringRef*>(qualifierData),
                        qualifierValue);
                    GetContext()->Tracer->Message(
                        "obtained qualifier DeviceIDByUID=%s",
                        Convert::ToString(qualifierValue).c_str());
                    const auto value = GetDeviceIDByUID(qualifierValue);
                    Convert::ToFoundation(
                        value,
                        *static_cast<AudioObjectID*>(outData));
                    GetContext()->Tracer->Message(
                        "returning DeviceIDByUID=%s",
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

OSStatus Plugin::SetPropertyData(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32 inDataSize,
    const void* inData)
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "Plugin::SetPropertyData()";
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

    status = Object::SetPropertyData(
        objectID, clientPID, address, qualifierDataSize, qualifierData, inDataSize, inData);

end:
    GetContext()->Tracer->OperationEnd(op, status);
    return status;
}

} // namespace aspl
