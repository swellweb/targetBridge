// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/Driver.hpp>

#include "Bridge.hpp"
#include "Variant.hpp"

#include <cstddef>

namespace aspl {

Driver::Driver(std::shared_ptr<Context> context,
    std::shared_ptr<Plugin> plugin,
    std::shared_ptr<Storage> storage)
    : context_(context ? std::move(context) : std::make_shared<Context>())
    , plugin_(plugin ? std::move(plugin) : std::make_shared<Plugin>(context_))
    , storage_(storage ? std::move(storage) : std::make_shared<Storage>(context_))
{
    GetContext()->Tracer->Message("Driver::Driver()");

    driverInterfacePointer_ = &driverInterface_;
    driverInterface_ = {
        // Reserved
        nullptr,

        // Service methods, handled by driver itself
        Driver::QueryInterface,
        Driver::AddRef,
        Driver::Release,
        Driver::InitializeJumper,
        Driver::CreateDeviceJumper,
        Driver::DestroyDeviceJumper,

        // Methods redirected to objects found in Context::Dispatcher
        Bridge::AddClient,
        Bridge::RemoveClient,
        Bridge::PerformConfigurationChange,
        Bridge::AbortConfigurationChange,
        Bridge::HasProperty,
        Bridge::IsPropertySettable,
        Bridge::GetPropertyDataSize,
        Bridge::GetPropertyData,
        Bridge::SetPropertyData,
        Bridge::StartIO,
        Bridge::StopIO,
        Bridge::GetZeroTimeStamp,
        Bridge::WillDoIOOperation,
        Bridge::BeginIOOperation,
        Bridge::DoIOOperation,
        Bridge::EndIOOperation,
    };
}

Driver::~Driver()
{
    GetContext()->Tracer->Message("Driver::~Driver()");
}

std::shared_ptr<const Context> Driver::GetContext() const
{
    return plugin_->GetContext();
}

std::shared_ptr<Plugin> Driver::GetPlugin() const
{
    return plugin_;
}

std::shared_ptr<Storage> Driver::GetStorage() const
{
    return storage_;
}

const AudioServerPlugInDriverInterface& Driver::GetPluginInterface() const
{
    return driverInterface_;
}

AudioServerPlugInDriverRef Driver::GetReference()
{
    return &driverInterfacePointer_;
}

Driver* Driver::GetDriver(AudioServerPlugInDriverRef driverRef)
{
    AudioServerPlugInDriverInterface* driverInterface = *driverRef;

    return reinterpret_cast<Driver*>(
        reinterpret_cast<UInt8*>(driverInterface) - offsetof(Driver, driverInterface_));
}

void Driver::SetDriverHandler(std::shared_ptr<DriverRequestHandler> handler)
{
    driverHandler_.Set(handler);
}

void Driver::SetDriverHandler(DriverRequestHandler* handler)
{
    driverHandler_.Set(handler);
}

OSStatus Driver::Initialize()
{
    const auto handlerVariant = driverHandler_.Get();
    const auto handler = GetVariantPtr(handlerVariant);

    if (handler) {
        return handler->OnInitialize();
    }

    return kAudioHardwareNoError;
}

OSStatus Driver::CreateDevice(CFDictionaryRef description,
    const AudioServerPlugInClientInfo* clientInfo,
    AudioObjectID* outDeviceObjectID)
{
    return kAudioHardwareUnsupportedOperationError;
}

OSStatus Driver::DestroyDevice(AudioObjectID objectID)
{
    return kAudioHardwareUnsupportedOperationError;
}

HRESULT Driver::QueryInterface(void* driverRef, REFIID iid, LPVOID* outInterface)
{
    const auto driver =
        Driver::GetDriver(reinterpret_cast<AudioServerPlugInDriverRef>(driverRef));

    CFUUIDRef interfaceID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, iid);

    const bool isSupportedInterface =
        CFEqual(interfaceID, IUnknownUUID) ||
        CFEqual(interfaceID, kAudioServerPlugInDriverInterfaceUUID);

    CFRelease(interfaceID);

    if (!isSupportedInterface) {
        driver->GetContext()->Tracer->Message("Driver::QueryInterface() E_NOINTERFACE");
        return E_NOINTERFACE;
    }

    *outInterface = driver->GetReference();

    const auto counter = ++driver->refCounter_;

    driver->GetContext()->Tracer->Message("Driver::QueryInterface() S_OK refCounter=%lu",
        static_cast<unsigned long>(counter));

    return S_OK;
}

ULONG Driver::AddRef(void* driverRef)
{
    const auto driver =
        Driver::GetDriver(reinterpret_cast<AudioServerPlugInDriverRef>(driverRef));

    const auto counter = ++driver->refCounter_;

    driver->GetContext()->Tracer->Message(
        "Driver::AddRef() refCounter=%lu", static_cast<unsigned long>(counter));

    return counter;
}

ULONG Driver::Release(void* driverRef)
{
    const auto driver =
        Driver::GetDriver(reinterpret_cast<AudioServerPlugInDriverRef>(driverRef));

    const auto counter = --driver->refCounter_;

    driver->GetContext()->Tracer->Message(
        "Driver::Release() refCounter=%lu", static_cast<unsigned long>(counter));

    return counter;
}

OSStatus Driver::InitializeJumper(AudioServerPlugInDriverRef driverRef,
    AudioServerPlugInHostRef hostRef)
{
    const auto driver = Driver::GetDriver(driverRef);

    driver->GetContext()->Tracer->Message("Driver::Initialize()");

    driver->context_->Host = hostRef;

    return driver->Initialize();
}

OSStatus Driver::CreateDeviceJumper(AudioServerPlugInDriverRef driverRef,
    CFDictionaryRef description,
    const AudioServerPlugInClientInfo* clientInfo,
    AudioObjectID* outDeviceObjectID)
{
    const auto driver = Driver::GetDriver(driverRef);

    driver->GetContext()->Tracer->Message("Driver::CreateDevice()");

    return driver->CreateDevice(description, clientInfo, outDeviceObjectID);
}

OSStatus Driver::DestroyDeviceJumper(AudioServerPlugInDriverRef driverRef,
    AudioObjectID objectID)
{
    const auto driver = Driver::GetDriver(driverRef);

    driver->GetContext()->Tracer->Message("Driver::DestroyDevice()");

    return driver->DestroyDevice(objectID);
}

} // namespace aspl
