// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/Device.hpp
//! @brief Audio device object.

#pragma once

#include <aspl/Client.hpp>
#include <aspl/ControlRequestHandler.hpp>
#include <aspl/DoubleBuffer.hpp>
#include <aspl/IORequestHandler.hpp>
#include <aspl/MuteControl.hpp>
#include <aspl/Object.hpp>
#include <aspl/Stream.hpp>
#include <aspl/VolumeControl.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <array>
#include <atomic>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <variant>
#include <vector>

namespace aspl {

//! Audio device parameters.
struct DeviceParameters
{
    //! Human-readable name of the device.
    //! Used by default implementation of Device::GetName().
    std::string Name = "libASPL Device";

    //! Human readable name of the maker of the plug-in.
    //! Used by default implementation of Device::GetManufacturer().
    std::string Manufacturer = "libASPL";

    //! Persistent token that can identify the same audio device across boot sessions.
    //! Used by default implementation of Device::GetDeviceUID().
    std::string DeviceUID = "";

    //! Persistent token that can identify audio devices of the same kind.
    //! Used by default implementation of Device::GetModelUID().
    std::string ModelUID = "libaspl";

    //! Human readable serial number of the device.
    //! Used by default implementation of Device::GetSerialNumber().
    std::string SerialNumber = "";

    //! Human readable firmware version of the device.
    //! Used by default implementation of Device::GetFirmwareVersion().
    std::string FirmwareVersion = "";

    //! URL that points to the device icon, e.g. in  plugin resource bundle.
    //! Used by default implementation of Device::GetIconURL().
    std::string IconURL = "";

    //! Bundle ID for an application that provides a GUI for configuring the device.
    //! Used by default implementation of Device::GetConfigurationApplicationBundleID().
    std::string ConfigurationApplicationBundleID = "";

    //! Whether the device can be the default device for content.
    //! Used by default implementation of Device::GetCanBeDefaultDevice().
    bool CanBeDefault = true;

    //! Whether the device can be the default device for system sounds.
    //! Used by default implementation of Device::GetCanBeDefaultSystemDevice().
    bool CanBeDefaultForSystemSounds = true;

    //! Device sample rate.
    //! Used by default implementation of Device::GetNominalSampleRate().
    UInt32 SampleRate = 44100;

    //! Preferred number of channels.
    //! Used by default implementations of Device::GetPreferredChannelCount().
    UInt32 ChannelCount = 2;

    //! The presentation latency of the device, number of frames.
    //! Used by default implementation of Device::GetLatency().
    UInt32 Latency = 0;

    //! How close to now it is allowed to read and write, number of frames.
    //! Used by default implementation of Device::GetSafetyOffset().
    UInt32 SafetyOffset = 0;

    //! How many frames to expect between successive timestamps returned
    //! from Device::GetZeroTimeStamp()
    //! Used by default implementation of Device::GetZeroTimeStampPeriod().
    //! If zero, assigned to SampleRate value, which means one second.
    UInt32 ZeroTimeStampPeriod = 0;

    //! Whether the device clock should be considered stable.
    //! Used by default implementation of Device::GetClockIsStable().
    bool ClockIsStable = true;

    //! Clock algorithm.
    //! Used by default implementation of Device::GetClockAlgorithm().
    AudioDeviceClockAlgorithmSelector ClockAlgorithm =
        kAudioDeviceClockAlgorithmSimpleIIR;

    //! Clock domain.
    //! Used by default implementation of Device::GetClockDomain().
    UInt32 ClockDomain = 0;

    //! Whether IORequestHandler will handle mixed output from all clients,
    //! or handle individual clients and perform mixing by itself.
    //!
    //! - When true, Device will invoke IORequestHandler::OnProcessMixedOutput() and
    //!   IORequestHandler::WriteMixedOutput().
    //!   It will be provided with the result of mixing of all clients.
    //!
    //! - When false, Device will invoke IORequestHandler::OnProcessClientOutput()
    //!   and IORequestHandler::WriteClientOutput().
    //!   It will be repeatedly called with the output from each client.
    //!   IORequestHandler is responsible for mixing in this case.
    bool EnableMixing = true;

    //! If true, realtime calls are logged to tracer.
    //! This is not suitable for production use because tracer is not realtime-safe
    //! and because realtime operations are too frequent.
    bool EnableRealtimeTracing = false;
};

//! Audio device object.
//!
//! Audio device is something to which applications (clients) can connect and do I/O.
//!
//! **Streams and controls**
//!
//! After creating device, and before publishing it to HAL, you should populate it with
//! streams (Stream class) and controls (VolumeControl, MuteControl).
//!
//! Each stream can be either input or output; control can be input, output, and global.
//! Input streams allow client to read from device; output streams allow clients to
//! write to device. Controls allow clients or user to adjust processing settings.
//!
//! When a client performs I/O, it always specifies the stream. Each stream may
//! represent its own source or destination of samples. Each stream also may have its
//! own format, latency, and other attributes.
//!
//! The meaning of controls is device-specific. If desired, you can attach controls
//! to a stream, and stream will take them into account when applying per-stream
//! processing. However you're free to treat streams and controls in any other way.
//!
//! **I/O operations**
//!
//! Unlike other objects, in addition to property dispatch operations, Device class has
//! a bunch of I/O-related operations exported to HAL.
//!
//! Default Device implementation performs some typical housekeeping by itself (like
//! maintaining maps of clients and streams) and then delegates the principal part (like
//! actually reading or writing samples) to two other classes: ControlRequestHandler (for
//! non-realtime, control operations) and IORequestHandler (for realtime I/O operations).
//!
//! Typically you'll need default implementation of Device and custom implementation of
//! IORequestHandler and probably ControlRequestHandler. Though, if default Device
//! implementation does not fit your needs, you can override how it handles control and
//! I/O requests from HAL and drop IORequestHandler and ControlRequestHandler at all.
//!
//! When you override IORequestHandler or Device I/O operations, remember that HAL invokes
//! them on realtime thread and they should be realtime-safe.
class Device : public Object
{
public:
    //! Construct device.
    explicit Device(std::shared_ptr<const Context> context,
        const DeviceParameters& params = {});

    //! @name Getters and setters
    //! @{

    //! Get device name.
    //! Human readable name of the device.
    //! Can be localized.
    //! By default returns DeviceParameters::Name.
    //! @note
    //!  Backs @c kAudioObjectPropertyName property.
    virtual std::string GetName() const;

    //! Get device manufacturer.
    //! Human readable name of the maker of the plug-in.
    //! Can be localized.
    //! By default returns DeviceParameters::Manufacturer.
    //! @note
    //!  Backs @c kAudioObjectPropertyManufacturer property.
    virtual std::string GetManufacturer() const;

    //! Get device UID.
    //! Persistent token that can identify the same audio device across boot sessions.
    //! Two instances of the same device must have different values for this property.
    //! By default returns DeviceParameters::DeviceUID if it's non-empty, or otherwise
    //! generates random UID.
    //! @note
    //!  Backs @c kAudioDevicePropertyDeviceUID property.
    virtual std::string GetDeviceUID() const;

    //! Get model UID.
    //! Persistent token that can identify audio devices of the same kind.
    //! Two instances of the same device must have the same value for this property.
    //! By default returns DeviceParameters::ModelUID.
    //! @note
    //!  Backs @c kAudioDevicePropertyModelUID property.
    virtual std::string GetModelUID() const;

    //! Get serial number.
    //! Human readable serial number of the device.
    //! This is pure informational value which doesn't have to be unique.
    //! By default returns DeviceParameters::SerialNumber.
    //! @note
    //!  Backs @c kAudioObjectPropertySerialNumber property.
    virtual std::string GetSerialNumber() const;

    //! Get firmware version.
    //! Human readable firmware version of the device.
    //! This is pure informational value which doesn't have to be unique.
    //! By default returns DeviceParameters::FirmwareVersion.
    //! @note
    //!  Backs @c kAudioObjectPropertyFirmwareVersion property.
    virtual std::string GetFirmwareVersion() const;

    //! Get device icon URL.
    //! Returns URL that points to the device icon, e.g in plugin resource bundle.
    //! By default returns DeviceParameters::IconURL.
    //! @note
    //!  Backs @c kAudioDevicePropertyIcon property.
    virtual std::string GetIconURL() const;

    //! Get bundle ID of configuration application.
    //! The returned app should provides a GUI for configuring the device.
    //! By default returns DeviceParameters::ConfigurationApplicationBundleID.
    //! @note
    //!  Backs @c kAudioDevicePropertyConfigurationApplication property.
    virtual std::string GetConfigurationApplicationBundleID() const;

    //! Get device transport type.
    //! Represents how the device is attached to the system.
    //! Common values are defined in <CoreAudio/AudioHardwareBase.h>.
    //! Default is kAudioDeviceTransportTypeVirtual.
    //! @note
    //!  Backs @c kAudioDevicePropertyTransportType property.
    virtual UInt32 GetTransportType() const;

    //! Get related devices.
    //! By default returns a single-element list with own ID.
    //! @remarks
    //!  The related devices property identifies device objects that are very closely
    //!  related. Generally, this is for relating devices that are packaged together
    //!  in the hardware such as when the input side and the output side of a piece
    //!  of hardware can be clocked separately and therefore need to be represented
    //!  as separate AudioDevice objects. In such case, both devices would report
    //!  that they are related to each other. Note that at minimum, a device is
    //!  related to itself, so this list will always be at least one item long.
    //! @note
    //!  Backs @c kAudioDevicePropertyRelatedDevices property.
    virtual std::vector<AudioObjectID> GetRelatedDeviceIDs() const;

    //! Check whether the device clock should be considered stable.
    //! By default returns DeviceParameters::ClockIsStable.
    //! @remarks
    //!  The true value indicates that the device's clock runs at or very near the nominal
    //!  sample rate with only small variations.
    //! @note
    //!  Backs @c kAudioDevicePropertyClockIsStable property.
    virtual bool GetClockIsStable() const;

    //! Get clock algorithm.
    //! By default returns DeviceParameters::ClockAlgorithm.
    //! @remarks
    //!  This property defines what filtering the HAL applies to the values returned
    //!  by GetZeroTimeStamp(). Possible values are defined in
    //!  CoreAudio/AudioServerPlugIn.h.
    //! @note
    //!  Backs @c kAudioDevicePropertyClockAlgorithm property.
    virtual AudioDeviceClockAlgorithmSelector GetClockAlgorithm() const;

    //! Get clock domain.
    //! By default returns DeviceParameters::ClockDomain.
    //! @remarks
    //!  This property allows the device to declare what other devices it is
    //!  synchronized with in hardware. The way it works is that if two devices have
    //!  the same value for this property and the value is not zero, then the two
    //!  devices are synchronized in hardware. Note that a device that either can't
    //!  be synchronized with others or doesn't know should return 0 for this property.
    //! @note
    //!  Backs @c kAudioDevicePropertyClockDomain property.
    virtual UInt32 GetClockDomain() const;

    //! Get presentation latency of the device.
    //! Measured in number of frames.
    //! By default returns the last value set by SetLatencyAsync().
    //! Initial value is DeviceParameters::Latency.
    //! @note
    //!  Backs @c kAudioDevicePropertyLatency property.
    virtual UInt32 GetLatency() const;

    //! Asynchronously set presentation latency.
    //! Requests HAL to asynchronously invoke SetLatencyImpl().
    OSStatus SetLatencyAsync(UInt32 latency);

    //! How close to now it is allowed to read and write.
    //! Measured in number of frames.
    //! By default returns the last value set by SetSafetyOffset().
    //! Initial value is DeviceParameters::SafetyOffset.
    //! @note
    //!  Backs @c kAudioDevicePropertySafetyOffset property.
    virtual UInt32 GetSafetyOffset() const;

    //! Asynchronously set safety offset.
    //! Requests HAL to asynchronously invoke SetSafetyOffsetImpl().
    OSStatus SetSafetyOffsetAsync(UInt32 offset);

    //! Difference between successive timestamps returned from GetZeroTimeStamp().
    //! Measured in number of frames.
    //! By default returns the last value set by SetZeroTimeStampPeriodAsync().
    //! Initial value is DeviceParameters::ZeroTimeStampPeriod if it's non-zero,
    //! or DeviceParameters::SampleRate otherwise.
    //! @remarks
    //!  If GetZeroTimeStamp() returned a sample time of X, we expect that the next
    //!  valid returned timestamp will be X plus the value of this property.
    //! @note
    //!  Backs @c kAudioDevicePropertyZeroTimeStampPeriod property.
    virtual UInt32 GetZeroTimeStampPeriod() const;

    //! Asynchronously set zero timestamp period.
    //! Requests HAL to asynchronously invoke SetZeroTimeStampPeriodImpl().
    OSStatus SetZeroTimeStampPeriodAsync(UInt32 period);

    //! Get nominal sample rate.
    //! By default returns the last value set by SetNominalSampleRateAsync().
    //! Initial value is DeviceParameters::SampleRate.
    //! Note that each device stream can define its own sample rate in its
    //! physical and virtual formats.
    //! @note
    //!  Backs @c kAudioDevicePropertyNominalSampleRate property.
    virtual Float64 GetNominalSampleRate() const;

    //! Asynchronously set nominal sample rate.
    //! Requests HAL to asynchronously invoke SetNominalSampleRateImpl().
    //! Fails if rate is not present in GetAvailableSampleRates(), which by default
    //! returns only one rate, provided during initialization.
    //! If you want to make your device supporting multiple rates, you typically
    //! need to override both of these methods.
    //! @note
    //!  Backs @c kAudioDevicePropertyNominalSampleRate property.
    OSStatus SetNominalSampleRateAsync(Float64 rate);

    //! Get list of supported nominal sample rates.
    //! By default returns the list set by SetAvailableSampleRatesAsync().
    //! If nothing was set, returns a single-element list with a range which min and max
    //! are both set to the value returned by GetNominalSampleRate().
    //! @remarks
    //!  Empty list means that any rate is allowed.
    //!  For discrete sampler rates, the range should have the minimum value equal
    //!  to the maximum value.
    //! @note
    //!  Backs @c kAudioDevicePropertyAvailableNominalSampleRates property.
    virtual std::vector<AudioValueRange> GetAvailableSampleRates() const;

    //! Asynchronously set list of supported nominal sample rates.
    //! See comments for GetAvailableSampleRates().
    //! Requests HAL to asynchronously invoke SetAvailableSampleRatesImpl().
    OSStatus SetAvailableSampleRatesAsync(std::vector<AudioValueRange> rates);

    //! Return which two channels to use as left/right for stereo data by default.
    //! By default returns the last value set by SetPreferredChannelsForStereoAsync().
    //! Initial value is {1, 2}.
    //! Channel numbers are 1-based.
    //! @note
    //!  Backs @c kAudioDevicePropertyPreferredChannelsForStereo property.
    virtual std::array<UInt32, 2> GetPreferredChannelsForStereo() const;

    //! Asynchronously set channels for stereo.
    //! Channel numbers are 1-based.
    //! Requests HAL to asynchronously invoke SetPreferredChannelsForStereoImpl().
    OSStatus SetPreferredChannelsForStereoAsync(std::array<UInt32, 2> channels);

    //! Get preferred number of channels.
    //!
    //! GetPreferredChannelCount() and SetPreferredChannelCountAsync() are the most
    //! simple way to configure channels. Use them if all you need is to get/set
    //! number of channels.
    //!
    //! If you need more precise configuration, see GetPreferredChannels() and
    //! GetPreferredChannelLayout(). If you don't, you can ignore them; their default
    //! implementation will use GetPreferredChannelCount().
    //!
    //! Default implementation of this method automatically checks what channel parameters
    //! did you set (SetPreferredChannelCountAsync(), SetPreferredChannelsAsync(),
    //! SetPreferredChannelLayoutAsync()), and returns number of channels based on that.
    //!
    //! If nothing was set, it just returns DeviceParameters::ChannelCount.
    //!
    //! @note
    //!  Indirectly backs @c kAudioDevicePropertyPreferredChannelLayout property
    //!  via GetPreferredChannels() / GetPreferredChannelLayout().
    virtual UInt32 GetPreferredChannelCount() const;

    //! Asynchronously set preferred channel count.
    //! See comments for GetPreferredChannelCount().
    //! Requests HAL to asynchronously invoke SetPreferredChannelCountImpl().
    //! @note
    //!  Indirectly backs @c kAudioDevicePropertyPreferredChannelLayout property
    //!  via GetPreferredChannels() / GetPreferredChannelLayout().
    OSStatus SetPreferredChannelCountAsync(UInt32 channelCount);

    //! Get preferred channels for device.
    //!
    //! GetPreferredChannels() and SetPreferredChannelsAsync() are a more precise way to
    //! configure channels. Use them if all you want to specify parameters of individual
    //! channels, defined in AudioChannelDescription struct.
    //!
    //! If all you need is just to change number of channels, see
    //! GetPreferredChannelCount() instead. And if you need even more precise
    //! configuration, see GetPreferredChannelLayout().
    //!
    //! Default implementation of this method automatically checks what channel parameters
    //! did you set (SetPreferredChannelsAsync(), SetPreferredChannelLayoutAsync()), and
    //! returns channel array based on that.
    //!
    //! If nothing was set, it constructs channels with default parameters based on the
    //! number of channels returned by GetPreferredChannelCount().
    //!
    //! @note
    //!  Indirectly backs @c kAudioDevicePropertyPreferredChannelLayout property
    //!  via GetPreferredChannelLayout().
    virtual std::vector<AudioChannelDescription> GetPreferredChannels() const;

    //! Asynchronously set preferred channels array.
    //! See comments for GetPreferredChannels().
    //! Requests HAL to asynchronously invoke SetPreferredChannelsImpl().
    //! @note
    //!  Indirectly backs @c kAudioDevicePropertyPreferredChannelLayout property
    //!  via GetPreferredChannelLayout().
    OSStatus SetPreferredChannelsAsync(std::vector<AudioChannelDescription> channels);

    //! Get preferred AudioChannelLayout to use for the device.
    //!
    //! This is the most precise way to configure channels, by providing custom
    //! AudioChannelLayout. In most cases, it is enough to use GetPreferredChannelCount()
    //! or GetPreferredChannels() instead.
    //!
    //! Default implementation of this method automatically checks if you have set channel
    //! layout using SetPreferredChannelLayoutAsync(), and returns it.
    //!
    //! If nothing was set, it constructs default channel layout based on the channels
    //! returned by GetPreferredChannels().
    //!
    //! @remarks
    //!  AudioChannelLayout has variable size, which depends on the number of
    //!  channels. Hence, this methods returns a byte array instead of
    //!  AudioChannelLayout struct. The returned array contains a properly
    //!  formatted AudioChannelLayout struct.
    //!
    //! @note
    //!  Backs @c kAudioDevicePropertyPreferredChannelLayout property.
    virtual std::vector<UInt8> GetPreferredChannelLayout() const;

    //! Asynchronously set preferred channel layout.
    //! See comments for GetPreferredChannelLayout().
    //! The provided buffer should contain properly formatted AudioChannelLayout struct.
    //! Requests HAL to asynchronously invoke SetPreferredChannelLayoutImpl().
    OSStatus SetPreferredChannelLayoutAsync(std::vector<UInt8> channelLayout);

    //! Check whether the device is doing I/O.
    //! By default, returns true if I/O was activated using StartIO().
    //! @note
    //!  Backs @c kAudioDevicePropertyDeviceIsRunning property.
    virtual bool GetIsRunning() const;

    //! Check whether device identification is in progress.
    //! A true value indicates that the device hardware is drawing attention to itself,
    //! typically by flashing or lighting up its front panel display. This makes it easy
    //! for a user to associate the physical hardware with its representation in an app.
    //! By default always returns false.
    //! @note
    //!  Backs @c kAudioObjectPropertyIdentify property.
    virtual bool GetIsIdentifying() const;

    //! Start or stop device identification.
    //! Invokes SetIsIdentifyingImpl() and NotifyPropertyChanged().
    //! @note
    //!  Backs @c kAudioObjectPropertyIdentify property.
    OSStatus SetIsIdentifying(bool);

    //! Check whether the device is alive.
    //! By default returns the last value set by SetIsAlive().
    //! Initial value is true.
    //! @remarks
    //!  It is not uncommon for a device to be dead but still momentarily
    //!  available in the device list.
    //! @note
    //!  Backs @c kAudioDevicePropertyDeviceIsAlive property.
    virtual bool GetIsAlive() const;

    //! Mark device as alive or dead.
    //! Invokes SetIsAliveImpl() and NotifyPropertyChanged().
    OSStatus SetIsAlive(bool isAlive);

    //! Check whether the device is hidden from clients.
    //! By default returns the last value set by SetIsHidden().
    //! Initial value is false.
    //! @note
    //!  Backs @c kAudioDevicePropertyIsHidden property.
    virtual bool GetIsHidden() const;

    //! Mark or unmark  device as hidden.
    //! Invokes SetIsHiddenImpl() and NotifyPropertyChanged().
    OSStatus SetIsHidden(bool isHidden);

    //! Check whether the device can be the default device for content.
    //! By default, returns the last value set by SetCanBeDefaultDevice().
    //! Initial value is DeviceParameters::CanBeDefault.
    //! @remarks
    //!  Default device is configured via Sound Preferences. This is the device which
    //!  applications will use to play their content or capture sound.
    //!  Nearly all devices should allow for this.
    //! @note
    //!  Backs @c kAudioDevicePropertyDeviceCanBeDefaultDevice property.
    virtual bool GetCanBeDefaultDevice() const;

    //! Set whether the device can be the default device for content.
    //! Invokes SetCanBeDefaultDeviceImpl() and NotifyPropertyChanged().
    OSStatus SetCanBeDefaultDevice(bool value);

    //! Check whether the device can be the default device for system sounds.
    //! By default, returns the last value set by SetCanBeDefaultSystemDevice().
    //! Initial value is DeviceParameters::CanBeDefaultForSystemSounds.
    //! @remarks
    //!  Default system device is configured via Sound Preferences. It is used by
    //!  applications to play interface sounds.
    //! @note
    //!  Backs @c kAudioDevicePropertyDeviceCanBeDefaultSystemDevice property.
    virtual bool GetCanBeDefaultSystemDevice() const;

    //! Set whether the device can be the default device for system sounds.
    //! Invokes SetCanBeDefaultSystemDeviceImpl() and NotifyPropertyChanged().
    OSStatus SetCanBeDefaultSystemDevice(bool value);

    //! Get device streams.
    //! Returns the list of owned streams.
    //! Scope defines whether to return input streams, output streams, or both.
    //! Default implementation returns all owned objects of given scope and
    //! kAudioStreamClassID class.
    //! @note
    //!  Backs @c kAudioDevicePropertyStreams property.
    virtual std::vector<AudioObjectID> GetStreamIDs(
        AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) const;

    //! Get device controls.
    //! Returns the list of owned controls.
    //! Scope defines whether to return input controls, output controls, or both.
    //! Default implementation returns all owned objects of given scope and
    //! kAudioControlClassID class and its derivatives, including volume and
    //! mute controls.
    //! @note
    //!  Backs @c kAudioObjectPropertyControlList property.
    virtual std::vector<AudioObjectID> GetControlIDs(
        AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) const;

    //! @}

    //! @name Streams
    //! @{

    //! Get number of streams for given direction.
    UInt32 GetStreamCount(Direction dir) const;

    //! Get stream with given direction and zero-based index.
    //! Returns nullptr if there are less than idx+1 streams.
    std::shared_ptr<Stream> GetStreamByIndex(Direction dir, UInt32 idx) const;

    //! Get stream with given object ID.
    //! Returns nullptr if there is no such stream.
    std::shared_ptr<Stream> GetStreamByID(AudioObjectID streamID) const;

    //! Add stream + volume control + mute control.
    //! @remarks
    //!  Constructs a new Stream, VolumeControl, and MuteControl instances with default
    //!  parameters adjusted to the stream direction and index.
    //!  Attaches volume and mute controls to the stream, so that
    //!  Stream::ApplyProcessing(), called by IORequestHandler, will take volume and
    //!  mute into account.
    //!  Also adds constructed objects to the owned object list.
    //! @returns
    //!  added stream.
    //! @note
    //!  The addition is split into two parts: synchronous and asynchronous. Objects
    //!  are constructed and initialized synchronously, but are added to the owned
    //!  objects list and published to HAL asynchronously (when HAL allows it).
    //!  Hence, GetStreamCount() and GetStreamByIndex() are updated immediately,
    //!  but GetOwnedObjectIDs(), GetStreamIDs(), etc. are updated some time later.
    std::shared_ptr<Stream> AddStreamWithControlsAsync(Direction dir);

    //! Add stream + volume control + mute control.
    //! Same as AddStreamWithControlsAsync(Direction), but allows to provide
    //! custom parameters.
    std::shared_ptr<Stream> AddStreamWithControlsAsync(const StreamParameters& params);

    //! Add stream to device.
    //! @remarks
    //!  Constructs a new Stream instance with default parameters,
    //!  adjusted to the stream direction and index.
    //!  Also adds stream to the owned object list.
    //! @returns
    //!  added stream.
    //! @note
    //!  The addition is split into two parts: synchronous and asynchronous. Stream
    //!  is constructed and initialized synchronously, but is added to the owned
    //!  objects list and published to HAL asynchronously (when HAL allows it).
    //!  Hence, GetStreamCount() and GetStreamByIndex() are updated immediately,
    //!  but GetOwnedObjectIDs(), GetStreamIDs(), etc. are updated some time later.
    std::shared_ptr<Stream> AddStreamAsync(Direction dir);

    //! Add stream to device.
    //! Same as AddStreamAsync(Direction), but allows to provide custom parameters.
    std::shared_ptr<Stream> AddStreamAsync(const StreamParameters& params);

    //! Add stream to device.
    //! Same as AddStreamAsync(Direction), but allows to construct stream manually.
    void AddStreamAsync(std::shared_ptr<Stream> stream);

    //! Remove stream from device.
    //! @remarks
    //!  Removes stream from device and the owned object list.
    //! @note
    //!  The removal is split into two parts: synchronous and asynchronous. Stream
    //!  is removed from the stream list synchronously, but is excluded from the
    //!  owned objects asynchronously (when HAL allows it). Hence, GetStreamCount()
    //!  and GetStreamByIndex() are updated immediately, but GetOwnedObjectIDs(),
    //!  GetStreamIDs(), etc. are updated some time later.
    void RemoveStreamAsync(std::shared_ptr<Stream> stream);

    //! @}

    //! @name Volume controls
    //! @{

    //! Get number of volume controls for given scope.
    UInt32 GetVolumeControlCount(AudioObjectPropertyScope scope) const;

    //! Get volume control with given scope and zero-based index.
    //! Returns nullptr if there are less than idx+1 volume controls.
    std::shared_ptr<VolumeControl> GetVolumeControlByIndex(AudioObjectPropertyScope scope,
        UInt32 idx) const;

    //! Get volume control with given object ID.
    //! Returns nullptr if there is no such control.
    std::shared_ptr<VolumeControl> GetVolumeControlByID(AudioObjectID controlID) const;

    //! Add volume control to device.
    //! @remarks
    //!  Constructs a new VolumeControl instance with default parameters,
    //!  adjusted to the volume control scope and index.
    //!  Also adds volume control to the owned object list.
    //! @returns
    //!  added control.
    //! @note
    //!  The addition is split into two parts: synchronous and asynchronous. Control
    //!  is constructed and initialized synchronously, but is added to the owned
    //!  objects list and published to HAL asynchronously (when HAL allows it).
    //!  Hence, GetVolumeControlCount() and GetVolumeControlByIndex() are updated
    //!  immediately, but GetOwnedObjectIDs(), GetControlIDs(), etc. are updated later.
    std::shared_ptr<VolumeControl> AddVolumeControlAsync(AudioObjectPropertyScope scope);

    //! Add volume control to device.
    //! Same as AddVolumeControlAsync(Direction), but allows to provide custom parameters.
    std::shared_ptr<VolumeControl> AddVolumeControlAsync(
        const VolumeControlParameters& params);

    //! Add volume control to device.
    //! Same as AddVolumeControlAsync(Direction), but allows to construct control
    //! manually.
    void AddVolumeControlAsync(std::shared_ptr<VolumeControl> control);

    //! Remove volume control from device.
    //! @remarks
    //!  Removes control from device and the owned object list.
    //! @note
    //!  The removal is split into two parts: synchronous and asynchronous. Control
    //!  is removed from the control list synchronously, but is excluded from the
    //!  owned objects asynchronously (when HAL allows it). Hence, GetVolumeControlCount()
    //!  and GetVolumeControlByIndex() are updated immediately, but GetOwnedObjectIDs(),
    //!  GetControlIDs(), etc. are updated some time later.
    void RemoveVolumeControlAsync(std::shared_ptr<VolumeControl> control);

    //! @}

    //! @name Mute controls
    //! @{

    //! Get number of mute controls for given scope.
    UInt32 GetMuteControlCount(AudioObjectPropertyScope scope) const;

    //! Get mute control with given scope and zero-based index.
    //! Returns nullptr if there are less than idx+1 mute controls.
    std::shared_ptr<MuteControl> GetMuteControlByIndex(AudioObjectPropertyScope scope,
        UInt32 idx) const;

    //! Get mute control with given object ID.
    //! Returns nullptr if there is no such control.
    std::shared_ptr<MuteControl> GetMuteControlByID(AudioObjectID controlID) const;

    //! Add mute control to device.
    //! @remarks
    //!  Constructs a new MuteControl instance with default parameters,
    //!  adjusted to the mute control scope and index.
    //!  Also adds mute control to the owned object list.
    //! @returns
    //!  added control.
    //! @note
    //!  The addition is split into two parts: synchronous and asynchronous. Control
    //!  is constructed and initialized synchronously, but is added to the owned
    //!  objects list and published to HAL asynchronously (when HAL allows it).
    //!  Hence, GetMuteControlCount() and GetMuteControlByIndex() are updated
    //!  immediately, but GetOwnedObjectIDs(), GetControlIDs(), etc. are updated later.
    std::shared_ptr<MuteControl> AddMuteControlAsync(AudioObjectPropertyScope scope);

    //! Add mute control to device.
    //! Same as AddMuteControlAsync(Direction), but allows to provide custom parameters.
    std::shared_ptr<MuteControl> AddMuteControlAsync(const MuteControlParameters& params);

    //! Add mute control to device.
    //! Same as AddMuteControlAsync(Direction), but allows to construct control manually.
    void AddMuteControlAsync(std::shared_ptr<MuteControl> control);

    //! Remove mute control from device.
    //! @remarks
    //!  Removes control from device and the owned object list.
    //! @note
    //!  The removal is split into two parts: synchronous and asynchronous. Control
    //!  is removed from the control list synchronously, but is excluded from the
    //!  owned objects asynchronously (when HAL allows it). Hence, GetMuteControlCount()
    //!  and GetMuteControlByIndex() are updated immediately, but GetOwnedObjectIDs(),
    //!  GetControlIDs(), etc. are updated some time later.
    void RemoveMuteControlAsync(std::shared_ptr<MuteControl> control);

    //! @}

    //! @name Control operations
    //! @{

    //! Set handler for control requests.
    //! This is optional. You may provide a custom handler if you want to do
    //! custom processing or want to inject custom client implementation.
    void SetControlHandler(std::shared_ptr<ControlRequestHandler> handler);

    //! Set handler for control requests (raw pointer overload).
    //! This overload uses raw pointer instead of shared_ptr, and the user
    //! is responsible for keeping handler object alive until it's reset
    //! or Device is destroyed.
    void SetControlHandler(ControlRequestHandler* handler);

    //! Get pointer to configured control handler.
    //! Never returns null, if there is no handler, a no-op handler is used.
    //! For details about life-time, see SetControlHandler().
    ControlRequestHandler* GetControlHandler() const;

    //! Called before new client start I/O with the device.
    //! Updates client map and invokes OnAddClient().
    virtual OSStatus AddClient(AudioObjectID objectID,
        const AudioServerPlugInClientInfo* rawClientInfo);

    //! Called after a client finishes I/O with the device.
    //! Updates client map and invokes OnRemoveClient().
    virtual OSStatus RemoveClient(AudioObjectID objectID,
        const AudioServerPlugInClientInfo* rawClientInfo);

    //! Get number of clients.
    UInt32 GetClientCount() const;

    //! Get all clients.
    std::vector<std::shared_ptr<Client>> GetClients() const;

    //! Find client by client ID.
    std::shared_ptr<Client> GetClientByID(UInt32 clientID) const;

    //! Tell the device to start I/O.
    //! Invokes ControlRequestHandler::OnStartIO() and updates GetIsRunning().
    //! GetIsRunning() will return true until at least one client is doing I/O.
    //! @note
    //!  Calls StartIOImpl(), which you can override if needed.
    //!  You can also replace I/O handling entirely by overriding top-level methods:
    //!  StartIO(), StopIO(), GetZeroTimeStamp(), WillDoIOOperation(),
    //!  BeginIOOperation(), DoIOOperation(), EndIOOperation().
    //!  If you override top-level (non-Impl) methods, you likely need to override
    //!  all of them together and implement your own locking.
    //! @note
    //!  Invoked by HAL on non-realtime thread.
    virtual OSStatus StartIO(AudioObjectID objectID, UInt32 clientID);

    //! Tell the device to stop I/O.
    //! Invokes ControlRequestHandler::OnStopIO() and updates GetIsRunning().
    //! GetIsRunning() will return true until at least one client is doing I/O.
    //! @note
    //!  Calls StopIOImpl(), which you can override if needed.
    //!  You can also replace I/O handling entirely by overriding top-level methods:
    //!  StartIO(), StopIO(), GetZeroTimeStamp(), WillDoIOOperation(),
    //!  BeginIOOperation(), DoIOOperation(), EndIOOperation().
    //!  If you override top-level (non-Impl) methods, you likely need to override
    //!  all of them together and implement your own locking.
    //! @note
    //!  Invoked by HAL on non-realtime thread.
    virtual OSStatus StopIO(AudioObjectID objectID, UInt32 clientID);

    //! @}

    //! @name I/O operations
    //! @{

    //! Set handler for I/O requests.
    //! Its methods will be invoked when an I/O operation is performed.
    //! They are always invoked on realtime thread, serialized.
    //! You need to provide your own implementation if you want your device
    //! to actually do something useful. Default implementation is suitable for
    //! a null / black hole device.
    void SetIOHandler(std::shared_ptr<IORequestHandler> handler);

    //! Set handler for I/O requests (raw pointer overload).
    //! This overload uses raw pointer instead of shared_ptr, and the user
    //! is responsible for keeping handler object alive until it's reset
    //! or Device is destroyed.
    void SetIOHandler(IORequestHandler* handler);

    //! Get pointer to configured I/O handler.
    //! Never returns null, if there is no handler, a no-op handler is used.
    //! For details about life-time, see SetIOHandler().
    IORequestHandler* GetIOHandler() const;

    //! Get the current zero time stamp for the device.
    //! In default implementation, the zero time stamp and host time are increased
    //! every GetZeroTimeStampPeriod() frames.
    //! @remarks
    //!  The HAL models the timing of a device as a series of time stamps that relate the
    //!  sample time to a host time. The zero time stamps are spaced such that the sample
    //!  times are the value of kAudioDevicePropertyZeroTimeStampPeriod apart. This is
    //!  often modeled using a ring buffer where the zero time stamp is updated when
    //!  wrapping around the ring buffer.
    //! @note
    //!  Calls GetZeroTimeStampImpl(), which you can override if needed.
    //!  See also comments for StartIO() and StopIO().
    //! @note
    //!  Invoked by HAL on realtime thread.
    virtual OSStatus GetZeroTimeStamp(AudioObjectID objectID,
        UInt32 clientID,
        Float64* outSampleTime,
        UInt64* outHostTime,
        UInt64* outSeed);

    //! Asks device whether it want to perform the given phase of the IO cycle.
    //! In default implementation, makes decision based on whether the device has input
    //! and output streams, and what is returned by DeviceParameters::EnableMixing.
    //! @note
    //!  Calls WillDoIOOperationImpl(), which you can override if needed.
    //!  See also comments for StartIO() and StopIO().
    //! @note
    //!  Invoked by HAL on realtime thread.
    virtual OSStatus WillDoIOOperation(AudioObjectID objectID,
        UInt32 clientID,
        UInt32 operationID,
        Boolean* outWillDo,
        Boolean* outWillDoInPlace);

    //! Called before performing I/O operation.
    //! By default does nothing.
    //! @note
    //!  Calls BeginIOOperationImpl(), which you can override if needed.
    //!  See also comments for StartIO() and StopIO().
    //! @note
    //!  Invoked by HAL on realtime thread.
    virtual OSStatus BeginIOOperation(AudioObjectID objectID,
        UInt32 clientID,
        UInt32 operationID,
        UInt32 ioBufferFrameSize,
        const AudioServerPlugInIOCycleInfo* ioCycleInfo);

    //! Perform an IO operation for a particular stream.
    //! In default implementation, invokes corresponding method of I/O handler based on
    //! passed operation type, for example OnReadInput() or OnWriteMixedOutput().
    //! @note
    //!  Calls DoIOOperationImpl(), which you can override if needed.
    //!  See also comments for StartIO() and StopIO().
    //! @note
    //!  Invoked by HAL on realtime thread.
    virtual OSStatus DoIOOperation(AudioObjectID objectID,
        AudioObjectID streamID,
        UInt32 clientID,
        UInt32 operationID,
        UInt32 ioBufferFrameSize,
        const AudioServerPlugInIOCycleInfo* ioCycleInfo,
        void* ioMainBuffer,
        void* ioSecondaryBuffer);

    //! Called after performing I/O operation.
    //! By default does nothing.
    //! @note
    //!  Calls EndIOOperationImpl(), which you can override if needed.
    //!  See also comments for StartIO() and StopIO().
    //! @note
    //!  Invoked by HAL on realtime thread.
    virtual OSStatus EndIOOperation(AudioObjectID objectID,
        UInt32 clientID,
        UInt32 operationID,
        UInt32 ioBufferFrameSize,
        const AudioServerPlugInIOCycleInfo* ioCycleInfo);

    //! @}

    //! @name Configuration
    //! @{

    //! Request HAL to perform configuration update.
    //! @remarks
    //!  This method is needed when we want to change parameters that can't be just
    //!  changed on fly, e.g. set sample rate or add a stream. In this case, we
    //!  ask HAL to schedule configuration update, defined by passed function, and
    //!  some time later HAL invokes PerformConfigurationChange(), which runs the
    //!  function. HAL may also invoke AbortConfigurationChange() instead.
    //! @note
    //!  There are three cases when this method decides that it's safe to invoke the
    //!  function immediately ("in-place") instead of enqueueing it:
    //!   - If Context::Host is null, the method assumes that the entire plugin is not
    //!     yet initialized and published to HAL, and thus HAL doesn't use Device.
    //!   - If Device::HasOwner() is false, the method assumes that the device itself
    //!     is not added to the plugin hierarchy yet, and thus HAL doesn't use Device.
    //!   - If the method is invoked from PerformConfigurationChange(), it assumes
    //!     that we're already at the point where it's safe to change configuration.
    virtual void RequestConfigurationChange(std::function<void()> func = {});

    //! Request device to change its owner.
    //! @remarks
    //!  This method is called by Device owner (Plugin object) when device is added
    //!  or removed to the plugin (and so becomes published or unpublished from HAL).
    //!  This method implements thread-safe changing of the ownership and handles
    //!  possible races with RequestConfigurationChange().
    //!  It is needed because RequestConfigurationChange() mechanism is tightly
    //!  coupled with the ownership state and should be taken into account when
    //!  ownership changes.
    //! @note
    //!  Normally @p owner is always a pointer to Plugin, and @p shouldHaveOwnership
    //!  is true when adding device and false when removing.
    //!  This method is expected to do all necessary housekeeping and invoke
    //!  owner->AddOwnedObject(this) or owner->RemoveOwnedObject(this).
    virtual void RequestOwnershipChange(Object* owner, bool shouldHaveOwnership);

    //! Called by the Host to allow the device to perform a configuration change
    //! that had been previously requested via a call to the Host method,
    //! RequestDeviceConfigurationChange().
    //! @note
    //!  Invoked by HAL on non-realtime thread.
    virtual OSStatus PerformConfigurationChange(AudioObjectID objectID,
        UInt64 changeAction,
        void* changeInfo);

    //! Called by the Host to tell the device not to perform a configuration change
    //! that had been requested via a call to the Host method,
    //! RequestDeviceConfigurationChange().
    //! @note
    //!  Invoked by HAL on non-realtime thread.
    virtual OSStatus AbortConfigurationChange(AudioObjectID objectID,
        UInt64 changeAction,
        void* changeInfo);

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

    //! Set presentation latency.
    //! Invoked by SetLatencyAsync() to actually change latency.
    //! Default implementation just changes the value returned by GetLatency().
    virtual OSStatus SetLatencyImpl(UInt32 latency);

    //! Set safety offset.
    //! Invoked by SetSafetyOffsetAsync() to actually change offset.
    //! Default implementation just changes the value returned by
    //! GetSafetyOffset().
    virtual OSStatus SetSafetyOffsetImpl(UInt32 offset);

    //! Set zero timestamp period.
    //! Invoked by SetZeroTimeStampPeriodAsync() to actually change period.
    //! Default implementation just changes the value returned by
    //! GetZeroTimeStampPeriod().
    virtual OSStatus SetZeroTimeStampPeriodImpl(UInt32 period);

    //! Set nominal sample rate.
    //! Invoked by SetNominalSampleRateAsync() to actually change the rate.
    //! Default implementation just changes the value returned by GetNominalSampleRate().
    //! @note
    //!  Backs @c kAudioDevicePropertyNominalSampleRate property.
    virtual OSStatus SetNominalSampleRateImpl(Float64 rate);

    //! Set list of supported nominal sample rates.
    //! Invoked by SetAvailableSampleRatesAsync() to actually change the list.
    //! Default implementation just updates the list returned by
    //! GetAvailableSampleRates().
    virtual OSStatus SetAvailableSampleRatesImpl(std::vector<AudioValueRange> rates);

    //! Set channels for stereo.
    //! Invoked by SetPreferredChannelsForStereoAsync() to actually change the value.
    //! Default implementation just changes the value returned
    //! GetPreferredChannelsForStereo().
    virtual OSStatus SetPreferredChannelsForStereoImpl(std::array<UInt32, 2> channels);

    //! Set preferred channel count.
    //! Invoked by SetPreferredChannelCountAsync() to actually change the value.
    //! Default implementation changes the value returned by GetPreferredChannelCount().
    //! By default, it also affects values returned by GetPreferredChannels() and
    //! GetPreferredChannelLayout().
    virtual OSStatus SetPreferredChannelCountImpl(UInt32 channelCount);

    //! Invoked by SetPreferredChannelsAsync() to actually change the value.
    //! Default implementation changes the value returned by GetPreferredChannels().
    //! By default, it also affects values returned by GetPreferredChannelCount() and
    //! GetPreferredChannelLayout().
    virtual OSStatus SetPreferredChannelsImpl(
        std::vector<AudioChannelDescription> channels);

    //! Invoked by SetPreferredChannelLayoutAsync() to actually change the value.
    //! Default implementation changes the value returned by GetPreferredChannelLayout().
    //! By default, it also affects values returned by GetPreferredChannelCount() and
    //! GetPreferredChannels().
    virtual OSStatus SetPreferredChannelLayoutImpl(std::vector<UInt8> channelLayout);

    //! Start or stop device identification.
    //! This can be requested by UI, but probably makes little sense to virtual devices.
    //! By default always fails.
    //! Invoked by SetIsIdentifying().
    //! @note
    //!  Backs @c kAudioObjectPropertyIdentify property.
    virtual OSStatus SetIsIdentifyingImpl(bool isIdentifying);

    //! Mark device as alive or dead.
    //! By default just changes the value returned by GetIsAlive().
    //! Invoked by SetIsAlive().
    virtual OSStatus SetIsAliveImpl(bool isAlive);

    //! Mark or unmark device as hidden.
    //! By default just changes the value returned by GetIsHidden().
    //! Invoked by SetIsHidden().
    virtual OSStatus SetIsHiddenImpl(bool isHidden);

    //! Set whether the device can be the default device for content.
    //! By default just changes the value returned by GetCanBeDefaultDevice().
    //! Invoked by SetCanBeDefaultDevice().
    virtual OSStatus SetCanBeDefaultDeviceImpl(bool value);

    //! Set whether the device can be the default device for system sounds.
    //! By default just changes the value returned by GetCanBeDefaultSystemDevice().
    //! Invoked by SetCanBeDefaultSystemDevice().
    virtual OSStatus SetCanBeDefaultSystemDeviceImpl(bool value);

    //! @}

    //! @name I/O implementation
    //! @{

    //! Prepare device to start I/O.
    //! Invoked by StartIO().
    //! @remarks
    //!  StartIOImpl() is responsible for preparing to serve I/O requests.
    //!  Default implementation invokes ControlRequestHandler::OnStartIO() and
    //!  resets anchor timestamp and period counters, which are then used by
    //!  GetZeroTimeStampImpl().
    //! @note
    //!  startCount is incremented each time when StartIO() is called, and
    //!  decremented when StopIO() is called. Zero startCount means that
    //!  the device is switching from non-running to running state, and
    //!  often only this case needs handling in StartIOImpl().
    //! @note
    //!  StartIOImpl() gets startCount before it's incremented.
    //! @note
    //!  For most uses cases, it is enough to provide ControlRequestHandler
    //!  and there is no need to override this method.
    virtual OSStatus StartIOImpl(UInt32 clientID, UInt32 startCount);

    //! Prepare device to finish I/O.
    //! Invoked by StopIO().
    //! @remarks
    //!  StopIOImpl() is responsible for cleanup after serving I/O requests.
    //!  Default implementation just invokes ControlRequestHandler::OnStopIO().
    //! @note
    //!  startCount is incremented each time when StartIO() is called, and
    //!  decremented when StopIO() is called. Zero startCount means that
    //!  the device is switching from running to non-running state, and
    //!  often only this case needs handling in StopIOImpl().
    //! @note
    //!  StopIOImpl() gets startCount after it's decremented.
    //! @note
    //!  For most uses cases, it is enough to provide ControlRequestHandler
    //!  and there is no need to override this method.
    virtual OSStatus StopIOImpl(UInt32 clientID, UInt32 startCount);

    //! Get the current zero timestamp for the device.
    //! Invoked by GetZeroTimeStamp().
    //! @remarks
    //!  In default implementation, the zero time stamp and host time are increased
    //!  every GetZeroTimeStampPeriod() frames. Default implementation also handles
    //!  sample rate changes by checking GetNominalSampleRate().
    virtual OSStatus GetZeroTimeStampImpl(UInt32 clientID,
        Float64* outSampleTime,
        UInt64* outHostTime,
        UInt64* outSeed);

    //! Asks device whether it want to perform the given phase of the IO cycle.
    //! Invoked by WillDoIOOperation().
    //! @remarks
    //!  In default implementation, makes decision based on whether the device has input
    //!  and output streams, and what is returned by DeviceParameters::EnableMixing.
    virtual OSStatus WillDoIOOperationImpl(UInt32 clientID,
        UInt32 operationID,
        Boolean* outWillDo,
        Boolean* outWillDoInPlace);

    //! Called before performing I/O operation.
    //! Invoked by BeginIOOperation().
    //! @remarks
    //!   Default implementation does nothing.
    virtual OSStatus BeginIOOperationImpl(UInt32 clientID,
        UInt32 operationID,
        UInt32 ioBufferFrameSize,
        const AudioServerPlugInIOCycleInfo* ioCycleInfo);

    //! Perform an IO operation for a particular stream.
    //! Invoked by DoIOOperation().
    //! @remarks
    //!  In default implementation, invokes corresponding method of I/O handler based on
    //!  passed operation type, for example OnReadInput() or OnWriteMixedOutput().
    virtual OSStatus DoIOOperationImpl(AudioObjectID streamID,
        UInt32 clientID,
        UInt32 operationID,
        UInt32 ioBufferFrameSize,
        const AudioServerPlugInIOCycleInfo* ioCycleInfo,
        void* ioMainBuffer,
        void* ioSecondaryBuffer);

    //! Called after performing I/O operation.
    //! Invoked by EndIOOperation().
    //! @remarks
    //!   Default implementation does nothing.
    virtual OSStatus EndIOOperationImpl(UInt32 clientID,
        UInt32 operationID,
        UInt32 ioBufferFrameSize,
        const AudioServerPlugInIOCycleInfo* ioCycleInfo);

    //! @}

private:
    // value checkers for async setters
    OSStatus CheckNominalSampleRate(Float64 rate) const;

    // these fields are immutable and can be accessed w/o lock
    const DeviceParameters params_;
    const std::string deviceUID_;

    // these fields may be accessed by both control and I/O operations w/o lock
    std::atomic<UInt32> numInputStreams_ = 0;
    std::atomic<UInt32> numOutputStreams_ = 0;

    std::atomic<bool> isAlive_ = true;
    std::atomic<bool> isHidden_ = false;

    std::atomic<bool> canBeDefaultDevice_;
    std::atomic<bool> canBeDefaultSystemDevice_;

    std::atomic<UInt32> latency_;
    std::atomic<UInt32> safetyOffset_;
    std::atomic<UInt32> zeroTimeStampPeriod_;
    std::atomic<Float64> nominalSampleRate_;

    std::atomic<SInt32> startCount_ = 0;

    // serializes writing to fields below
    mutable std::recursive_mutex writeMutex_;

    DoubleBuffer<std::optional<std::vector<AudioValueRange>>> availableSampleRates_;
    DoubleBuffer<std::array<UInt32, 2>> preferredChannelsForStereo_;
    DoubleBuffer<std::optional<UInt32>> preferredChannelCount_;
    DoubleBuffer<std::optional<std::vector<AudioChannelDescription>>> preferredChannels_;
    DoubleBuffer<std::optional<std::vector<UInt8>>> preferredChannelLayout_;

    DoubleBuffer<std::unordered_map<Direction, std::vector<std::shared_ptr<Stream>>>>
        streams_;

    DoubleBuffer<std::unordered_map<AudioObjectID, std::shared_ptr<Stream>>> streamByID_;

    DoubleBuffer<std::unordered_map<AudioObjectPropertyScope,
        std::vector<std::shared_ptr<VolumeControl>>>>
        volumeControls_;

    DoubleBuffer<std::unordered_map<AudioObjectID, std::shared_ptr<VolumeControl>>>
        volumeControlByID_;

    DoubleBuffer<std::unordered_map<AudioObjectPropertyScope,
        std::vector<std::shared_ptr<MuteControl>>>>
        muteControls_;

    DoubleBuffer<std::unordered_map<AudioObjectID, std::shared_ptr<MuteControl>>>
        muteControlByID_;

    DoubleBuffer<std::unordered_map<UInt32, std::shared_ptr<Client>>> clientByID_;

    DoubleBuffer<
        std::variant<std::shared_ptr<ControlRequestHandler>, ControlRequestHandler*>>
        controlHandler_;
    DoubleBuffer<std::variant<std::shared_ptr<IORequestHandler>, IORequestHandler*>>
        ioHandler_;

    std::map<UInt64, std::function<void()>> pendingConfigurationRequests_;
    UInt64 lastConfigurationRequestID_ = 0;
    UInt64 insideConfigurationHandler_ = 0;

    // serializes I/O operations and protects fields below
    mutable std::recursive_mutex ioMutex_;

    // how much host clock ticks are per audio frame and what was the sample
    // rate when this value was calculated
    Float64 hostTicksPerFrame_ = 0;
    Float64 lastSampleRate_ = 0;

    // time and period counter which are reset when I/O is (re-)started
    UInt64 anchorHostTime_ = 0;
    UInt64 periodCounter_ = 0;

    // current zero timestamp, last values returned by GetZeroTimeStamp()
    Float64 currentPeriodTimestamp_ = 0;
    UInt64 currentPeriodHostTime_ = 0;
};

} // namespace aspl
