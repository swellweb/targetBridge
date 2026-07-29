// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/Stream.hpp
//! @brief Audio stream object.

#pragma once

#include <aspl/Direction.hpp>
#include <aspl/DoubleBuffer.hpp>
#include <aspl/MuteControl.hpp>
#include <aspl/Object.hpp>
#include <aspl/VolumeControl.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <optional>
#include <vector>

namespace aspl {

class Device;

//! Audio stream parameters.
struct StreamParameters
{
    //! Stream direction.
    //! Used by default implementation of Stream::GetDirection().
    Direction Direction = Direction::Output;

    //! Absolute channel number for the first channel in the stream.
    //! Used by default implementation of Stream::GetStartingChannel().
    UInt32 StartingChannel = 1;

    //! Stream format.
    //! Used by default implementation of Stream::GetPhysicalFormat().
    //! Default format is:
    //!  - 44100 Hz
    //!  - 2 channels (stereo)
    //!  - 16-bit native-endian signed integers (Int16)
    //!  - interleaved (L R L R ...)
    AudioStreamBasicDescription Format = {
        .mSampleRate = 44100,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian |
                        kAudioFormatFlagIsPacked,
        .mBitsPerChannel = 16,
        .mChannelsPerFrame = 2,
        .mBytesPerFrame = 4,
        .mFramesPerPacket = 1,
        .mBytesPerPacket = 4,
    };

    //! Additional presentation latency the stream has.
    //! Used by default implementation of Stream::GetLatency().
    UInt32 Latency = 0;
};

//! Audio stream object.
//!
//! Stream is part of a Device representing a source (input stream) or a destination
//! (output stream) for samples. Clients connected to the device can read from its
//! input streams and write to its output streams.
//!
//! Each stream can have its own format, latency, and other parameters.
//!
//! Stream does not do I/O by its own. Instead, it provides ApplyProcessing() method,
//! which is invoked by ReaderWriter (in its default implementation).
//!
//! Default implementation of Stream::ApplyProcessing() just invokes corresponding
//! methods on attached VolumeControl and MuteControl objects, which you can set
//! using AttachVolumeControl() and AttachMuteControl().
class Stream : public Object
{
public:
    //! Construct stream.
    explicit Stream(std::shared_ptr<const Context> context,
        std::shared_ptr<Device> device,
        const StreamParameters& params = {});

    //! @name Getters and setters
    //! @{

    //! Tell whether the stream participates in I/O.
    //! By default returns the last value set by SetIsActive().
    //! Initial value is true.
    //! @note
    //!  Backs @c kAudioStreamPropertyIsActive property.
    virtual bool GetIsActive() const;

    //! Activate or deactivate stream.
    //! Invokes SetIsActiveImpl() and NotifyPropertyChanged().
    //! @note
    //!  Backs @c kAudioStreamPropertyIsActive property.
    OSStatus SetIsActive(bool isActive);

    //! Get stream direction.
    //! By default returns corresponding field of StreamParameters.
    //! @see StreamParameters::Direction.
    //! @note
    //!  Backs @c kAudioStreamPropertyDirection property.
    virtual Direction GetDirection() const;

    //! Get terminal type.
    //! By default returns kAudioStreamTerminalTypeMicrophone if GetDirection()
    //! returns Direction::Input, and kAudioStreamTerminalTypeSpeaker if
    //! it return Direction::Output.
    //! @remarks
    //!  Indicates what is at the other end of the stream such as a speaker
    //!  or headphones, or a microphone. Values for this property are defined
    //!  in <CoreAudio/AudioHardwareBase.h>
    //! @note
    //!  Backs @c kAudioStreamPropertyTerminalType property.
    virtual UInt32 GetTerminalType() const;

    //! Absolute channel number for the first channel in the stream.
    //! For example, if a device has two output streams with two channels each, then
    //! the starting channel number for the first stream is 1 and thus starting
    //! channel number for the second stream is 3.
    //! By default returns StreamParameters::StartingChannel.
    //! @note
    //!  Backs @c kAudioStreamPropertyStartingChannel property.
    virtual UInt32 GetStartingChannel() const;

    //! Get number of channels in stream.
    //! Return value is based on GetPhysicalFormat().
    UInt32 GetChannelCount() const;

    //! Get stream sample rate.
    //! Return value is based on GetPhysicalFormat().
    Float64 GetSampleRate() const;

    //! Get any additional presentation latency the stream has.
    //! This latency is added to the device latency.
    //! By default returns value last set with SetLatencyAsync().
    //! Initial value is StreamParameters::Latency.
    //! @note
    //!  Backs @c kAudioStreamPropertyLatency property.
    virtual UInt32 GetLatency() const;

    //! Asynchronously set stream presentation latency,
    //! Requests HAL to asynchronously invoke SetLatencyImpl().
    OSStatus SetLatencyAsync(UInt32 latency);

    //! Get the current physical format of the stream.
    //! Physical format defines the underlying format supported natively by hardware.
    //! By default returns value set by last SetPhysicalFormatAsync() call.
    //! Initial value is StreamParameters::Format.
    //! @note
    //!  Backs @c kAudioStreamPropertyPhysicalFormat property.
    virtual AudioStreamBasicDescription GetPhysicalFormat() const;

    //! Set current format of the stream.
    //! Requests HAL to asynchronously invoke SetPhysicalFormatImpl().
    //! Fails if format is not present in GetAvailablePhysicalFormats(), which by
    //! default returns only one format, provided during initialization.
    //! If you want to make your stream supporting multiple formats, you typically
    //! need to override both of these methods.
    //! @note
    //!  Backs @c kAudioStreamPropertyPhysicalFormat property.
    OSStatus SetPhysicalFormatAsync(AudioStreamBasicDescription format);

    //! Get list of supported physical formats.
    //! Empty list means that any format is allowed.
    //! By default returns the last value set by SetAvailablePhysicalFormatsAsync().
    //! If nothing was set, return a single-element list with the format returned by
    //! GetPhysicalFormat().
    //! @note
    //!  Backs @c kAudioStreamPropertyAvailablePhysicalFormats property.
    virtual std::vector<AudioStreamRangedDescription> GetAvailablePhysicalFormats() const;

    //! Asynchronously set list of supported physical formats.
    //! See comments for GetAvailablePhysicalFormats().
    //! Requests HAL to asynchronously invoke SetAvailablePhysicalFormatsImpl().
    OSStatus SetAvailablePhysicalFormatsAsync(
        std::vector<AudioStreamRangedDescription> formats);

    //! Get the current format of the stream.
    //! Virtual format defines the format used to present the device to the apps.
    //! For example, physical format may use integers, while virtual format may
    //! use floating point numbers.
    //! For devices that don't override the mix operation, the virtual format has
    //! to be the same as the physical format.
    //! By default returns value set by last SetVirtualFormatAsync() call.
    //! Initial value is StreamParameters::Format.
    //! @note
    //!  Backs @c kAudioStreamPropertyVirtualFormat property.
    virtual AudioStreamBasicDescription GetVirtualFormat() const;

    //! Set current virtual format of the stream.
    //! Requests HAL to asynchronously invoke SetVirtualFormatImpl().
    //! Fails if format is not present in GetAvailableVirtualFormats(), which by
    //! default returns only one format, provided during initialization.
    //! If you want to make your stream supporting multiple formats, you typically
    //! need to override both of these methods.
    //! @note
    //!  Backs @c kAudioStreamPropertyVirtualFormat property.
    OSStatus SetVirtualFormatAsync(AudioStreamBasicDescription format);

    //! Get list of supported virtual formats.
    //! Empty list means that any format is allowed.
    //! By default returns the last value set by SetAvailableVirtualFormatsAsync().
    //! If nothing was set, return a single-element list with the format returned by
    //! GetVirtualFormat().
    //! @note
    //!  Backs @c kAudioStreamPropertyAvailableVirtualFormats property.
    virtual std::vector<AudioStreamRangedDescription> GetAvailableVirtualFormats() const;

    //! Asynchronously set list of supported virtual formats.
    //! See comments for GetAvailableVirtualFormats().
    //! Requests HAL to asynchronously invoke SetAvailableVirtualFormatsImpl().
    OSStatus SetAvailableVirtualFormatsAsync(
        std::vector<AudioStreamRangedDescription> formats);

    //! @}

    //! @name Processing
    //! @{

    //! Convert number of frame to the number of bytes.
    //! Result depends on the value returned by GetPhysicalFormat().
    virtual UInt32 ConvertFramesToBytes(UInt32 numFrames) const;

    //! Convert number of bytes to the number of frames.
    //! Result depends on the value returned by GetPhysicalFormat().
    virtual UInt32 ConvertBytesToFrames(UInt32 numBytes) const;

    //! Attach volume control to the stream.
    //! ApplyProcessing() will use control to apply volume settings to the stream.
    void AttachVolumeControl(std::shared_ptr<VolumeControl> control);

    //! Attach mute control to the stream.
    //! ApplyProcessing() will use control to apply mute settings to the stream.
    void AttachMuteControl(std::shared_ptr<MuteControl> control);

    //! Apply processing to the stream's data.
    //! The provided buffer contains exactly @p frameCount * @p channelCount samples.
    //! Modifies frames in the provided buffer.
    //! Default implementation invokes ApplyProcessing() on attached volume and mute
    //! controls, if they are present.
    //! @note
    //!  Invoked by ReaderWriter on realtime thread.
    virtual void ApplyProcessing(Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) const;

    //! @}

    //! @name Configuration
    //! @{

    //! Request HAL to perform configuration update.
    //! Similar to Device::RequestConfigurationChange().
    void RequestConfigurationChange(std::function<void()> func = {});

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

    //! Activate or deactivate stream.
    //! Should return zero if the state was successfully changed.
    //! By default just changes the value returned by GetIsActive().
    //! Invoked by SetIsActive().
    //! @note
    //!  Backs @c kAudioStreamPropertyIsActive property.
    virtual OSStatus SetIsActiveImpl(bool isActive);

    //! Set stream presentation latency.
    //! Invoked by SetLatencyAsync() to actually change the latency.
    //! Default implementation just changes the value returned by GetLatency().
    virtual OSStatus SetLatencyImpl(UInt32 latency);

    //! Set current format of the stream.
    //! Invoked by SetPhysicalFormatAsync() to actually change the format.
    //! Default behavior is to change the format returned by GetPhysicalFormat() and
    //! to invoke Device::SetSampleRateAsync() to ensure that device and all its
    //! streams have the same rate.
    //! @note
    //!  Backs @c kAudioStreamPropertyPhysicalFormat property.
    virtual OSStatus SetPhysicalFormatImpl(const AudioStreamBasicDescription& format);

    //! Set list of supported physical formats.
    //! Invoked by SetAvailablePhysicalFormatsAsync().
    //! Default implementation just changes the list returned by
    //! GetAvailablePhysicalFormats().
    virtual OSStatus SetAvailablePhysicalFormatsImpl(
        std::vector<AudioStreamRangedDescription> formats);

    //! Set current virtual format of the stream.
    //! Invoked by SetVirtualFormatAsync() to actually change the format.
    //! Default behavior is to change the format returned by GetVirtualFormat() and
    //! to invoke Device::SetSampleRateAsync() to ensure that device and all its
    //! streams have the same rate.
    //! @note
    //!  Backs @c kAudioStreamPropertyVirtualFormat property.
    virtual OSStatus SetVirtualFormatImpl(const AudioStreamBasicDescription& format);

    //! Set list of supported virtual formats.
    //! Invoked by SetAvailableVirtualFormatsAsync().
    //! Default implementation just changes the list returned by
    //! GetAvailableVirtualFormats().
    virtual OSStatus SetAvailableVirtualFormatsImpl(
        std::vector<AudioStreamRangedDescription> formats);

    //! @}

private:
    // value checkers for async setters
    OSStatus CheckPhysicalFormat(const AudioStreamBasicDescription&) const;
    OSStatus CheckVirtualFormat(const AudioStreamBasicDescription&) const;

    // fields
    const StreamParameters params_;

    const std::weak_ptr<Device> device_;

    std::recursive_mutex writeMutex_;

    std::atomic<bool> isActive_ = true;
    std::atomic<UInt32> latency_;

    DoubleBuffer<AudioStreamBasicDescription> physicalFormat_;
    DoubleBuffer<AudioStreamBasicDescription> virtualFormat_;

    DoubleBuffer<std::optional<std::vector<AudioStreamRangedDescription>>>
        availPhysicalFormats_;

    DoubleBuffer<std::optional<std::vector<AudioStreamRangedDescription>>>
        availVirtualFormats_;

    DoubleBuffer<std::shared_ptr<VolumeControl>> volumeControl_;
    DoubleBuffer<std::shared_ptr<MuteControl>> muteControl_;
};

} // namespace aspl
