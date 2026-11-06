// TargetBridge Audio: a CoreAudio output device whose mix is looped back to an
// input stream on the same device. The Sender reads that input and relays it
// to the receiver. Built on libASPL (MIT).

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr UInt32 kSampleRate = 48000;
constexpr UInt32 kChannelCount = 2;
constexpr int64_t kRingFrames = 1 << 15; // about 680 ms
constexpr AudioObjectPropertySelector kNameProperty = 'tbnm'; // also in the Sender
constexpr const char* kNameStorageKey = "deviceName";

AudioStreamBasicDescription MakeFormat()
{
    AudioStreamBasicDescription format = {};
    format.mSampleRate = kSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags =
        kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = kChannelCount;
    format.mBytesPerFrame = kChannelCount * sizeof(Float32);
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = format.mBytesPerFrame;
    return format;
}

class LoopbackHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler
{
public:
    LoopbackHandler()
        : ring_(static_cast<size_t>(kRingFrames * kChannelCount), 0.0f)
    {
    }

    // Sample times restart with each I/O session, so drop the previous one.
    OSStatus OnStartIO() override
    {
        std::fill(ring_.begin(), ring_.end(), 0.0f);
        writeEnd_.store(0, std::memory_order_release);
        return kAudioHardwareNoError;
    }

    // The volume and mute controls are not applied here. The Sender forwards
    // them to the receiver, so the stream itself stays at full level.
    void OnProcessClientOutput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) override
    {
    }

    void OnProcessMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) override
    {
    }

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override
    {
        const auto* source = static_cast<const Float32*>(bytes);
        const int64_t frameCount = bytesCount / (kChannelCount * sizeof(Float32));
        const int64_t start = static_cast<int64_t>(timestamp);
        const int64_t previousEnd = writeEnd_.load(std::memory_order_relaxed);

        // Silence any gap so old audio is never replayed as new.
        for (int64_t frame = std::max(previousEnd, start - kRingFrames); frame < start;
             frame++) {
            Float32* target = FrameAt(frame);
            target[0] = 0.0f;
            target[1] = 0.0f;
        }

        for (int64_t i = 0; i < frameCount; i++) {
            Float32* target = FrameAt(start + i);
            target[0] = source[i * kChannelCount];
            target[1] = source[i * kChannelCount + 1];
        }

        writeEnd_.store(std::max(previousEnd, start + frameCount), std::memory_order_release);
    }

    void OnReadClientInput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override
    {
        auto* target = static_cast<Float32*>(bytes);
        const int64_t frameCount = bytesCount / (kChannelCount * sizeof(Float32));
        const int64_t start = static_cast<int64_t>(timestamp);
        const int64_t writeEnd = writeEnd_.load(std::memory_order_acquire);
        const int64_t oldestValid = std::max<int64_t>(0, writeEnd - kRingFrames);

        for (int64_t i = 0; i < frameCount; i++) {
            const int64_t frame = start + i;
            const bool available = frame >= oldestValid && frame < writeEnd;
            const Float32* source = available ? FrameAt(frame) : nullptr;
            target[i * kChannelCount] = source ? source[0] : 0.0f;
            target[i * kChannelCount + 1] = source ? source[1] : 0.0f;
        }
    }

private:
    Float32* FrameAt(int64_t frame)
    {
        return ring_.data() + ((frame & (kRingFrames - 1)) * kChannelCount);
    }

    std::vector<Float32> ring_;
    std::atomic<int64_t> writeEnd_ { 0 };
};

// Device whose name can be changed by the Sender and survives restarts.
class NamedDevice : public aspl::Device
{
public:
    NamedDevice(std::shared_ptr<aspl::Context> context,
        const aspl::DeviceParameters& params,
        std::shared_ptr<aspl::Storage> storage)
        : aspl::Device(context, params)
        , storage_(storage)
        , name_(params.Name)
    {
        RegisterCustomProperty(
            kNameProperty, *this, &NamedDevice::CopyNameProperty, &NamedDevice::SetNameProperty);
    }

    std::string GetName() const override
    {
        std::lock_guard<std::mutex> lock(nameMutex_);
        return name_;
    }

    void LoadStoredName()
    {
        const auto [name, found] = storage_->ReadString(kNameStorageKey);
        if (found && !name.empty()) {
            ApplyName(name);
        }
    }

private:
    CFStringRef CopyNameProperty() const
    {
        return CFStringCreateWithCString(
            kCFAllocatorDefault, GetName().c_str(), kCFStringEncodingUTF8);
    }

    void SetNameProperty(CFStringRef value)
    {
        char buffer[256] = {};
        if (!CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8) ||
            buffer[0] == '\0') {
            return;
        }
        ApplyName(buffer);
        storage_->WriteString(kNameStorageKey, buffer);
    }

    void ApplyName(const std::string& name)
    {
        {
            std::lock_guard<std::mutex> lock(nameMutex_);
            name_ = name;
        }
        NotifyPropertyChanged(kAudioObjectPropertyName);
    }

    std::shared_ptr<aspl::Storage> storage_;
    mutable std::mutex nameMutex_;
    std::string name_;
};

class DriverHandler : public aspl::DriverRequestHandler
{
public:
    explicit DriverHandler(std::shared_ptr<NamedDevice> device)
        : device_(device)
    {
    }

    OSStatus OnInitialize() override
    {
        device_->LoadStoredName();
        return kAudioHardwareNoError;
    }

private:
    std::shared_ptr<NamedDevice> device_;
};

std::shared_ptr<aspl::Driver> CreateDriver()
{
    auto context = std::make_shared<aspl::Context>();
    auto storage = std::make_shared<aspl::Storage>(context);

    aspl::DeviceParameters deviceParams;
    deviceParams.Name = "TargetBridge Audio";
    deviceParams.Manufacturer = "TargetBridge";
    deviceParams.DeviceUID = "com.targetbridge.audio.device";
    deviceParams.ModelUID = "com.targetbridge.audio.model";
    deviceParams.SampleRate = kSampleRate;
    deviceParams.ChannelCount = kChannelCount;
    deviceParams.EnableMixing = true;

    auto device = std::make_shared<NamedDevice>(context, deviceParams, storage);

    aspl::StreamParameters outputParams;
    outputParams.Direction = aspl::Direction::Output;
    outputParams.Format = MakeFormat();
    device->AddStreamWithControlsAsync(outputParams);

    aspl::StreamParameters inputParams;
    inputParams.Direction = aspl::Direction::Input;
    inputParams.Format = MakeFormat();
    device->AddStreamAsync(inputParams);

    auto handler = std::make_shared<LoopbackHandler>();
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    auto driver = std::make_shared<aspl::Driver>(context, plugin, storage);
    driver->SetDriverHandler(std::make_shared<DriverHandler>(device));
    return driver;
}

} // namespace

extern "C" void* TargetBridgeAudioEntryPoint(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    static std::shared_ptr<aspl::Driver> driver = CreateDriver();
    return driver->GetReference();
}
