// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/Driver.hpp
//! @brief Plugin driver.

#pragma once

#include <aspl/Context.hpp>
#include <aspl/DoubleBuffer.hpp>
#include <aspl/DriverRequestHandler.hpp>
#include <aspl/Plugin.hpp>
#include <aspl/Storage.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <atomic>
#include <memory>
#include <variant>

namespace aspl {

//! Plugin driver.
//!
//! Driver is the top-level object of AudioServer plugin. It contains Plugin
//! object, which is the root of the whole object hierarchy. The driver's job
//! is to receive requests from HAL and redirect them to appropriate objects.
//!
//! Driver is exposed to HAL as "driver reference" (@c AudioServerPlugInDriverRef).
//! The driver reference is actually a pointer to pointer to "plugin driver interface"
//! (@c AudioServerPlugInDriverInterface), which is a struct with a bunch of function
//! pointers for various operations (mostly for property dispatch and I/O).
//!
//! Driver fills this struct with its private functions. Each of them just finds
//! the registered object by ID and redirects operation to it. Objects are searched
//! in Context::Dispatcher. Every object requires Context as constructor argument
//! and automatically registers and unregisters itself in Dispatcher.
//!
//! Driver also provides Storage object, which provides API for persistent storage
//! associated with plugin, and managed by CoreAudio daemon.
//!
//! By default driver creates its own Context, Plugin, and Storage objects, but you
//! can provide your own if desired.
//!
//! After constructing driver, you need to use GetReference() method to obtain
//! the "driver reference" and return it from the plugin entry point, like:
//!
//! @code
//!   extern "C" void* MyEntryPoint(CFAllocatorRef, CFUUIDRef typeUUID)
//!   {
//!     if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
//!       return nullptr;
//!     }
//!     static auto driver = std::make_shared<aspl::Driver>();
//!     return driver->GetReference();
//!   }
//! @endcode
//!
//! Don't forget do declare your entry point in Info.plist of the plugin.
//!
//! Right after the Driver object is created, it is not fully initialized yet. The
//! final initialization is performed by HAL asynchronously, after returning from
//! plugin entry point.
//!
//! Until asynchronous initialization is done, most driver services are not really
//! functioning yet: devices don't appear in system, persistent storage returns
//! errors for all requests, etc.
//!
//! The user can be notified when the initialization is done by providing custom
//! DriverRequestHandler, or by inheriting Driver and overriding appropriate method.
class Driver
{
public:
    //! Construct driver.
    //! If context, plugin, or storage is not set, it is created automatically.
    explicit Driver(std::shared_ptr<Context> context = {},
        std::shared_ptr<Plugin> plugin = {},
        std::shared_ptr<Storage> storage = {});

    Driver(const Driver&) = delete;
    Driver& operator=(const Driver&) = delete;

    virtual ~Driver();

    //! Get context.
    //! Context contains data shared among all driver objects.
    std::shared_ptr<const Context> GetContext() const;

    //! Get plugin.
    //! Plugin is the root of driver's object tree.
    std::shared_ptr<Plugin> GetPlugin() const;

    //! Get storage.
    //! Storage provides API for persistent key-value database.
    std::shared_ptr<Storage> GetStorage() const;

    //! Get plugin interface.
    //! Plugin interface is a table with function pointers which implement
    //! various plugin operations.
    const AudioServerPlugInDriverInterface& GetPluginInterface() const;

    //! Get driver reference.
    //! This is what should be returned from plugin entry point.
    AudioServerPlugInDriverRef GetReference();

    //! Cast driver reference back to driver.
    static Driver* GetDriver(AudioServerPlugInDriverRef driverRef);

    //! Set handler for HAL requests to driver.
    //! Optional. Use when you need to do custom handling.
    void SetDriverHandler(std::shared_ptr<DriverRequestHandler> handler);

    //! Set handler for HAL requests to driver (raw pointer overload).
    //! This overload uses raw pointer instead of shared_ptr, and the user
    //! is responsible for keeping handler object alive until it's reset
    //! or Driver is destroyed.
    void SetDriverHandler(DriverRequestHandler* handler);

protected:
    //! Initialize driver.
    //! Default implementation invokes DriverRequestHandler::OnInitialize().
    virtual OSStatus Initialize();

    //! Create device.
    //! Default implementation returns kAudioHardwareUnsupportedOperationError.
    virtual OSStatus CreateDevice(CFDictionaryRef description,
        const AudioServerPlugInClientInfo* clientInfo,
        AudioObjectID* outDeviceObjectID);

    //! Destroy device.
    //! Default implementation returns kAudioHardwareUnsupportedOperationError.
    virtual OSStatus DestroyDevice(AudioObjectID objectID);

private:
    // COM methods
    static HRESULT QueryInterface(void* driverRef, REFIID iid, LPVOID* outInterface);

    static ULONG AddRef(void* driverRef);
    static ULONG Release(void* driverRef);

    // Driver methods
    static OSStatus InitializeJumper(AudioServerPlugInDriverRef driverRef,
        AudioServerPlugInHostRef hostRef);

    static OSStatus CreateDeviceJumper(AudioServerPlugInDriverRef driverRef,
        CFDictionaryRef description,
        const AudioServerPlugInClientInfo* clientInfo,
        AudioObjectID* outDeviceObjectID);

    static OSStatus DestroyDeviceJumper(AudioServerPlugInDriverRef driverRef,
        AudioObjectID objectID);

    const std::shared_ptr<Context> context_;
    const std::shared_ptr<Plugin> plugin_;
    const std::shared_ptr<Storage> storage_;

    // User-provided handler
    DoubleBuffer<
        std::variant<std::shared_ptr<DriverRequestHandler>, DriverRequestHandler*>>
        driverHandler_;

    // Method table
    AudioServerPlugInDriverInterface driverInterface_;
    AudioServerPlugInDriverInterface* driverInterfacePointer_;

    // Reference counter
    std::atomic<ULONG> refCounter_ = 0;
};

} // namespace aspl
