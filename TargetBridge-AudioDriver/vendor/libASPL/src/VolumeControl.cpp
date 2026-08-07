// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/Compat.hpp>
#include <aspl/VolumeControl.hpp>

#include "Convert.hpp"
#include "VolumeCurve.hpp"

#include <algorithm>

namespace aspl {

VolumeControl::VolumeControl(std::shared_ptr<const Context> context,
    const VolumeControlParameters& params)
    : Object(std::move(context), "VolumeControl")
    , params_(params)
    , volumeCurve_(std::make_unique<VolumeCurve>())
    , rawVolume_(params_.MaxRawVolume)
{
    volumeCurve_->AddRange(params_.MinRawVolume,
        params_.MaxRawVolume,
        params_.MinDecibelVolume,
        params_.MaxDecibelVolume);
}

AudioObjectPropertyScope VolumeControl::GetScope() const
{
    return params_.Scope;
}

AudioObjectPropertyElement VolumeControl::GetElement() const
{
    return kAudioObjectPropertyElementMain;
}

SInt32 VolumeControl::GetRawValue() const
{
    return rawVolume_;
}

OSStatus VolumeControl::SetRawValue(SInt32 value)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "VolumeControl::SetRawValue()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;

    if (value == GetRawValue()) {
        GetContext()->Tracer->Message("value not changed");
        goto end;
    }

    GetContext()->Tracer->Message(
        "setting raw value to %s", Convert::ToString(value).c_str());

    status = SetRawValueImpl(value);
    if (status != kAudioHardwareNoError) {
        GetContext()->Tracer->Message("SetRawValueImpl() failed");
        goto end;
    }

    NotifyPropertiesChanged(
        {kAudioLevelControlPropertyScalarValue, kAudioLevelControlPropertyDecibelValue},
        GetScope(),
        GetElement());

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus VolumeControl::SetRawValueImpl(SInt32 value)
{
    value = std::min(value, volumeCurve_->GetMaximumRaw());
    value = std::max(value, volumeCurve_->GetMinimumRaw());

    rawVolume_ = value;

    return kAudioHardwareNoError;
}

Float32 VolumeControl::GetDecibelValue() const
{
    return volumeCurve_->ConvertRawToDB(rawVolume_);
}

OSStatus VolumeControl::SetDecibelValue(Float32 value)
{
    Tracer::Operation op;
    op.Name = "VolumeControl::SetDecibelValue()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    value = std::min(value, volumeCurve_->GetMaximumDB());
    value = std::max(value, volumeCurve_->GetMinimumDB());

    const OSStatus status = SetRawValue(volumeCurve_->ConvertDBToRaw(value));

    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

Float32 VolumeControl::GetScalarValue() const
{
    return volumeCurve_->ConvertRawToScalar(rawVolume_);
}

OSStatus VolumeControl::SetScalarValue(Float32 value)
{
    Tracer::Operation op;
    op.Name = "VolumeControl::SetScalarValue()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    value = std::min(value, 1.0f);
    value = std::max(value, 0.0f);

    const OSStatus status = SetRawValue(volumeCurve_->ConvertScalarToRaw(value));

    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

AudioValueRange VolumeControl::GetRawRange() const
{
    AudioValueRange range = {};

    range.mMinimum = volumeCurve_->GetMinimumRaw();
    range.mMaximum = volumeCurve_->GetMaximumRaw();

    return range;
}

AudioValueRange VolumeControl::GetDecibelRange() const
{
    AudioValueRange range = {};

    range.mMinimum = volumeCurve_->GetMinimumDB();
    range.mMaximum = volumeCurve_->GetMaximumDB();

    return range;
}

Float32 VolumeControl::ConvertScalarToDecibels(Float32 value) const
{
    value = std::min(value, 1.0f);
    value = std::max(value, 0.0f);

    return volumeCurve_->ConvertScalarToDB(value);
}

Float32 VolumeControl::ConvertDecibelsToScalar(Float32 value) const
{
    value = std::min(value, volumeCurve_->GetMaximumDB());
    value = std::max(value, volumeCurve_->GetMinimumDB());

    return volumeCurve_->ConvertDBToScalar(value);
}

void VolumeControl::ApplyProcessing(Float32* frames,
    UInt32 frameCount,
    UInt32 channelCount) const
{
    const Float32 volume = GetScalarValue();

    for (UInt32 i = 0; i < frameCount * channelCount; i++) {
        Float32 s = frames[i] * volume;

        s = std::min(s, 1.0f);
        s = std::max(s, -1.0f);

        frames[i] = s;
    }
}

} // namespace aspl
