// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/VolumeControl.hpp
//! @brief Volume control object.

#pragma once

#include <aspl/Direction.hpp>
#include <aspl/Object.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <atomic>
#include <memory>
#include <mutex>

namespace aspl {

class VolumeCurve;

//! Volume control parameters.
struct VolumeControlParameters
{
    //! Define whether this is input or output control.
    //! Used by default implementation of VolumeControl::GetScope().
    AudioObjectPropertyScope Scope = kAudioObjectPropertyScopeOutput;

    //! Minimum volume value in raw units.
    SInt32 MinRawVolume = 0;

    //! Maximum volume value in raw units.
    SInt32 MaxRawVolume = 96;

    //! Minimum volume value in decibel units.
    Float32 MinDecibelVolume = -96.0f;

    //! Maximum volume value in decibel units.
    Float32 MaxDecibelVolume = 0.0f;
};

//! Volume control object.
//!
//! Volumes can be represented using three scales:
//!  - raw - integer amplitude amplifier, custom range
//!  - decibels - floating point logarithmic scale, custom range
//!  - scalar - floating point logarithmic scale, range [0; 1]
//!
//! Decibels and raw scales are linearly related.
//!
//! The raw scale is intended for computations. The scalar scale is used by macOS
//! for volume sliders.
//!
//! Default implementation of VolumeControl stores volumes in the raw scale and
//! convert it on fly to/from other scales when requested.
//!
//! Volume control does not affect I/O by its own. It just stores the volume and
//! provides ApplyProcessing() method which modifies given samples according to
//! the volume.
//!
//! You can attach VolumeControl to Stream using Stream::AttachVolumeControl()
//! method, and then stream will use it to process samples passed to stream.
//! Alternatively, you can invoke VolumeControls manually the way you need.
class VolumeControl : public Object
{
public:
    //! Construct stream.
    explicit VolumeControl(std::shared_ptr<const Context> context,
        const VolumeControlParameters& params = {});

    //! @name Getters and setters
    //! @{

    //! Get the scope that the control is attached to.
    //! Can return kAudioObjectPropertyScopeInput or kAudioObjectPropertyScopeOutput.
    //! By default returns VolumeControlParameters::Scope.
    //! @note
    //!  Backs @c kAudioControlPropertyScope property.
    virtual AudioObjectPropertyScope GetScope() const;

    //! Get the element that the control is attached to.
    //! Typically should return kAudioObjectPropertyElementMain.
    //! By default returns kAudioObjectPropertyElementMain.
    //! @note
    //!  Backs @c kAudioControlPropertyElement property.
    virtual AudioObjectPropertyElement GetElement() const;

    //! Get current volume, in raw units.
    //! Values are in range GetRawRange().
    virtual SInt32 GetRawValue() const;

    //! Set current volume, in raw units.
    //! Values are in range GetRawRange().
    //! Invokes by SetRawValueImpl() and NotifyPropertiesChanged().
    OSStatus SetRawValue(SInt32 value);

    //! Get current volume, in decibel units.
    //! Values are in range GetDecibelRange().
    //! @note
    //!  Backs @c kAudioLevelControlPropertyDecibelValue property.
    virtual Float32 GetDecibelValue() const;

    //! Get current volume, in decibel units.
    //! Values are in range GetDecibelRange().
    //! Invokes by SetRawValue().
    //! @note
    //!  Backs @c kAudioLevelControlPropertyDecibelValue property.
    virtual OSStatus SetDecibelValue(Float32 value);

    //! Get current volume, in scalar units.
    //! Values are in range [0; 1].
    //! @note
    //!  Backs @c kAudioLevelControlPropertyScalarValue property.
    virtual Float32 GetScalarValue() const;

    //! Set current volume, in scalar units.
    //! Values are in range [0; 1].
    //! Invokes by SetRawValue().
    //! @note
    //!  Backs @c kAudioLevelControlPropertyScalarValue property.
    virtual OSStatus SetScalarValue(Float32 value);

    //! Get minimum and maximum volume values, in raw units.
    //! Default implementation returns range based on VolumeControlParameters.
    virtual AudioValueRange GetRawRange() const;

    //! Get minimum and maximum volume values, in decibel units.
    //! Default implementation returns range based on VolumeControlParameters.
    //! @note
    //!  Backs @c kAudioLevelControlPropertyDecibelRange property.
    virtual AudioValueRange GetDecibelRange() const;

    //! Convert volume from scalar scale to decibel scale.
    //! Default implementation performs conversion based on VolumeControlParameters.
    //! @note
    //!  Backs @c kAudioLevelControlPropertyConvertScalarToDecibels property.
    virtual Float32 ConvertScalarToDecibels(Float32 value) const;

    //! Convert volume from decibel scale to scalar scale.
    //! Default implementation performs conversion based on VolumeControlParameters.
    //! @note
    //!  Backs @c kAudioLevelControlPropertyConvertDecibelsToScalar property.
    virtual Float32 ConvertDecibelsToScalar(Float32 value) const;

    //! @}

    //! @name Processing
    //! @{

    //! Apply processing to given buffer.
    //! The provided buffer contains exactly @p frameCount * @p channelCount samples.
    //! The provides samples are scalled according to the current GetScalarValue().
    //! @note
    //!  Invoked by Stream::ApplyProcessing() on realtime thread.
    virtual void ApplyProcessing(Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) const;

    //! @}

    //! @name Property dispath
    //! @{

    //! Get class ID.
    AudioClassID GetClass() const override;

    //! Get base class ID.
    AudioClassID GetBaseClass() const override;

    //! Check if this object is instance of given base class.
    bool IsInstance(AudioClassID classID) const override;

    //! Check whether given property is present.
    Boolean HasProperty(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address) const override;

    //! Check whether given property can be changed.
    OSStatus IsPropertySettable(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        Boolean* outIsSettable) const override;

    //! Get size of property value in bytes.
    OSStatus GetPropertyDataSize(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32* outDataSize) const override;

    //! Get property value.
    OSStatus GetPropertyData(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32 inDataSize,
        UInt32* outDataSize,
        void* outData) const override;

    //! Change property value.
    OSStatus SetPropertyData(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32 inDataSize,
        const void* inData) override;

    //! @}

protected:
    //! @name Setters implementation
    //! @{

    //! Set current volume, in raw units.
    //! Values are in range GetRawRange().
    //! Invoked by SetRawValue().
    virtual OSStatus SetRawValueImpl(SInt32 value);

    //! @}

private:
    const VolumeControlParameters params_;
    const std::unique_ptr<VolumeCurve> volumeCurve_;

    std::mutex writeMutex_;
    std::atomic<SInt32> rawVolume_ = 0;
};

} // namespace aspl
