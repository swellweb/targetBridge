// THIS FILE IS AUTO-GENERATED. DO NOT EDIT!

// Generator: generate-accessors.py
// Source: VolumeControl.json
// Timestamp: Sun Apr 13 14:12:49 2025 UTC

// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/VolumeControl.hpp>

#include "Compare.hpp"
#include "Convert.hpp"
#include "Traits.hpp"

#include <algorithm>

namespace aspl {

AudioClassID VolumeControl::GetClass() const
{
    return kAudioVolumeControlClassID;
}

AudioClassID VolumeControl::GetBaseClass() const
{
    return kAudioLevelControlClassID;
}

bool VolumeControl::IsInstance(AudioClassID classID) const
{
    switch (classID) {
    case kAudioVolumeControlClassID:
    case kAudioLevelControlClassID:
    case kAudioControlClassID:
    case kAudioObjectClassID:
        return true;
    default:
        return false;
    }
}

Boolean VolumeControl::HasProperty(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address) const
{
    Boolean result = false;

    Tracer::Operation op;
    op.Name = "VolumeControl::HasProperty()";
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
        case kAudioLevelControlPropertyScalarValue:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioLevelControlPropertyDecibelValue:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioLevelControlPropertyDecibelRange:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
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

OSStatus VolumeControl::IsPropertySettable(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    Boolean* outIsSettable) const
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "VolumeControl::IsPropertySettable()";
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
        case kAudioLevelControlPropertyScalarValue:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=true");
                    *outIsSettable = true;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioLevelControlPropertyDecibelValue:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=true");
                    *outIsSettable = true;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioLevelControlPropertyDecibelRange:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
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

OSStatus VolumeControl::GetPropertyDataSize(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32* outDataSize) const
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "VolumeControl::GetPropertyDataSize()";
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
        case kAudioLevelControlPropertyScalarValue:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(Float32);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioLevelControlPropertyDecibelValue:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(Float32);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioLevelControlPropertyDecibelRange:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(AudioValueRange);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(Float32);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(Float32);
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

OSStatus VolumeControl::GetPropertyData(AudioObjectID objectID,
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
    op.Name = "VolumeControl::GetPropertyData()";
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
        case kAudioLevelControlPropertyScalarValue:
            {
                if (inDataSize < sizeof(Float32)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(Float32)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(Float32);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetScalarValue();
                    Convert::ToFoundation(
                        value,
                        *static_cast<Float32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning ScalarValue=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioLevelControlPropertyDecibelValue:
            {
                if (inDataSize < sizeof(Float32)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(Float32)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(Float32);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetDecibelValue();
                    Convert::ToFoundation(
                        value,
                        *static_cast<Float32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning DecibelValue=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioLevelControlPropertyDecibelRange:
            {
                if (inDataSize < sizeof(AudioValueRange)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(AudioValueRange)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(AudioValueRange);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetDecibelRange();
                    Convert::ToFoundation(
                        value,
                        *static_cast<AudioValueRange*>(outData));
                    GetContext()->Tracer->Message(
                        "returning DecibelRange=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            {
                if (inDataSize < sizeof(Float32)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(Float32)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(Float32);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    std::remove_cv_t<std::remove_reference_t<method_return_type_t<
                        decltype(&VolumeControl::ConvertScalarToDecibels)>>> inputValue;
                    Convert::FromFoundation(
                        *static_cast<const Float32*>(outData),
                        inputValue);
                    GetContext()->Tracer->Message(
                        "obtained input ScalarToDecibels=%s",
                        Convert::ToString(inputValue).c_str());
                    const auto value = ConvertScalarToDecibels(inputValue);
                    Convert::ToFoundation(
                        value,
                        *static_cast<Float32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning ScalarToDecibels=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            {
                if (inDataSize < sizeof(Float32)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(Float32)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(Float32);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    std::remove_cv_t<std::remove_reference_t<method_return_type_t<
                        decltype(&VolumeControl::ConvertDecibelsToScalar)>>> inputValue;
                    Convert::FromFoundation(
                        *static_cast<const Float32*>(outData),
                        inputValue);
                    GetContext()->Tracer->Message(
                        "obtained input DecibelsToScalar=%s",
                        Convert::ToString(inputValue).c_str());
                    const auto value = ConvertDecibelsToScalar(inputValue);
                    Convert::ToFoundation(
                        value,
                        *static_cast<Float32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning DecibelsToScalar=%s",
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

OSStatus VolumeControl::SetPropertyData(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32 inDataSize,
    const void* inData)
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "VolumeControl::SetPropertyData()";
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
        case kAudioLevelControlPropertyScalarValue:
            {
                if (inDataSize != sizeof(Float32)) {
                    GetContext()->Tracer->Message("invalid size: should be %u, got %u",
                        unsigned(sizeof(Float32)), unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (!inData) {
                    GetContext()->Tracer->Message("input buffer is null");
                    status = kAudioHardwareIllegalOperationError;
                    goto end;
                }
                std::remove_cv_t<std::remove_reference_t<
                    decltype(GetScalarValue())>> value;
                Convert::FromFoundation(
                    *static_cast<const Float32*>(inData),
                    value);
                GetContext()->Tracer->Message(
                    "setting ScalarValue=%s",
                    Convert::ToString(value).c_str());
                status = SetScalarValue(std::move(value));
                if (status != kAudioHardwareNoError) {
                    GetContext()->Tracer->Message("setter failed");
                    goto end;
                }
            }
            goto end;
        case kAudioLevelControlPropertyDecibelValue:
            {
                if (inDataSize != sizeof(Float32)) {
                    GetContext()->Tracer->Message("invalid size: should be %u, got %u",
                        unsigned(sizeof(Float32)), unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (!inData) {
                    GetContext()->Tracer->Message("input buffer is null");
                    status = kAudioHardwareIllegalOperationError;
                    goto end;
                }
                std::remove_cv_t<std::remove_reference_t<
                    decltype(GetDecibelValue())>> value;
                Convert::FromFoundation(
                    *static_cast<const Float32*>(inData),
                    value);
                GetContext()->Tracer->Message(
                    "setting DecibelValue=%s",
                    Convert::ToString(value).c_str());
                status = SetDecibelValue(std::move(value));
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
