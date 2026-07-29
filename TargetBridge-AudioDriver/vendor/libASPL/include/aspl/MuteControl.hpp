// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/MuteControl.hpp
//! @brief Mute control object.

#pragma once

#include <aspl/Direction.hpp>
#include <aspl/Object.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <atomic>
#include <mutex>

namespace aspl {

//! Mute control parameters.
struct MuteControlParameters
{
    //! Define whether this is input or output control.
    //! Used by default implementation of MuteControl::GetScope().
    AudioObjectPropertyScope Scope = kAudioObjectPropertyScopeOutput;
};

//! Mute control object.
//!
//! Stores a boolean state, indicating whether something is muted or not.
//!
//! Mute control does not affect I/O by its own. It just stores the mute flag
//! and provides ApplyProcessing() method which zeroises provided samples if
//! the mute flag is set.
//!
//! You can attach MuteControl to the Stream using Stream::AttachMuteControl()
//! method, and then stream will use it to process samples passed to stream.
//! Alternatively, you can invoke MuteControls manually the way you need.
class MuteControl : public Object
{
public:
    //! Construct stream.
    explicit MuteControl(std::shared_ptr<const Context> context,
        const MuteControlParameters& params = {});

    //! @name Getters and setters
    //! @{

    //! Get the scope that the control is attached to.
    //! Can return kAudioObjectPropertyScopeInput or kAudioObjectPropertyScopeOutput.
    //! By default returns MuteControlParameters::Scope.
    //! @note
    //!  Backs @c kAudioControlPropertyScope property.
    virtual AudioObjectPropertyScope GetScope() const;

    //! Get the element that the control is attached to.
    //! Typically should return kAudioObjectPropertyElementMain.
    //! By default returns kAudioObjectPropertyElementMain.
    //! @note
    //!  Backs @c kAudioControlPropertyElement property.
    virtual AudioObjectPropertyElement GetElement() const;

    //! Get muted boolean state.
    //! By default returns internal muted state.
    //! Initial value of the flag is false.
    //! @note
    //!  Backs @c kAudioBooleanControlPropertyValue property.
    virtual bool GetIsMuted() const;

    //! Set muted boolean state.
    //! Invokes SetIsMutedImpl() and NotifyPropertiesChanged().
    //! @note
    //!  Backs @c kAudioBooleanControlPropertyValue property.
    OSStatus SetIsMuted(bool isMuted);

    //! @}

    //! @name Processing
    //! @{

    //! Apply processing to given buffer.
    //! The provided buffer contains exactly @p frameCount * @p channelCount samples.
    //! If GetIsMuted() is false, this method does nothing.
    //! If GetIsMuted() is true, this method overrides all samples with zeros.
    //! @note
    //!  Invoked by Stream::ApplyProcessing() on realtime thread.
    virtual void ApplyProcessing(Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) const;

    //! @}

    //! @name Property dispatch
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

    //! Set muted boolean state.
    //! Invoked by SetIsMuted().
    //! By default sets internal muted state.
    //! @note
    //!  Backs @c kAudioBooleanControlPropertyValue property.
    virtual OSStatus SetIsMutedImpl(bool isMuted);

    //! @}

private:
    const MuteControlParameters params_;

    std::mutex writeMutex_;
    std::atomic<bool> isMuted_ = false;
};

} // namespace aspl
