// TargetBridge Audio: a CoreAudio output device whose mix is looped back to an
// input stream on the same device. The Sender reads that input and relays it
// to the receiver. Built on libASPL (MIT).

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>

#include <algorithm>
#include <atomic>
#include <functional>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr UInt32 kSampleRate = 48000;
constexpr UInt32 kChannelCount = 2;
constexpr int64_t kRingFrames = 1 << 15; // about 680 ms
// Both live on the plugin object, which exists even while the device is hidden.
constexpr AudioObjectPropertySelector kNameProperty = 'tbnm'; // also in the Sender
constexpr AudioObjectPropertySelector kVisibilityProperty = 'tbsh'; // also in the Sender
// A Sender that asked to show the device but never started I/O has gone away.
constexpr int64_t kShowWithoutClientTimeoutNs = 15 * NSEC_PER_SEC;
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
    std::function<void(pid_t)> onClientAdded;
    std::function<void(pid_t)> onClientRemoved;

    std::shared_ptr<aspl::Client> OnAddClient(const aspl::ClientInfo& clientInfo) override
    {
        if (onClientAdded) onClientAdded(clientInfo.ProcessID);
        return std::make_shared<aspl::Client>(clientInfo);
    }

    void OnRemoveClient(std::shared_ptr<aspl::Client> client) override
    {
        if (onClientRemoved) onClientRemoved(client->GetProcessID());
    }

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

    void Rename(const std::string& name)
    {
        ApplyName(name);
        storage_->WriteString(kNameStorageKey, name);
    }

private:
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

// Adds the device while a Sender session uses it and removes it afterwards,
// including when that Sender quits or crashes.
class DeviceVisibility : public std::enable_shared_from_this<DeviceVisibility>
{
public:
    DeviceVisibility(std::shared_ptr<aspl::Plugin> plugin, std::shared_ptr<NamedDevice> device)
        : plugin_(plugin)
        , device_(device)
    {
    }

    bool IsVisible() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return visible_;
    }

    void Show(pid_t owner)
    {
        uint64_t generation = 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            owner_ = owner;
            ownerSeen_ = false;
            generation = ++generation_;
            if (!visible_) {
                plugin_->AddDevice(device_);
                visible_ = true;
            }
        }

        std::weak_ptr<DeviceVisibility> weak = shared_from_this();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kShowWithoutClientTimeoutNs),
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                if (auto self = weak.lock()) self->HideIfOwnerNeverArrived(generation);
            });
    }

    void Hide()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        HideLocked();
    }

    void ClientAdded(pid_t pid)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (pid == owner_) ownerSeen_ = true;
    }

    void ClientRemoved(pid_t pid)
    {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (pid != owner_ || !visible_) return;
        }
        // Not from inside the device's own client callback.
        std::weak_ptr<DeviceVisibility> weak = shared_from_this();
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (auto self = weak.lock()) self->HideIfOwner(pid);
        });
    }

private:
    void HideIfOwner(pid_t pid)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (pid == owner_) HideLocked();
    }

    void HideIfOwnerNeverArrived(uint64_t generation)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (generation == generation_ && !ownerSeen_) HideLocked();
    }

    void HideLocked()
    {
        owner_ = 0;
        ownerSeen_ = false;
        if (!visible_) return;
        plugin_->RemoveDevice(device_);
        visible_ = false;
    }

    std::shared_ptr<aspl::Plugin> plugin_;
    std::shared_ptr<NamedDevice> device_;
    mutable std::mutex mutex_;
    bool visible_ = false;
    pid_t owner_ = 0;
    bool ownerSeen_ = false;
    uint64_t generation_ = 0;
};

// The Sender renames the device and shows or hides it through these properties.
class ControlPlugin : public aspl::Plugin
{
public:
    explicit ControlPlugin(std::shared_ptr<aspl::Context> context)
        : aspl::Plugin(context)
    {
        RegisterCustomProperty(
            kNameProperty, *this, &ControlPlugin::CopyName, &ControlPlugin::SetName);
        RegisterCustomProperty(
            kVisibilityProperty, *this, &ControlPlugin::CopyVisibility, &ControlPlugin::SetVisibility);
    }

    void Attach(std::shared_ptr<NamedDevice> device, std::shared_ptr<DeviceVisibility> visibility)
    {
        device_ = device;
        visibility_ = visibility;
    }

private:
    CFStringRef CopyName() const
    {
        const std::string name = device_ ? device_->GetName() : "";
        return CFStringCreateWithCString(kCFAllocatorDefault, name.c_str(), kCFStringEncodingUTF8);
    }

    void SetName(CFStringRef value)
    {
        const std::string name = ToString(value);
        if (device_ && !name.empty()) device_->Rename(name);
    }

    CFStringRef CopyVisibility() const
    {
        const bool visible = visibility_ && visibility_->IsVisible();
        return CFStringCreateWithCString(
            kCFAllocatorDefault, visible ? "visible" : "hidden", kCFStringEncodingUTF8);
    }

    // "show:<pid of the Sender>" or "hide".
    void SetVisibility(CFStringRef value)
    {
        if (!visibility_) return;
        const std::string command = ToString(value);
        if (command.rfind("show:", 0) == 0) {
            const long pid = std::strtol(command.c_str() + 5, nullptr, 10);
            if (pid > 0) visibility_->Show(static_cast<pid_t>(pid));
        } else if (command == "hide") {
            visibility_->Hide();
        }
    }

    static std::string ToString(CFStringRef value)
    {
        char buffer[256] = {};
        if (!value || !CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
            return "";
        }
        return buffer;
    }

    std::shared_ptr<NamedDevice> device_;
    std::shared_ptr<DeviceVisibility> visibility_;
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

    // The device starts hidden. A Sender session adds it through the plugin.
    auto plugin = std::make_shared<ControlPlugin>(context);
    auto visibility = std::make_shared<DeviceVisibility>(plugin, device);
    plugin->Attach(device, visibility);
    std::weak_ptr<DeviceVisibility> weakVisibility = visibility;
    handler->onClientAdded = [weakVisibility](pid_t pid) {
        if (auto v = weakVisibility.lock()) v->ClientAdded(pid);
    };
    handler->onClientRemoved = [weakVisibility](pid_t pid) {
        if (auto v = weakVisibility.lock()) v->ClientRemoved(pid);
    };

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
