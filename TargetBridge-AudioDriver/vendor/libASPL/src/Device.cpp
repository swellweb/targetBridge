// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/Device.hpp>

#include "Convert.hpp"
#include "Strings.hpp"
#include "Uid.hpp"
#include "Variant.hpp"
#include "VolumeCurve.hpp"

#include <algorithm>

#include <mach/mach_time.h>

namespace aspl {

Device::Device(std::shared_ptr<const Context> context, const DeviceParameters& params)
    : Object(std::move(context), "Device")
    , params_(params)
    , deviceUID_(!params.DeviceUID.empty() ? params.DeviceUID
                                           : params.ModelUID + ":" + GenerateUID())
    , canBeDefaultDevice_(params.CanBeDefault)
    , canBeDefaultSystemDevice_(params.CanBeDefaultForSystemSounds)
    , latency_(params.Latency)
    , safetyOffset_(params.SafetyOffset)
    , zeroTimeStampPeriod_(
          params_.ZeroTimeStampPeriod ? params_.ZeroTimeStampPeriod : params_.SampleRate)
    , nominalSampleRate_(params.SampleRate)
    , preferredChannelsForStereo_({1, 2})
{
    SetControlHandler(nullptr);
    SetIOHandler(nullptr);
}

std::string Device::GetName() const
{
    return params_.Name;
}

std::string Device::GetManufacturer() const
{
    return params_.Manufacturer;
}

std::string Device::GetDeviceUID() const
{
    return deviceUID_;
}

std::string Device::GetModelUID() const
{
    return params_.ModelUID;
}

std::string Device::GetSerialNumber() const
{
    return params_.SerialNumber;
}

std::string Device::GetFirmwareVersion() const
{
    return params_.FirmwareVersion;
}

std::string Device::GetIconURL() const
{
    return params_.IconURL;
}

std::string Device::GetConfigurationApplicationBundleID() const
{
    return params_.ConfigurationApplicationBundleID;
}

UInt32 Device::GetTransportType() const
{
    return kAudioDeviceTransportTypeVirtual;
}

std::vector<AudioObjectID> Device::GetRelatedDeviceIDs() const
{
    return {GetID()};
}

bool Device::GetClockIsStable() const
{
    return params_.ClockIsStable;
}

AudioDeviceClockAlgorithmSelector Device::GetClockAlgorithm() const
{
    return params_.ClockAlgorithm;
}

UInt32 Device::GetClockDomain() const
{
    return params_.ClockDomain;
}

UInt32 Device::GetLatency() const
{
    return latency_;
}

OSStatus Device::SetLatencyImpl(UInt32 latency)
{
    latency_ = latency;

    return kAudioHardwareNoError;
}

UInt32 Device::GetSafetyOffset() const
{
    return safetyOffset_;
}

OSStatus Device::SetSafetyOffsetImpl(UInt32 offset)
{
    safetyOffset_ = offset;

    return kAudioHardwareNoError;
}

UInt32 Device::GetZeroTimeStampPeriod() const
{
    return zeroTimeStampPeriod_;
}

OSStatus Device::SetZeroTimeStampPeriodImpl(UInt32 period)
{
    zeroTimeStampPeriod_ = period;

    return kAudioHardwareNoError;
}

Float64 Device::GetNominalSampleRate() const
{
    return nominalSampleRate_;
}

OSStatus Device::CheckNominalSampleRate(Float64 rate) const
{
    const auto availRates = GetAvailableSampleRates();

    if (availRates.empty()) {
        return kAudioHardwareNoError;
    }

    if (std::find_if(availRates.begin(), availRates.end(), [rate](const auto& range) {
            return rate >= range.mMinimum && rate <= range.mMaximum;
        }) != availRates.end()) {
        return kAudioHardwareNoError;
    }

    GetContext()->Tracer->Message("rate %f is not supported", rate);

    return kAudioHardwareUnsupportedOperationError;
}

OSStatus Device::SetNominalSampleRateImpl(Float64 rate)
{
    nominalSampleRate_ = rate;

    return kAudioHardwareNoError;
}

std::vector<AudioValueRange> Device::GetAvailableSampleRates() const
{
    if (auto rates = availableSampleRates_.Get()) {
        return *rates;
    }

    const auto sampleRate = GetNominalSampleRate();

    AudioValueRange range;
    range.mMinimum = sampleRate;
    range.mMaximum = sampleRate;

    return {range};
}

OSStatus Device::SetAvailableSampleRatesImpl(std::vector<AudioValueRange> rates)
{
    availableSampleRates_.Set(std::move(rates));

    return kAudioHardwareNoError;
}

std::array<UInt32, 2> Device::GetPreferredChannelsForStereo() const
{
    return preferredChannelsForStereo_.Get();
}

OSStatus Device::SetPreferredChannelsForStereoImpl(std::array<UInt32, 2> channels)
{
    preferredChannelsForStereo_.Set(channels);

    return kAudioHardwareNoError;
}

UInt32 Device::GetPreferredChannelCount() const
{
    // If SetPreferredChannelCount() was called, use that value.
    if (auto channelCount = preferredChannelCount_.Get()) {
        return *channelCount;
    }

    // If SetPreferredChannelsAsync() was called, use that value.
    if (auto chans = preferredChannels_.Get(); chans && !chans->empty()) {
        return UInt32(chans->size());
    }

    // If SetPreferredChannelLayoutAsync() was called, use that value.
    if (auto layoutBuffer = preferredChannelLayout_.Get();
        layoutBuffer && !layoutBuffer->empty()) {
        const AudioChannelLayout* layout =
            reinterpret_cast<AudioChannelLayout*>(layoutBuffer->data());

        if (layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions) {
            return layout->mNumberChannelDescriptions;
        }
    }

    // Default value.
    return params_.ChannelCount;
}

OSStatus Device::SetPreferredChannelCountImpl(UInt32 channelCount)
{
    preferredChannelCount_.Set(channelCount);

    return kAudioHardwareNoError;
}

std::vector<AudioChannelDescription> Device::GetPreferredChannels() const
{
    // If SetPreferredChannelsAsync() was called, use that value.
    if (auto chans = preferredChannels_.Get()) {
        return *chans;
    }

    // If SetPreferredChannelLayoutAsync() was called, use that value.
    if (auto layoutBuffer = preferredChannelLayout_.Get();
        layoutBuffer && !layoutBuffer->empty()) {
        const AudioChannelLayout* layout =
            reinterpret_cast<AudioChannelLayout*>(layoutBuffer->data());

        if (layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions) {
            return std::vector(layout->mChannelDescriptions,
                layout->mChannelDescriptions + layout->mNumberChannelDescriptions);
        }
    }

    // Construct value based on GetPreferredChannelCount().
    std::vector<AudioChannelDescription> chans(GetPreferredChannelCount());

    for (size_t n = 0; n < chans.size(); n++) {
        chans[n].mChannelLabel = kAudioChannelLabel_Left + UInt32(n);
        chans[n].mChannelFlags = 0;
        chans[n].mCoordinates[0] = 0;
        chans[n].mCoordinates[1] = 0;
        chans[n].mCoordinates[2] = 0;
    }

    return chans;
}

OSStatus Device::SetPreferredChannelsImpl(std::vector<AudioChannelDescription> channels)
{
    preferredChannels_.Set(std::move(channels));

    return kAudioHardwareNoError;
}

std::vector<UInt8> Device::GetPreferredChannelLayout() const
{
    // If SetPreferredChannelLayoutAsync() was called, use that value.
    if (auto layoutBuffer = preferredChannelLayout_.Get()) {
        return *layoutBuffer;
    }

    // Construct value based on GetPreferredChannels().
    const auto chans = GetPreferredChannels();

    const size_t layoutSize = offsetof(AudioChannelLayout, mChannelDescriptions) +
                              chans.size() * sizeof(AudioChannelDescription);

    std::vector<UInt8> layoutBuffer(layoutSize);

    AudioChannelLayout* layout =
        reinterpret_cast<AudioChannelLayout*>(layoutBuffer.data());

    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    layout->mChannelBitmap = 0;
    layout->mNumberChannelDescriptions = UInt32(chans.size());

    for (size_t n = 0; n < chans.size(); n++) {
        layout->mChannelDescriptions[n] = chans[n];
    }

    return layoutBuffer;
}

OSStatus Device::SetPreferredChannelLayoutImpl(std::vector<UInt8> channelLayout)
{
    preferredChannelLayout_.Set(std::move(channelLayout));

    return kAudioHardwareNoError;
}

bool Device::GetIsRunning() const
{
    return startCount_ > 0;
}

bool Device::GetIsIdentifying() const
{
    return false;
}

OSStatus Device::SetIsIdentifyingImpl(bool isIdentifying)
{
    return kAudioHardwareUnsupportedOperationError;
}

bool Device::GetIsAlive() const
{
    return isAlive_;
}

OSStatus Device::SetIsAliveImpl(bool isAlive)
{
    isAlive_ = isAlive;

    return kAudioHardwareNoError;
}

bool Device::GetIsHidden() const
{
    return isHidden_;
}

OSStatus Device::SetIsHiddenImpl(bool isHidden)
{
    isHidden_ = isHidden;

    return kAudioHardwareNoError;
}

bool Device::GetCanBeDefaultDevice() const
{
    return canBeDefaultDevice_;
}

OSStatus Device::SetCanBeDefaultDeviceImpl(bool value)
{
    canBeDefaultDevice_ = value;

    return kAudioHardwareNoError;
}

bool Device::GetCanBeDefaultSystemDevice() const
{
    return canBeDefaultSystemDevice_;
}

OSStatus Device::SetCanBeDefaultSystemDeviceImpl(bool value)
{
    canBeDefaultSystemDevice_ = value;

    return kAudioHardwareNoError;
}

std::vector<AudioObjectID> Device::GetStreamIDs(AudioObjectPropertyScope scope) const
{
    return GetOwnedObjectIDs(scope, kAudioStreamClassID);
}

std::vector<AudioObjectID> Device::GetControlIDs(AudioObjectPropertyScope scope) const
{
    return GetOwnedObjectIDs(scope, kAudioControlClassID);
}

UInt32 Device::GetStreamCount(Direction dir) const
{
    auto readLock = streams_.GetReadLock();

    const auto& streams = readLock.GetReference();

    if (!streams.count(dir)) {
        return 0;
    }

    return UInt32(streams.at(dir).size());
}

std::shared_ptr<Stream> Device::GetStreamByIndex(Direction dir, UInt32 idx) const
{
    auto readLock = streams_.GetReadLock();

    const auto& streams = readLock.GetReference();

    if (!streams.count(dir)) {
        return {};
    }

    const auto& streamList = streams.at(dir);
    if (streamList.size() <= idx) {
        return {};
    }

    return streamList[idx];
}

std::shared_ptr<Stream> Device::GetStreamByID(AudioObjectID streamID) const
{
    auto readLock = streamByID_.GetReadLock();

    const auto& streamByID = readLock.GetReference();

    auto iter = streamByID.find(streamID);
    if (iter == streamByID.end()) {
        return {};
    }

    return iter->second;
}

std::shared_ptr<Stream> Device::AddStreamWithControlsAsync(Direction dir)
{
    std::lock_guard writeLock(writeMutex_);

    auto stream = AddStreamAsync(dir);

    auto volumeControl =
        AddVolumeControlAsync(dir == Direction::Output ? kAudioObjectPropertyScopeOutput
                                                       : kAudioObjectPropertyScopeInput);

    auto muteControl =
        AddMuteControlAsync(dir == Direction::Output ? kAudioObjectPropertyScopeOutput
                                                     : kAudioObjectPropertyScopeInput);

    stream->AttachVolumeControl(volumeControl);
    stream->AttachMuteControl(muteControl);

    return stream;
}

std::shared_ptr<Stream> Device::AddStreamWithControlsAsync(const StreamParameters& params)
{
    std::lock_guard writeLock(writeMutex_);

    auto stream = AddStreamAsync(params);

    auto volumeControl = AddVolumeControlAsync(params.Direction == Direction::Output
                                                   ? kAudioObjectPropertyScopeOutput
                                                   : kAudioObjectPropertyScopeInput);

    auto muteControl = AddMuteControlAsync(params.Direction == Direction::Output
                                               ? kAudioObjectPropertyScopeOutput
                                               : kAudioObjectPropertyScopeInput);

    stream->AttachVolumeControl(volumeControl);
    stream->AttachMuteControl(muteControl);

    return stream;
}

std::shared_ptr<Stream> Device::AddStreamAsync(Direction dir)
{
    std::lock_guard writeLock(writeMutex_);

    StreamParameters params;

    params.Direction = dir;
    params.Format.mSampleRate = GetNominalSampleRate();
    params.Format.mChannelsPerFrame = GetPreferredChannelCount();
    params.Format.mBytesPerFrame =
        params.Format.mChannelsPerFrame * (params.Format.mBitsPerChannel / 8);
    params.Format.mFramesPerPacket = 1;
    params.Format.mBytesPerPacket = params.Format.mBytesPerFrame;
    params.StartingChannel = 1;

    {
        auto readLock = streams_.GetReadLock();

        const auto& streams = readLock.GetReference();

        if (streams.count(dir)) {
            for (const auto& stream : streams.at(dir)) {
                params.StartingChannel = std::max(params.StartingChannel,
                    stream->GetStartingChannel() + stream->GetChannelCount());
            }
        }
    }

    return AddStreamAsync(params);
}

std::shared_ptr<Stream> Device::AddStreamAsync(const StreamParameters& params)
{
    auto stream = std::make_shared<Stream>(
        GetContext(), std::static_pointer_cast<Device>(shared_from_this()), params);

    AddStreamAsync(stream);

    return stream;
}

void Device::AddStreamAsync(std::shared_ptr<Stream> stream)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::AddStreamAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    if (stream) {
        const auto dir = stream->GetDirection();

        {
            auto streams = streams_.Get();

            streams[dir].push_back(stream);
            streams_.Set(std::move(streams));
        }

        {
            auto streamByID = streamByID_.Get();

            streamByID[stream->GetID()] = stream;
            streamByID_.Set(std::move(streamByID));
        }

        RequestConfigurationChange([this, stream, dir]() {
            if (dir == Direction::Input) {
                numInputStreams_++;
            } else {
                numOutputStreams_++;
            }

            AddOwnedObject(stream,
                dir == Direction::Input ? kAudioObjectPropertyScopeInput
                                        : kAudioObjectPropertyScopeOutput);
        });
    } else {
        GetContext()->Tracer->Message("stream is null");
    }

    GetContext()->Tracer->OperationEnd(op, kAudioHardwareNoError);
}

void Device::RemoveStreamAsync(std::shared_ptr<Stream> stream)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::RemoveStreamAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    if (stream) {
        const auto dir = stream->GetDirection();

        {
            auto streams = streams_.Get();

            streams[dir].erase(
                std::remove(streams[dir].begin(), streams[dir].end(), stream),
                streams[dir].end());

            streams_.Set(std::move(streams));
        }

        {
            auto streamByID = streamByID_.Get();

            streamByID.erase(stream->GetID());
            streamByID_.Set(std::move(streamByID));
        }

        RequestConfigurationChange([this, stream, dir]() {
            if (dir == Direction::Input) {
                numInputStreams_--;
            } else {
                numOutputStreams_--;
            }

            RemoveOwnedObject(stream->GetID());
        });
    } else {
        GetContext()->Tracer->Message("stream is null");
    }

    GetContext()->Tracer->OperationEnd(op, kAudioHardwareNoError);
}

UInt32 Device::GetVolumeControlCount(AudioObjectPropertyScope scope) const
{
    auto readLock = volumeControls_.GetReadLock();

    const auto& volumeControls = readLock.GetReference();

    if (!volumeControls.count(scope)) {
        return 0;
    }

    return UInt32(volumeControls.at(scope).size());
}

std::shared_ptr<VolumeControl> Device::GetVolumeControlByIndex(
    AudioObjectPropertyScope scope,
    UInt32 idx) const
{
    auto readLock = volumeControls_.GetReadLock();

    const auto& volumeControls = readLock.GetReference();

    if (!volumeControls.count(scope)) {
        return {};
    }

    const auto& controlList = volumeControls.at(scope);
    if (controlList.size() <= idx) {
        return {};
    }

    return controlList[idx];
}

std::shared_ptr<VolumeControl> Device::GetVolumeControlByID(AudioObjectID controlID) const
{
    auto readLock = volumeControlByID_.GetReadLock();

    const auto& controlByID = readLock.GetReference();

    if (!controlByID.count(controlID)) {
        return {};
    }

    return controlByID.at(controlID);
}

std::shared_ptr<VolumeControl> Device::AddVolumeControlAsync(
    AudioObjectPropertyScope scope)
{
    VolumeControlParameters params;
    params.Scope = scope;

    return AddVolumeControlAsync(params);
}

std::shared_ptr<VolumeControl> Device::AddVolumeControlAsync(
    const VolumeControlParameters& params)
{
    auto control = std::make_shared<VolumeControl>(GetContext(), params);

    AddVolumeControlAsync(control);

    return control;
}

void Device::AddVolumeControlAsync(std::shared_ptr<VolumeControl> control)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::AddVolumeControlAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    if (control) {
        const auto scope = control->GetScope();

        {
            auto controls = volumeControls_.Get();

            controls[scope].push_back(control);
            volumeControls_.Set(std::move(controls));
        }

        {
            auto controlByID = volumeControlByID_.Get();

            controlByID[control->GetID()] = control;
            volumeControlByID_.Set(std::move(controlByID));
        }

        RequestConfigurationChange([this, control, scope]() {
            AddOwnedObject(control, scope);
        });
    } else {
        GetContext()->Tracer->Message("control is null");
    }

    GetContext()->Tracer->OperationEnd(op, kAudioHardwareNoError);
}

void Device::RemoveVolumeControlAsync(std::shared_ptr<VolumeControl> control)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::RemoveVolumeControlAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    if (control) {
        const auto scope = control->GetScope();

        {
            auto controls = volumeControls_.Get();

            controls[scope].erase(
                std::remove(controls[scope].begin(), controls[scope].end(), control),
                controls[scope].end());

            volumeControls_.Set(std::move(controls));
        }

        {
            auto controlByID = volumeControlByID_.Get();

            controlByID.erase(control->GetID());
            volumeControlByID_.Set(std::move(controlByID));
        }

        RequestConfigurationChange([this, control]() {
            RemoveOwnedObject(control->GetID());
        });
    } else {
        GetContext()->Tracer->Message("control is null");
    }

    GetContext()->Tracer->OperationEnd(op, kAudioHardwareNoError);
}

UInt32 Device::GetMuteControlCount(AudioObjectPropertyScope scope) const
{
    auto readLock = muteControls_.GetReadLock();

    const auto& muteControls = readLock.GetReference();

    if (!muteControls.count(scope)) {
        return 0;
    }

    return UInt32(muteControls.at(scope).size());
}

std::shared_ptr<MuteControl> Device::GetMuteControlByIndex(AudioObjectPropertyScope scope,
    UInt32 idx) const
{
    auto readLock = muteControls_.GetReadLock();

    const auto& muteControls = readLock.GetReference();

    if (!muteControls.count(scope)) {
        return {};
    }

    const auto& controlList = muteControls.at(scope);
    if (controlList.size() <= idx) {
        return {};
    }

    return controlList[idx];
}

std::shared_ptr<MuteControl> Device::GetMuteControlByID(AudioObjectID controlID) const
{
    auto readLock = muteControlByID_.GetReadLock();

    const auto& controlByID = readLock.GetReference();

    if (!controlByID.count(controlID)) {
        return {};
    }

    return controlByID.at(controlID);
}

std::shared_ptr<MuteControl> Device::AddMuteControlAsync(AudioObjectPropertyScope scope)
{
    MuteControlParameters params;
    params.Scope = scope;

    return AddMuteControlAsync(params);
}

std::shared_ptr<MuteControl> Device::AddMuteControlAsync(
    const MuteControlParameters& params)
{
    auto control = std::make_shared<MuteControl>(GetContext(), params);

    AddMuteControlAsync(control);

    return control;
}

void Device::AddMuteControlAsync(std::shared_ptr<MuteControl> control)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::AddMuteControlAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    if (control) {
        const auto scope = control->GetScope();

        {
            auto controls = muteControls_.Get();

            controls[scope].push_back(control);
            muteControls_.Set(std::move(controls));
        }

        {
            auto controlByID = muteControlByID_.Get();

            controlByID[control->GetID()] = control;
            muteControlByID_.Set(std::move(controlByID));
        }

        RequestConfigurationChange([this, control, scope]() {
            AddOwnedObject(control, scope);
        });
    } else {
        GetContext()->Tracer->Message("control is null");
    }

    GetContext()->Tracer->OperationEnd(op, kAudioHardwareNoError);
}

void Device::RemoveMuteControlAsync(std::shared_ptr<MuteControl> control)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::RemoveMuteControlAsync()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    if (control) {
        const auto scope = control->GetScope();

        {
            auto controls = muteControls_.Get();

            controls[scope].erase(
                std::remove(controls[scope].begin(), controls[scope].end(), control),
                controls[scope].end());

            muteControls_.Set(std::move(controls));
        }

        {
            auto controlByID = muteControlByID_.Get();

            controlByID.erase(control->GetID());
            muteControlByID_.Set(std::move(controlByID));
        }

        RequestConfigurationChange([this, control]() {
            RemoveOwnedObject(control->GetID());
        });
    } else {
        GetContext()->Tracer->Message("control is null");
    }

    GetContext()->Tracer->OperationEnd(op, kAudioHardwareNoError);
}

void Device::SetControlHandler(std::shared_ptr<ControlRequestHandler> handler)
{
    std::lock_guard writeLock(writeMutex_);

    if (handler) {
        controlHandler_.Set(std::move(handler));
    } else {
        // no-op handler
        controlHandler_.Set(std::make_shared<ControlRequestHandler>());
    }
}

void Device::SetControlHandler(ControlRequestHandler* handler)
{
    std::lock_guard writeLock(writeMutex_);

    if (handler) {
        controlHandler_.Set(handler);
    } else {
        // no-op handler
        controlHandler_.Set(std::make_shared<ControlRequestHandler>());
    }
}

ControlRequestHandler* Device::GetControlHandler() const
{
    return GetVariantPtr(controlHandler_.Get());
}

OSStatus Device::AddClient(AudioObjectID objectID,
    const AudioServerPlugInClientInfo* rawClientInfo)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::AddClient()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;
    ClientInfo clientInfo;

    auto clientByID = clientByID_.Get();

    if (objectID != GetID()) {
        GetContext()->Tracer->Message("object not found");
        status = kAudioHardwareBadObjectError;
        goto end;
    }

    if (!rawClientInfo) {
        GetContext()->Tracer->Message("client info is null");
        status = kAudioHardwareIllegalOperationError;
        goto end;
    }

    clientInfo.ClientID = rawClientInfo->mClientID;
    clientInfo.ProcessID = rawClientInfo->mProcessID;
    clientInfo.IsNativeEndian = rawClientInfo->mIsNativeEndian;
    Convert::FromFoundation(rawClientInfo->mBundleID, clientInfo.BundleID);

    GetContext()->Tracer->Message(
        "client info: clientID=%u processID=%u isNativeEndian=%d bundleID=%s",
        unsigned(clientInfo.ClientID),
        unsigned(clientInfo.ProcessID),
        int(clientInfo.IsNativeEndian),
        clientInfo.BundleID.c_str());

    {
        auto client = GetControlHandler()->OnAddClient(clientInfo);
        if (!client) {
            GetContext()->Tracer->Message("control handler failed");
            status = kAudioHardwareUnspecifiedError;
            goto end;
        }

        clientByID[clientInfo.ClientID] = client;
        clientByID_.Set(std::move(clientByID));
    }

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::RemoveClient(AudioObjectID objectID,
    const AudioServerPlugInClientInfo* rawClientInfo)
{
    std::lock_guard writeLock(writeMutex_);

    Tracer::Operation op;
    op.Name = "Device::RemoveClient()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    OSStatus status = kAudioHardwareNoError;
    ClientInfo clientInfo;

    auto clientByID = clientByID_.Get();

    if (objectID != GetID()) {
        GetContext()->Tracer->Message("object not found");
        status = kAudioHardwareBadObjectError;
        goto end;
    }

    if (!rawClientInfo) {
        GetContext()->Tracer->Message("client info is null");
        status = kAudioHardwareIllegalOperationError;
        goto end;
    }

    clientInfo.ClientID = rawClientInfo->mClientID;
    clientInfo.ProcessID = rawClientInfo->mProcessID;
    clientInfo.IsNativeEndian = rawClientInfo->mIsNativeEndian;
    Convert::FromFoundation(rawClientInfo->mBundleID, clientInfo.BundleID);

    GetContext()->Tracer->Message(
        "client info: clientID=%u processID=%u isNativeEndian=%d bundleID=%s",
        unsigned(clientInfo.ClientID),
        unsigned(clientInfo.ProcessID),
        int(clientInfo.IsNativeEndian),
        clientInfo.BundleID.c_str());

    if (!clientByID.count(rawClientInfo->mClientID)) {
        GetContext()->Tracer->Message(
            "client %u not found", unsigned(rawClientInfo->mClientID));
        status = kAudioHardwareIllegalOperationError;
        goto end;
    }

    {
        auto client = clientByID.at(rawClientInfo->mClientID);

        clientByID.erase(clientInfo.ClientID);
        clientByID_.Set(std::move(clientByID));

        GetControlHandler()->OnRemoveClient(std::move(client));
    }

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

UInt32 Device::GetClientCount() const
{
    auto readLock = clientByID_.GetReadLock();

    const auto& clientByID = readLock.GetReference();

    return UInt32(clientByID.size());
}

std::vector<std::shared_ptr<Client>> Device::GetClients() const
{
    auto readLock = clientByID_.GetReadLock();

    const auto& clientByID = readLock.GetReference();

    std::vector<std::shared_ptr<Client>> ret;

    for (const auto& it : clientByID) {
        ret.push_back(it.second);
    }

    return ret;
}

std::shared_ptr<Client> Device::GetClientByID(UInt32 clientID) const
{
    auto readLock = clientByID_.GetReadLock();

    const auto& clientByID = readLock.GetReference();

    auto iter = clientByID.find(clientID);
    if (iter == clientByID.end()) {
        return {};
    }

    return iter->second;
}

OSStatus Device::StartIO(AudioObjectID objectID, UInt32 clientID)
{
    std::lock_guard ioLock(ioMutex_);

    Tracer::Operation op;
    op.Name = "Device::StartIO()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    const bool isStarting = (startCount_ == 0);

    OSStatus status = kAudioHardwareNoError;

    if (objectID != GetID()) {
        GetContext()->Tracer->Message("object not found");
        status = kAudioHardwareBadObjectError;
        goto end;
    }

    if (isStarting) {
        GetContext()->Tracer->Message("starting io: clientID=%u", unsigned(clientID));
    }

    status = StartIOImpl(clientID, startCount_);

    if (status != kAudioHardwareNoError) {
        goto end;
    }

    startCount_++;

    if (isStarting) {
        NotifyPropertyChanged(kAudioDevicePropertyDeviceIsRunning);
    }

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::StartIOImpl(UInt32 clientID, UInt32 startCount)
{
    OSStatus status = kAudioHardwareNoError;

    if (startCount == 0) {
        status = GetControlHandler()->OnStartIO();

        if (status != kAudioHardwareNoError) {
            goto end;
        }

        anchorHostTime_ = mach_absolute_time();
        periodCounter_ = 0;
    }

end:
    return status;
}

OSStatus Device::StopIO(AudioObjectID objectID, UInt32 clientID)
{
    std::lock_guard ioLock(ioMutex_);

    Tracer::Operation op;
    op.Name = "Device::StopIO()";
    op.ObjectID = GetID();

    GetContext()->Tracer->OperationBegin(op);

    const bool isStopping = (startCount_ == 1);

    OSStatus status = kAudioHardwareNoError;

    if (objectID != GetID()) {
        GetContext()->Tracer->Message("object not found");
        status = kAudioHardwareBadObjectError;
        goto end;
    }

    if (isStopping) {
        GetContext()->Tracer->Message("stopping io: clientID=%u", unsigned(clientID));
    }

    status = StopIOImpl(clientID, startCount_ - 1);

    if (status != kAudioHardwareNoError) {
        goto end;
    }

    startCount_--;

    if (isStopping) {
        NotifyPropertyChanged(kAudioDevicePropertyDeviceIsRunning);
    }

end:
    GetContext()->Tracer->OperationEnd(op, status);

    return status;
}

OSStatus Device::StopIOImpl(UInt32 clientID, UInt32 startCount)
{
    if (startCount == 0) {
        GetControlHandler()->OnStopIO();
    }

    return kAudioHardwareNoError;
}

void Device::SetIOHandler(std::shared_ptr<IORequestHandler> handler)
{
    std::lock_guard writeLock(writeMutex_);

    if (handler) {
        ioHandler_.Set(std::move(handler));
    } else {
        // no-op handler
        ioHandler_.Set(std::make_shared<IORequestHandler>());
    }
}

void Device::SetIOHandler(IORequestHandler* handler)
{
    std::lock_guard writeLock(writeMutex_);

    if (handler) {
        ioHandler_.Set(handler);
    } else {
        // no-op handler
        ioHandler_.Set(std::make_shared<IORequestHandler>());
    }
}

IORequestHandler* Device::GetIOHandler() const
{
    return GetVariantPtr(ioHandler_.Get());
}

OSStatus Device::GetZeroTimeStamp(AudioObjectID objectID,
    UInt32 clientID,
    Float64* outSampleTime,
    UInt64* outHostTime,
    UInt64* outSeed)
{
    std::lock_guard ioLock(ioMutex_);

    Tracer::Operation op;
    op.Name = "Device::GetZeroTimeStamp()";
    op.Flags = (Tracer::Flags::Realtime | Tracer::Flags::Readonly);
    op.ObjectID = GetID();

    if (params_.EnableRealtimeTracing) {
        GetContext()->Tracer->OperationBegin(op);
    }

    OSStatus status = kAudioHardwareNoError;

    if (objectID != GetID()) {
        status = kAudioHardwareBadObjectError;
        goto end;
    }

    status = GetZeroTimeStampImpl(clientID, outSampleTime, outHostTime, outSeed);

    if (status != kAudioHardwareNoError) {
        goto end;
    }

    if (params_.EnableRealtimeTracing) {
        GetContext()->Tracer->Message(
            "returning"
            " outSampleTime=%f"
            " outHostTime=%lu"
            " outSeed=%lu",
            *outSampleTime,
            static_cast<unsigned long>(*outHostTime),
            static_cast<unsigned long>(*outSeed));
    }

end:
    if (params_.EnableRealtimeTracing) {
        GetContext()->Tracer->OperationEnd(op, status);
    }

    return status;
}

OSStatus Device::GetZeroTimeStampImpl(UInt32 clientID,
    Float64* outSampleTime,
    UInt64* outHostTime,
    UInt64* outSeed)
{
    if (const Float64 newSampleRate = GetNominalSampleRate();
        newSampleRate != lastSampleRate_) {
        // Handle sample rate change.
        struct mach_timebase_info timeBase;
        mach_timebase_info(&timeBase);

        Float64 hostClockFrequency = Float64(timeBase.denom) / timeBase.numer;
        hostClockFrequency *= 1000000000.0;

        hostTicksPerFrame_ = hostClockFrequency / newSampleRate;
        lastSampleRate_ = newSampleRate;
    }

    const UInt64 currentHostTime = mach_absolute_time();

    const Float64 framesPerPeriod = GetZeroTimeStampPeriod();
    const Float64 hostTicksPerPeriod = hostTicksPerFrame_ * framesPerPeriod;

    {
        const UInt64 nextPeriodHostTime =
            anchorHostTime_ + UInt64(Float64(periodCounter_ + 1) * hostTicksPerPeriod);

        if (currentHostTime >= nextPeriodHostTime) {
            periodCounter_++;
        }
    }

    currentPeriodTimestamp_ = periodCounter_ * framesPerPeriod;
    currentPeriodHostTime_ =
        anchorHostTime_ + UInt64(Float64(periodCounter_) * hostTicksPerPeriod);

    *outSampleTime = currentPeriodTimestamp_;
    *outHostTime = currentPeriodHostTime_;
    *outSeed = 1;

    return kAudioHardwareNoError;
}

OSStatus Device::WillDoIOOperation(AudioObjectID objectID,
    UInt32 clientID,
    UInt32 operationID,
    Boolean* outWillDo,
    Boolean* outWillDoInPlace)
{
    std::lock_guard ioLock(ioMutex_);

    Tracer::Operation op;
    op.Name = "Device::WillDoIOOperation()";
    op.Flags = (Tracer::Flags::Realtime | Tracer::Flags::Readonly);
    op.ObjectID = GetID();

    if (params_.EnableRealtimeTracing) {
        GetContext()->Tracer->OperationBegin(op);
    }

    OSStatus status = kAudioHardwareNoError;

    if (objectID != GetID()) {
        status = kAudioHardwareBadObjectError;
        goto end;
    }

    *outWillDo = false;
    *outWillDoInPlace = false;

    status = WillDoIOOperationImpl(clientID, operationID, outWillDo, outWillDoInPlace);

    if (status != kAudioHardwareNoError) {
        goto end;
    }

    if (params_.EnableRealtimeTracing) {
        GetContext()->Tracer->Message("%s WillDo=%d WillDoInPlace=%d",
            OperationIDToString(operationID).c_str(),
            int(*outWillDo),
            int(*outWillDoInPlace));
    }

end:
    if (params_.EnableRealtimeTracing) {
        GetContext()->Tracer->OperationEnd(op, status);
    }

    return status;
}

OSStatus Device::WillDoIOOperationImpl(UInt32 clientID,
    UInt32 operationID,
    Boolean* outWillDo,
    Boolean* outWillDoInPlace)
{
    switch (operationID) {
    case kAudioServerPlugInIOOperationReadInput:
    case kAudioServerPlugInIOOperationProcessInput:
        if (numInputStreams_ > 0) {
            *outWillDo = true;
            *outWillDoInPlace = true;
        }
        break;

    case kAudioServerPlugInIOOperationMixOutput:
        if (numOutputStreams_ > 0 && !params_.EnableMixing) {
            *outWillDo = true;
            *outWillDoInPlace = true;
        }
        break;

    case kAudioServerPlugInIOOperationProcessMix:
    case kAudioServerPlugInIOOperationWriteMix:
        if (numOutputStreams_ > 0 && params_.EnableMixing) {
            *outWillDo = true;
            *outWillDoInPlace = true;
        }
        break;

    default:
        break;
    }

    return kAudioHardwareNoError;
}

OSStatus Device::BeginIOOperation(AudioObjectID objectID,
    UInt32 clientID,
    UInt32 operationID,
    UInt32 ioFrameCount,
    const AudioServerPlugInIOCycleInfo* ioCycleInfo)
{
    std::lock_guard ioLock(ioMutex_);

    if (params_.EnableRealtimeTracing) {
        GetContext()->Tracer->Message("Device::BeginIOOperation()");
    }

    OSStatus status = kAudioHardwareNoError;

    if (objectID != GetID()) {
        status = kAudioHardwareBadObjectError;
        goto end;
    }

    status = BeginIOOperationImpl(clientID, operationID, ioFrameCount, ioCycleInfo);

end:
    return status;
}

OSStatus Device::BeginIOOperationImpl(UInt32 clientID,
    UInt32 operationID,
    UInt32 ioFrameCount,
    const AudioServerPlugInIOCycleInfo* ioCycleInfo)
{
    return kAudioHardwareNoError;
}

OSStatus Device::DoIOOperation(AudioObjectID objectID,
    AudioObjectID streamID,
    UInt32 clientID,
    UInt32 operationID,
    UInt32 ioFrameCount,
    const AudioServerPlugInIOCycleInfo* ioCycleInfo,
    void* ioMainBuffer,
    void* ioSecondaryBuffer)
{
    std::lock_guard ioLock(ioMutex_);

    Tracer::Operation op;
    op.Name = "Device::DoIOOperation()";
    op.Flags = Tracer::Flags::Realtime;
    op.ObjectID = GetID();

    if (params_.EnableRealtimeTracing) {
        GetContext()->Tracer->OperationBegin(op);

        GetContext()->Tracer->Message(
            "%s StreamID=%u ClientID=%u NumFrames=%u InTs=%f OutTs=%f ZeroTs=%f",
            OperationIDToString(operationID).c_str(),
            unsigned(streamID),
            unsigned(clientID),
            unsigned(ioFrameCount),
            ioCycleInfo->mInputTime.mSampleTime,
            ioCycleInfo->mOutputTime.mSampleTime,
            currentPeriodTimestamp_);
    }

    OSStatus status = kAudioHardwareNoError;

    if (objectID != GetID()) {
        status = kAudioHardwareBadObjectError;
        goto end;
    }

    status = DoIOOperationImpl(streamID,
        clientID,
        operationID,
        ioFrameCount,
        ioCycleInfo,
        ioMainBuffer,
        ioSecondaryBuffer);

end:
    if (params_.EnableRealtimeTracing) {
        GetContext()->Tracer->OperationEnd(op, status);
    }

    return status;
}

OSStatus Device::DoIOOperationImpl(AudioObjectID streamID,
    UInt32 clientID,
    UInt32 operationID,
    UInt32 ioFrameCount,
    const AudioServerPlugInIOCycleInfo* ioCycleInfo,
    void* ioMainBuffer,
    void* ioSecondaryBuffer)
{
    auto client = GetClientByID(clientID);
    auto stream = GetStreamByID(streamID);

    if (!stream) {
        return kAudioHardwareIllegalOperationError;
    }

    const auto ioBytesCount = stream->ConvertFramesToBytes(ioFrameCount);
    const auto ioChannelCount = stream->GetChannelCount();

    const auto ioHandler = GetIOHandler();

    switch (operationID) {
    case kAudioServerPlugInIOOperationReadInput:
        ioHandler->OnReadClientInput(client,
            stream,
            currentPeriodTimestamp_,
            ioCycleInfo->mInputTime.mSampleTime,
            ioMainBuffer,
            ioBytesCount);
        break;

    case kAudioServerPlugInIOOperationProcessInput:
        ioHandler->OnProcessClientInput(client,
            stream,
            currentPeriodTimestamp_,
            ioCycleInfo->mInputTime.mSampleTime,
            static_cast<Float32*>(ioMainBuffer),
            ioFrameCount,
            ioChannelCount);
        break;

    case kAudioServerPlugInIOOperationMixOutput:
        ioHandler->OnProcessClientOutput(client,
            stream,
            currentPeriodTimestamp_,
            ioCycleInfo->mOutputTime.mSampleTime,
            static_cast<Float32*>(ioMainBuffer),
            ioFrameCount,
            ioChannelCount);

        ioHandler->OnWriteClientOutput(client,
            stream,
            currentPeriodTimestamp_,
            ioCycleInfo->mOutputTime.mSampleTime,
            static_cast<const Float32*>(ioMainBuffer),
            ioFrameCount,
            ioChannelCount);
        break;

    case kAudioServerPlugInIOOperationProcessMix:
        ioHandler->OnProcessMixedOutput(stream,
            currentPeriodTimestamp_,
            ioCycleInfo->mOutputTime.mSampleTime,
            static_cast<Float32*>(ioMainBuffer),
            ioFrameCount,
            ioChannelCount);
        break;

    case kAudioServerPlugInIOOperationWriteMix:
        ioHandler->OnWriteMixedOutput(stream,
            currentPeriodTimestamp_,
            ioCycleInfo->mOutputTime.mSampleTime,
            ioMainBuffer,
            ioBytesCount);
        break;

    default:
        break;
    }

    return kAudioHardwareNoError;
}

OSStatus Device::EndIOOperation(AudioObjectID objectID,
    UInt32 clientID,
    UInt32 operationID,
    UInt32 ioFrameCount,
    const AudioServerPlugInIOCycleInfo* ioCycleInfo)
{
    std::lock_guard ioLock(ioMutex_);

    if (params_.EnableRealtimeTracing) {
        GetContext()->Tracer->Message("Device::EndIOOperation()");
    }

    OSStatus status = kAudioHardwareNoError;

    if (objectID != GetID()) {
        status = kAudioHardwareBadObjectError;
        goto end;
    }

    status = EndIOOperationImpl(clientID, operationID, ioFrameCount, ioCycleInfo);

end:
    return status;
}

OSStatus Device::EndIOOperationImpl(UInt32 clientID,
    UInt32 operationID,
    UInt32 ioFrameCount,
    const AudioServerPlugInIOCycleInfo* ioCycleInfo)
{
    return kAudioHardwareNoError;
}

void Device::RequestConfigurationChange(std::function<void()> func)
{
    std::lock_guard writeLock(writeMutex_);

    auto host = GetContext()->Host.load();

    // Note: RequestConfigurationChange(), RequestOwnershipChange(), and
    // PerformConfigurationChange() calls are serialized via a mutex.
    // RequestOwnershipChange() changes HasOwner(), and PerformConfigurationChange()
    // changes insideConfigurationHandler_.
    if (host && HasOwner() && !insideConfigurationHandler_) {
        const auto reqID = lastConfigurationRequestID_++;

        GetContext()->Tracer->Message(
            "Device::RequestConfigurationChange() enqueueing change reqID=%lu",
            static_cast<unsigned long>(reqID));

        pendingConfigurationRequests_[reqID] = std::move(func);

        host->RequestDeviceConfigurationChange(host, GetID(), reqID, nullptr);
    } else {
        GetContext()->Tracer->Message(
            "Device::RequestConfigurationChange() applying change in-place");

        func();
    }
}

void Device::RequestOwnershipChange(Object* owner, bool shouldHaveOwnership)
{
    std::lock_guard writeLock(writeMutex_);

    if (shouldHaveOwnership) {
        if (HasOwner()) {
            // Device owner is always either empty or Plugin object.
            // If we already have an owner, we assume that it's
            // already set to the same object and do nothing.
            return;
        }

        GetContext()->Tracer->Message(
            "Device::RequestOwnershipChange() attaching owner devID=%lu ownerID=%lu",
            static_cast<unsigned long>(GetID()),
            static_cast<unsigned long>(owner->GetID()));

        // Device becomes visible to HAL.
        // HasOwner() now will return true.
        // RequestConfigurationChange() will enqueue changes instead of applying in-place.
        owner->AddOwnedObject(shared_from_this());
    } else {
        if (!HasOwner()) {
            // If we already don't have an owner, do nothing.
            return;
        }

        GetContext()->Tracer->Message(
            "Device::RequestOwnershipChange() detaching owner devID=%lu ownerID=%lu",
            static_cast<unsigned long>(GetID()),
            static_cast<unsigned long>(owner->GetID()));

        // Device disappears HAL.
        // HasOwner() now will return false.
        // RequestConfigurationChange() will apply changes in-place.
        owner->RemoveOwnedObject(GetID());

        if (!pendingConfigurationRequests_.empty()) {
            // If there are any enqueued changes, apply them now since it's not
            // guaranteed now that HAL will ever handle them. But HAL *will* try
            // to apply (some of) them, PerformConfigurationChange() will just
            // ignore those requests because we've removed them from map here.
            GetContext()->Tracer->Message(
                "Device::RequestOwnershipChange()"
                " applying pending configuration changes in-place"
                " devID=%lu  numChanges=%lu",
                static_cast<unsigned long>(GetID()),
                static_cast<unsigned long>(pendingConfigurationRequests_.size()));

            // Iterate ordered map from lower to higher request IDs.
            while (!pendingConfigurationRequests_.empty()) {
                auto it = pendingConfigurationRequests_.begin();

                const auto& func = it->second;
                func();

                pendingConfigurationRequests_.erase(it);
            }
        }
    }
}

OSStatus Device::PerformConfigurationChange(AudioObjectID objectID,
    UInt64 changeAction,
    void* changeInfo)
{
    std::lock_guard writeLock(writeMutex_);

    insideConfigurationHandler_++;

    const auto reqID = changeAction;

    auto func = pendingConfigurationRequests_[reqID];

    if (func) {
        GetContext()->Tracer->Message(
            "Device::PerformConfigurationChange() performing queued change reqID=%lu",
            static_cast<unsigned long>(reqID));

        func();
    } else {
        GetContext()->Tracer->Message(
            "Device::PerformConfigurationChange() ignoring null change request reqID=%lu",
            static_cast<unsigned long>(reqID));
    }

    pendingConfigurationRequests_.erase(reqID);

    insideConfigurationHandler_--;

    return kAudioHardwareNoError;
}

OSStatus Device::AbortConfigurationChange(AudioObjectID objectID,
    UInt64 changeAction,
    void* changeInfo)
{
    std::lock_guard writeLock(writeMutex_);

    const auto reqID = changeAction;

    GetContext()->Tracer->Message(
        "Device::PerformConfigurationChange() aborting change request reqID=%lu",
        static_cast<unsigned long>(reqID));

    pendingConfigurationRequests_.erase(reqID);

    return kAudioHardwareNoError;
}

} // namespace aspl
