// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/Plugin.hpp
//! @brief Plugin object.

#pragma once

#include <aspl/Device.hpp>
#include <aspl/DoubleBuffer.hpp>
#include <aspl/Object.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace aspl {

//! Audio plugin parameters.
struct PluginParameters
{
    //! Human readable name of the maker of the plug-in.
    //! Used by default implementation of Plugin::GetManufacturer().
    std::string Manufacturer = "libASPL";

    //! Resource bundle path.
    //! Used by default implementation of Plugin::GetResourceBundlePath().
    //! Empty string means use plug-in bundle itself.
    std::string ResourceBundlePath = "";
};

//! Plugin object.
//!
//! Plugin is the root of the Object tree. All other objects are owned by it,
//! either directly or indirectly.
//!
//! Plugin, unlike other objects, has the constant well-known identifier
//! (@c kAudioObjectPlugInObject). HAL uses it to recursively discover all
//! other objects in the hierarchy.
//!
//! Typically, plugin owns one or more devices, and each device owns one or
//! more streams and zero or multiple controls. Plugin itself is owned by
//! Driver, but the latter is not an Object, but rather something like an
//! entry point to the object tree.
class Plugin : public Object
{
public:
    //! Construct plugin.
    explicit Plugin(std::shared_ptr<const Context> context,
        const PluginParameters& params = {});

    //! @name Getters and setters
    //! @{

    //! Get plugin manufacturer.
    //! Human readable name of the maker of the plug-in.
    //! Can be localized.
    //! By default returns PluginParameters::Manufacturer.
    //! @note
    //!  Backs @c kAudioObjectPropertyManufacturer property.
    virtual std::string GetManufacturer() const;

    //! Get resource bundle path.
    //! By default returns PluginParameters::ResourceBundlePath.
    //! @remarks
    //!  Relative to the path of the plug-in bundle.
    //!  Empty string means use plug-in bundle itself.
    //! @note
    //!  Backs @c kAudioPlugInPropertyResourceBundle property.
    virtual std::string GetResourceBundlePath() const;

    //! Get devices.
    //! Returns the list of owned devices.
    //! Default implementation returns all owned objects of kAudioDeviceClassID class.
    //! @note
    //!  Backs @c kAudioPlugInPropertyDeviceList property.
    virtual std::vector<AudioObjectID> GetDeviceIDs() const;

    //! Get device with given UID.
    //! Returns nullptr if there is no such device.
    //! @note
    //!  Backs @c kAudioPlugInPropertyTranslateUIDToDevice property.
    virtual AudioObjectID GetDeviceIDByUID(const std::string& uid) const;

    //! @}

    //! @name Devices
    //! @{

    //! Get number of devices added.
    UInt32 GetDeviceCount() const;

    //! Get device with given zero-based index.
    //! Returns nullptr if there are less than idx+1 devices.
    std::shared_ptr<Device> GetDeviceByIndex(UInt32 idx) const;

    //! Get device with given object ID.
    //! Returns nullptr if there is no such device.
    std::shared_ptr<Device> GetDeviceByID(AudioObjectID deviceID) const;

    //! Check if device is already added.
    bool HasDevice(std::shared_ptr<Device> device) const;

    //! Add device to the plugin.
    //! Adds device to the owned object list.
    void AddDevice(std::shared_ptr<Device> device);

    //! Remove device from the plugin.
    //! Removes device from the owned object list.
    void RemoveDevice(std::shared_ptr<Device> device);

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

private:
    mutable std::recursive_mutex writeMutex_;

    const PluginParameters params_;

    DoubleBuffer<std::vector<std::shared_ptr<Device>>> devices_;
    DoubleBuffer<std::unordered_map<AudioObjectID, std::shared_ptr<Device>>> deviceByID_;
    DoubleBuffer<std::unordered_map<std::string, std::shared_ptr<Device>>> deviceByUID_;
};

} // namespace aspl
