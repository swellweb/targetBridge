// THIS FILE IS AUTO-GENERATED. DO NOT EDIT!

// Generator: generate-accessors.py
// Source: Device.json
// Timestamp: Sun Apr 13 14:12:48 2025 UTC

// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/Device.hpp>

#include "Compare.hpp"
#include "Convert.hpp"
#include "Traits.hpp"

#include <algorithm>

namespace aspl {

AudioClassID Device::GetClass() const
{
    return kAudioDeviceClassID;
}

AudioClassID Device::GetBaseClass() const
{
    return kAudioObjectClassID;
}

bool Device::IsInstance(AudioClassID classID) const
{
    switch (classID) {
    case kAudioDeviceClassID:
    case kAudioObjectClassID:
        return true;
    default:
        return false;
    }
}

OSStatus Device::SetLatencyAsync(UInt32 value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::SetLatencyAsync()";
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
        op.Name = "Device::SetLatencyImpl()";
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

OSStatus Device::SetSafetyOffsetAsync(UInt32 value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::SetSafetyOffsetAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetSafetyOffset()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    RequestConfigurationChange([this, value = std::move(value)]() mutable {
        std::lock_guard writeLock(writeMutex_);

        Tracer::Operation op;
        op.Name = "Device::SetSafetyOffsetImpl()";
        op.ObjectID = GetID();

        GetContext()->Tracer->OperationBegin(op);

        OSStatus status = kAudioHardwareNoError;

        if (value == GetSafetyOffset()) {
            GetContext()->Tracer->Message("value not changed");
        } else {
            GetContext()->Tracer->Message("setting value to %s",
                Convert::ToString(value).c_str());

            status = SetSafetyOffsetImpl(std::move(value));
        }

        GetContext()->Tracer->OperationEnd(op, status);
    });

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::SetZeroTimeStampPeriodAsync(UInt32 value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::SetZeroTimeStampPeriodAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetZeroTimeStampPeriod()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    RequestConfigurationChange([this, value = std::move(value)]() mutable {
        std::lock_guard writeLock(writeMutex_);

        Tracer::Operation op;
        op.Name = "Device::SetZeroTimeStampPeriodImpl()";
        op.ObjectID = GetID();

        GetContext()->Tracer->OperationBegin(op);

        OSStatus status = kAudioHardwareNoError;

        if (value == GetZeroTimeStampPeriod()) {
            GetContext()->Tracer->Message("value not changed");
        } else {
            GetContext()->Tracer->Message("setting value to %s",
                Convert::ToString(value).c_str());

            status = SetZeroTimeStampPeriodImpl(std::move(value));
        }

        GetContext()->Tracer->OperationEnd(op, status);
    });

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::SetNominalSampleRateAsync(Float64 value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::SetNominalSampleRateAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetNominalSampleRate()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    status = CheckNominalSampleRate(value);
    if (status != kAudioHardwareNoError) {
        GetContext()->Tracer->Message("value is invalid");
        goto end;
    }

    RequestConfigurationChange([this, value = std::move(value)]() mutable {
        std::lock_guard writeLock(writeMutex_);

        Tracer::Operation op;
        op.Name = "Device::SetNominalSampleRateImpl()";
        op.ObjectID = GetID();

        GetContext()->Tracer->OperationBegin(op);

        OSStatus status = kAudioHardwareNoError;

        if (value == GetNominalSampleRate()) {
            GetContext()->Tracer->Message("value not changed");
        } else {
            GetContext()->Tracer->Message("setting value to %s",
                Convert::ToString(value).c_str());

            status = SetNominalSampleRateImpl(std::move(value));
        }

        GetContext()->Tracer->OperationEnd(op, status);
    });

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::SetAvailableSampleRatesAsync(std::vector<AudioValueRange> value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::SetAvailableSampleRatesAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetAvailableSampleRates()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    RequestConfigurationChange([this, value = std::move(value)]() mutable {
        std::lock_guard writeLock(writeMutex_);

        Tracer::Operation op;
        op.Name = "Device::SetAvailableSampleRatesImpl()";
        op.ObjectID = GetID();

        GetContext()->Tracer->OperationBegin(op);

        OSStatus status = kAudioHardwareNoError;

        if (value == GetAvailableSampleRates()) {
            GetContext()->Tracer->Message("value not changed");
        } else {
            GetContext()->Tracer->Message("setting value to %s",
                Convert::ToString(value).c_str());

            status = SetAvailableSampleRatesImpl(std::move(value));
        }

        GetContext()->Tracer->OperationEnd(op, status);
    });

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::SetPreferredChannelsForStereoAsync(std::array<UInt32, 2> value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::SetPreferredChannelsForStereoAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetPreferredChannelsForStereo()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    RequestConfigurationChange([this, value = std::move(value)]() mutable {
        std::lock_guard writeLock(writeMutex_);

        Tracer::Operation op;
        op.Name = "Device::SetPreferredChannelsForStereoImpl()";
        op.ObjectID = GetID();

        GetContext()->Tracer->OperationBegin(op);

        OSStatus status = kAudioHardwareNoError;

        if (value == GetPreferredChannelsForStereo()) {
            GetContext()->Tracer->Message("value not changed");
        } else {
            GetContext()->Tracer->Message("setting value to %s",
                Convert::ToString(value).c_str());

            status = SetPreferredChannelsForStereoImpl(std::move(value));
        }

        GetContext()->Tracer->OperationEnd(op, status);
    });

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::SetPreferredChannelCountAsync(UInt32 value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::SetPreferredChannelCountAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetPreferredChannelCount()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    RequestConfigurationChange([this, value = std::move(value)]() mutable {
        std::lock_guard writeLock(writeMutex_);

        Tracer::Operation op;
        op.Name = "Device::SetPreferredChannelCountImpl()";
        op.ObjectID = GetID();

        GetContext()->Tracer->OperationBegin(op);

        OSStatus status = kAudioHardwareNoError;

        if (value == GetPreferredChannelCount()) {
            GetContext()->Tracer->Message("value not changed");
        } else {
            GetContext()->Tracer->Message("setting value to %s",
                Convert::ToString(value).c_str());

            status = SetPreferredChannelCountImpl(std::move(value));
        }

        GetContext()->Tracer->OperationEnd(op, status);
    });

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::SetPreferredChannelsAsync(std::vector<AudioChannelDescription> value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::SetPreferredChannelsAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetPreferredChannels()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    RequestConfigurationChange([this, value = std::move(value)]() mutable {
        std::lock_guard writeLock(writeMutex_);

        Tracer::Operation op;
        op.Name = "Device::SetPreferredChannelsImpl()";
        op.ObjectID = GetID();

        GetContext()->Tracer->OperationBegin(op);

        OSStatus status = kAudioHardwareNoError;

        if (value == GetPreferredChannels()) {
            GetContext()->Tracer->Message("value not changed");
        } else {
            GetContext()->Tracer->Message("setting value to %s",
                Convert::ToString(value).c_str());

            status = SetPreferredChannelsImpl(std::move(value));
        }

        GetContext()->Tracer->OperationEnd(op, status);
    });

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::SetPreferredChannelLayoutAsync(std::vector<UInt8> value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::SetPreferredChannelLayoutAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetPreferredChannelLayout()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    RequestConfigurationChange([this, value = std::move(value)]() mutable {
        std::lock_guard writeLock(writeMutex_);

        Tracer::Operation op;
        op.Name = "Device::SetPreferredChannelLayoutImpl()";
        op.ObjectID = GetID();

        GetContext()->Tracer->OperationBegin(op);

        OSStatus status = kAudioHardwareNoError;

        if (value == GetPreferredChannelLayout()) {
            GetContext()->Tracer->Message("value not changed");
        } else {
            GetContext()->Tracer->Message("setting value to %s",
                Convert::ToString(value).c_str());

            status = SetPreferredChannelLayoutImpl(std::move(value));
        }

        GetContext()->Tracer->OperationEnd(op, status);
    });

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::SetIsIdentifying(bool value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::SetIsIdentifying()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetIsIdentifying()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    GetContext()->Tracer->Message("setting value to %s",
        Convert::ToString(value).c_str());

    status = SetIsIdentifyingImpl(value);
    if (status != kAudioHardwareNoError) {
        GetContext()->Tracer->Message("setter failed");
        goto end;
    }

    NotifyPropertyChanged(kAudioObjectPropertyIdentify);

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::SetIsAlive(bool value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::SetIsAlive()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetIsAlive()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    GetContext()->Tracer->Message("setting value to %s",
        Convert::ToString(value).c_str());

    status = SetIsAliveImpl(value);
    if (status != kAudioHardwareNoError) {
        GetContext()->Tracer->Message("setter failed");
        goto end;
    }

    NotifyPropertyChanged(kAudioDevicePropertyDeviceIsAlive);

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::SetIsHidden(bool value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::SetIsHidden()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetIsHidden()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    GetContext()->Tracer->Message("setting value to %s",
        Convert::ToString(value).c_str());

    status = SetIsHiddenImpl(value);
    if (status != kAudioHardwareNoError) {
        GetContext()->Tracer->Message("setter failed");
        goto end;
    }

    NotifyPropertyChanged(kAudioDevicePropertyIsHidden);

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::SetCanBeDefaultDevice(bool value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::SetCanBeDefaultDevice()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetCanBeDefaultDevice()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    GetContext()->Tracer->Message("setting value to %s",
        Convert::ToString(value).c_str());

    status = SetCanBeDefaultDeviceImpl(value);
    if (status != kAudioHardwareNoError) {
        GetContext()->Tracer->Message("setter failed");
        goto end;
    }

    NotifyPropertyChanged(kAudioDevicePropertyDeviceCanBeDefaultDevice);

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::SetCanBeDefaultSystemDevice(bool value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::SetCanBeDefaultSystemDevice()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetCanBeDefaultSystemDevice()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    GetContext()->Tracer->Message("setting value to %s",
        Convert::ToString(value).c_str());

    status = SetCanBeDefaultSystemDeviceImpl(value);
    if (status != kAudioHardwareNoError) {
        GetContext()->Tracer->Message("setter failed");
        goto end;
    }

    NotifyPropertyChanged(kAudioDevicePropertyDeviceCanBeDefaultSystemDevice);

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

Boolean Device::HasProperty(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address) const
{
    Boolean result = false;

    Tracer::Operation op;
    op.Name = "Device::HasProperty()";
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
        case kAudioObjectPropertyName:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioObjectPropertyManufacturer:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyDeviceUID:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyModelUID:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioObjectPropertySerialNumber:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioObjectPropertyFirmwareVersion:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyIcon:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyConfigurationApplication:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyTransportType:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyRelatedDevices:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyClockIsStable:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyClockAlgorithm:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyClockDomain:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyLatency:
            {
                switch (address->mScope) {
                case kAudioObjectPropertyScopeInput:
                case kAudioObjectPropertyScopeOutput:
                    {
                        GetContext()->Tracer->Message("returning HasProperty=true");
                        result = true;
                    }
                    break;
                default:
                    {
                        GetContext()->Tracer->Message(
                            "returning HasProperty=false (disallowed scope)");
                        result = false;
                    }
                    break;
                }
            }
            goto end;
        case kAudioDevicePropertySafetyOffset:
            {
                switch (address->mScope) {
                case kAudioObjectPropertyScopeInput:
                case kAudioObjectPropertyScopeOutput:
                    {
                        GetContext()->Tracer->Message("returning HasProperty=true");
                        result = true;
                    }
                    break;
                default:
                    {
                        GetContext()->Tracer->Message(
                            "returning HasProperty=false (disallowed scope)");
                        result = false;
                    }
                    break;
                }
            }
            goto end;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyNominalSampleRate:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            {
                switch (address->mScope) {
                case kAudioObjectPropertyScopeInput:
                case kAudioObjectPropertyScopeOutput:
                    {
                        GetContext()->Tracer->Message("returning HasProperty=true");
                        result = true;
                    }
                    break;
                default:
                    {
                        GetContext()->Tracer->Message(
                            "returning HasProperty=false (disallowed scope)");
                        result = false;
                    }
                    break;
                }
            }
            goto end;
        case kAudioDevicePropertyPreferredChannelLayout:
            {
                switch (address->mScope) {
                case kAudioObjectPropertyScopeInput:
                case kAudioObjectPropertyScopeOutput:
                    {
                        GetContext()->Tracer->Message("returning HasProperty=true");
                        result = true;
                    }
                    break;
                default:
                    {
                        GetContext()->Tracer->Message(
                            "returning HasProperty=false (disallowed scope)");
                        result = false;
                    }
                    break;
                }
            }
            goto end;
        case kAudioDevicePropertyDeviceIsRunning:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioObjectPropertyIdentify:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyDeviceIsAlive:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyIsHidden:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            {
                switch (address->mScope) {
                case kAudioObjectPropertyScopeInput:
                case kAudioObjectPropertyScopeOutput:
                    {
                        GetContext()->Tracer->Message("returning HasProperty=true");
                        result = true;
                    }
                    break;
                default:
                    {
                        GetContext()->Tracer->Message(
                            "returning HasProperty=false (disallowed scope)");
                        result = false;
                    }
                    break;
                }
            }
            goto end;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            {
                switch (address->mScope) {
                case kAudioObjectPropertyScopeInput:
                case kAudioObjectPropertyScopeOutput:
                    {
                        GetContext()->Tracer->Message("returning HasProperty=true");
                        result = true;
                    }
                    break;
                default:
                    {
                        GetContext()->Tracer->Message(
                            "returning HasProperty=false (disallowed scope)");
                        result = false;
                    }
                    break;
                }
            }
            goto end;
        case kAudioDevicePropertyStreams:
            {
                GetContext()->Tracer->Message("returning HasProperty=true");
                result = true;
            }
            goto end;
        case kAudioObjectPropertyControlList:
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

OSStatus Device::IsPropertySettable(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    Boolean* outIsSettable) const
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "Device::IsPropertySettable()";
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
        case kAudioObjectPropertyName:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
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
        case kAudioDevicePropertyDeviceUID:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyModelUID:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertySerialNumber:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyFirmwareVersion:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyIcon:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyConfigurationApplication:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyTransportType:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyRelatedDevices:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyClockIsStable:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyClockAlgorithm:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyClockDomain:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyLatency:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertySafetyOffset:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyNominalSampleRate:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=true");
                    *outIsSettable = true;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyPreferredChannelLayout:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyDeviceIsRunning:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyIdentify:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=true");
                    *outIsSettable = true;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyDeviceIsAlive:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyIsHidden:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyStreams:
            {
                if (outIsSettable) {
                    GetContext()->Tracer->Message("returning IsSettable=false");
                    *outIsSettable = false;
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyControlList:
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

OSStatus Device::GetPropertyDataSize(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32* outDataSize) const
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "Device::GetPropertyDataSize()";
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
        case kAudioObjectPropertyName:
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
        case kAudioDevicePropertyDeviceUID:
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
        case kAudioDevicePropertyModelUID:
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
        case kAudioObjectPropertySerialNumber:
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
        case kAudioObjectPropertyFirmwareVersion:
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
        case kAudioDevicePropertyIcon:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(CFURLRef);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyConfigurationApplication:
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
        case kAudioDevicePropertyTransportType:
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
        case kAudioDevicePropertyRelatedDevices:
            {
                if (outDataSize) {
                    const auto values = GetRelatedDeviceIDs();
                    *outDataSize = UInt32(values.size()
                        * sizeof(AudioObjectID));
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyClockIsStable:
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
        case kAudioDevicePropertyClockAlgorithm:
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
        case kAudioDevicePropertyClockDomain:
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
        case kAudioDevicePropertyLatency:
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
        case kAudioDevicePropertySafetyOffset:
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
        case kAudioDevicePropertyZeroTimeStampPeriod:
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
        case kAudioDevicePropertyNominalSampleRate:
            {
                if (outDataSize) {
                    *outDataSize = sizeof(Float64);
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            {
                if (outDataSize) {
                    const auto values = GetAvailableSampleRates();
                    *outDataSize = UInt32(values.size()
                        * sizeof(AudioValueRange));
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            {
                if (outDataSize) {
                    const auto values = GetPreferredChannelsForStereo();
                    *outDataSize = UInt32(values.size()
                        * sizeof(UInt32));
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyPreferredChannelLayout:
            {
                if (outDataSize) {
                    const auto values = GetPreferredChannelLayout();
                    *outDataSize = UInt32(values.size()
                        * sizeof(UInt8));
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyDeviceIsRunning:
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
        case kAudioObjectPropertyIdentify:
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
        case kAudioDevicePropertyDeviceIsAlive:
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
        case kAudioDevicePropertyIsHidden:
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
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
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
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
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
        case kAudioDevicePropertyStreams:
            {
                if (outDataSize) {
                    const auto values = GetStreamIDs(address->mScope);
                    *outDataSize = UInt32(values.size()
                        * sizeof(AudioObjectID));
                    GetContext()->Tracer->Message("returning PropertySize=%u",
                        unsigned(*outDataSize));
                } else {
                    GetContext()->Tracer->Message("output buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyControlList:
            {
                if (outDataSize) {
                    const auto values = GetControlIDs();
                    *outDataSize = UInt32(values.size()
                        * sizeof(AudioObjectID));
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

OSStatus Device::GetPropertyData(AudioObjectID objectID,
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
    op.Name = "Device::GetPropertyData()";
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
        case kAudioObjectPropertyName:
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
                    const auto value = GetName();
                    Convert::ToFoundation(
                        value,
                        *static_cast<CFStringRef*>(outData));
                    GetContext()->Tracer->Message(
                        "returning Name=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
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
        case kAudioDevicePropertyDeviceUID:
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
                    const auto value = GetDeviceUID();
                    Convert::ToFoundation(
                        value,
                        *static_cast<CFStringRef*>(outData));
                    GetContext()->Tracer->Message(
                        "returning DeviceUID=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyModelUID:
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
                    const auto value = GetModelUID();
                    Convert::ToFoundation(
                        value,
                        *static_cast<CFStringRef*>(outData));
                    GetContext()->Tracer->Message(
                        "returning ModelUID=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertySerialNumber:
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
                    const auto value = GetSerialNumber();
                    Convert::ToFoundation(
                        value,
                        *static_cast<CFStringRef*>(outData));
                    GetContext()->Tracer->Message(
                        "returning SerialNumber=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyFirmwareVersion:
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
                    const auto value = GetFirmwareVersion();
                    Convert::ToFoundation(
                        value,
                        *static_cast<CFStringRef*>(outData));
                    GetContext()->Tracer->Message(
                        "returning FirmwareVersion=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyIcon:
            {
                if (inDataSize < sizeof(CFURLRef)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(CFURLRef)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(CFURLRef);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetIconURL();
                    Convert::ToFoundation(
                        value,
                        *static_cast<CFURLRef*>(outData));
                    GetContext()->Tracer->Message(
                        "returning IconURL=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyConfigurationApplication:
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
                    const auto value = GetConfigurationApplicationBundleID();
                    Convert::ToFoundation(
                        value,
                        *static_cast<CFStringRef*>(outData));
                    GetContext()->Tracer->Message(
                        "returning ConfigurationApplicationBundleID=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyTransportType:
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
                    const auto value = GetTransportType();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning TransportType=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyRelatedDevices:
            {
                const auto values = GetRelatedDeviceIDs();
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
                        "returning RelatedDeviceIDs=%s (%u/%u)",
                        Convert::ToString(values).c_str(),
                        unsigned(valuesCount),
                        unsigned(values.size()));
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyClockIsStable:
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
                    const auto value = GetClockIsStable();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning ClockIsStable=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyClockAlgorithm:
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
                    const auto value = GetClockAlgorithm();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning ClockAlgorithm=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyClockDomain:
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
                    const auto value = GetClockDomain();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning ClockDomain=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyLatency:
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
        case kAudioDevicePropertySafetyOffset:
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
                    const auto value = GetSafetyOffset();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning SafetyOffset=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyZeroTimeStampPeriod:
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
                    const auto value = GetZeroTimeStampPeriod();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning ZeroTimeStampPeriod=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyNominalSampleRate:
            {
                if (inDataSize < sizeof(Float64)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(sizeof(Float64)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = sizeof(Float64);
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    const auto value = GetNominalSampleRate();
                    Convert::ToFoundation(
                        value,
                        *static_cast<Float64*>(outData));
                    GetContext()->Tracer->Message(
                        "returning NominalSampleRate=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            {
                const auto values = GetAvailableSampleRates();
                const size_t valuesCount = std::min(
                    inDataSize / sizeof(AudioValueRange),
                    values.size());
                if (outDataSize) {
                    *outDataSize = UInt32(valuesCount
                        * sizeof(AudioValueRange));
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    for (size_t i = 0; i < valuesCount; i++) {
                        Convert::ToFoundation(
                            values[i],
                            static_cast<AudioValueRange*>(outData)[i]);
                    }
                    GetContext()->Tracer->Message(
                        "returning AvailableSampleRates=%s (%u/%u)",
                        Convert::ToString(values).c_str(),
                        unsigned(valuesCount),
                        unsigned(values.size()));
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            {
                const auto values = GetPreferredChannelsForStereo();
                const size_t valuesCount = std::min(
                    inDataSize / sizeof(UInt32),
                    values.size());
                if (outDataSize) {
                    *outDataSize = UInt32(valuesCount
                        * sizeof(UInt32));
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    for (size_t i = 0; i < valuesCount; i++) {
                        Convert::ToFoundation(
                            values[i],
                            static_cast<UInt32*>(outData)[i]);
                    }
                    GetContext()->Tracer->Message(
                        "returning PreferredChannelsForStereo=%s (%u/%u)",
                        Convert::ToString(values).c_str(),
                        unsigned(valuesCount),
                        unsigned(values.size()));
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyPreferredChannelLayout:
            {
                const auto values = GetPreferredChannelLayout();
                const size_t valuesCount = values.size();
                if (inDataSize < valuesCount * sizeof(UInt8)) {
                    GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                        unsigned(valuesCount * sizeof(UInt8)),
                        unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (outDataSize) {
                    *outDataSize = UInt32(valuesCount
                        * sizeof(UInt8));
                } else {
                    GetContext()->Tracer->Message("size buffer is null");
                }
                if (outData) {
                    for (size_t i = 0; i < valuesCount; i++) {
                        Convert::ToFoundation(
                            values[i],
                            static_cast<UInt8*>(outData)[i]);
                    }
                    GetContext()->Tracer->Message(
                        "returning PreferredChannelLayout=%s (%u/%u)",
                        Convert::ToString(values).c_str(),
                        unsigned(valuesCount),
                        unsigned(values.size()));
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyDeviceIsRunning:
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
                    const auto value = GetIsRunning();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning IsRunning=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyIdentify:
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
                    const auto value = GetIsIdentifying();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning IsIdentifying=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyDeviceIsAlive:
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
                    const auto value = GetIsAlive();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning IsAlive=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyIsHidden:
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
                    const auto value = GetIsHidden();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning IsHidden=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
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
                    const auto value = GetCanBeDefaultDevice();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning CanBeDefaultDevice=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
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
                    const auto value = GetCanBeDefaultSystemDevice();
                    Convert::ToFoundation(
                        value,
                        *static_cast<UInt32*>(outData));
                    GetContext()->Tracer->Message(
                        "returning CanBeDefaultSystemDevice=%s",
                        Convert::ToString(value).c_str());
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioDevicePropertyStreams:
            {
                const auto values = GetStreamIDs(address->mScope);
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
                        "returning StreamIDs=%s (%u/%u)",
                        Convert::ToString(values).c_str(),
                        unsigned(valuesCount),
                        unsigned(values.size()));
                } else {
                    GetContext()->Tracer->Message("data buffer is null");
                }
            }
            goto end;
        case kAudioObjectPropertyControlList:
            {
                const auto values = GetControlIDs();
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
                        "returning ControlIDs=%s (%u/%u)",
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

OSStatus Device::SetPropertyData(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32 inDataSize,
    const void* inData)
{
    OSStatus status = kAudioHardwareNoError;

    Tracer::Operation op;
    op.Name = "Device::SetPropertyData()";
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
        case kAudioDevicePropertyNominalSampleRate:
            {
                if (inDataSize != sizeof(Float64)) {
                    GetContext()->Tracer->Message("invalid size: should be %u, got %u",
                        unsigned(sizeof(Float64)), unsigned(inDataSize));
                    status = kAudioHardwareBadPropertySizeError;
                    goto end;
                }
                if (!inData) {
                    GetContext()->Tracer->Message("input buffer is null");
                    status = kAudioHardwareIllegalOperationError;
                    goto end;
                }
                std::remove_cv_t<std::remove_reference_t<
                    decltype(GetNominalSampleRate())>> value;
                Convert::FromFoundation(
                    *static_cast<const Float64*>(inData),
                    value);
                GetContext()->Tracer->Message(
                    "setting NominalSampleRate=%s",
                    Convert::ToString(value).c_str());
                status = SetNominalSampleRateAsync(std::move(value));
                if (status != kAudioHardwareNoError) {
                    GetContext()->Tracer->Message("setter failed");
                    goto end;
                }
            }
            goto end;
        case kAudioObjectPropertyIdentify:
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
                    decltype(GetIsIdentifying())>> value;
                Convert::FromFoundation(
                    *static_cast<const UInt32*>(inData),
                    value);
                GetContext()->Tracer->Message(
                    "setting IsIdentifying=%s",
                    Convert::ToString(value).c_str());
                status = SetIsIdentifying(std::move(value));
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
