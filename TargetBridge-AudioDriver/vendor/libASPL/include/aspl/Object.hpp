// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/Object.hpp
//! @brief Basic audio object.

#pragma once

#include <aspl/Compat.hpp>
#include <aspl/Context.hpp>
#include <aspl/DoubleBuffer.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <type_traits>
#include <vector>

namespace aspl {

//! Base class for audio objects.
//!
//! CoreAudio uses property-based object model to communicate with plugins.
//! This class is the base class for various audio objects which implement
//! property dispatch protocol required by HAL.
//!
//! This class provides the following services:
//!
//!  - **Common context.** Each object belongs to Context, a common environment
//!    shared between objects of the same plugin / driver.
//!
//!  - **Identification.** Each object has a unique numeric identifier.
//!    ID is unique only within the same Context.
//!
//!  - **Classification.** Each object belongs to one of the predefined classes.
//!    The class defines a set of the properties and probably other
//!    operations which should be supported by object.
//!
//!  - **Ownership.** All objects of the plugin forms a tree hierarchy,
//!    with the Plugin object in the root.
//!
//!  - **Property dispatch protocol.** Every object implements a set
//!    of methods allowing to introspect, get, and set its properties.
//!
//!  - **Notification**. Object automatically notifies HAL when
//!    some of its properties is changed.
//!
//!  - **Registration of custom properties.** Object allows to register
//!    custom user-defined properties in addition to builtin properties
//!    defined by CoreAudio.
class Object : public std::enable_shared_from_this<Object>
{
public:
    //! Construct object.
    //! Class name is used for logging. It should be the name of the derived class.
    //! If objectID is @c kAudioObjectUnknown (zero), allocates new object ID.
    //! Otherwise uses given object ID.
    explicit Object(std::shared_ptr<const Context> context,
        const char* className = "Object",
        AudioObjectID objectID = kAudioObjectUnknown);

    Object(const Object&) = delete;
    Object& operator=(const Object&) = delete;

    virtual ~Object();

    //! Get object context.
    std::shared_ptr<const Context> GetContext() const;

    //! @name Class and ID
    //! @{

    //! Get class ID.
    //! Each subclass overrides this method.
    //! @note
    //!  Backs @c kAudioObjectPropertyClass property.
    virtual AudioClassID GetClass() const;

    //! Get base class ID.
    //! Each subclass overrides this method.
    //! @note
    //!  Backs @c kAudioObjectPropertyBaseClass property.
    virtual AudioClassID GetBaseClass() const;

    //! Check if this object is instance of given base class.
    //! Returns true if any of the base classes matches given class ID.
    //! Each subclass overrides this method.
    virtual bool IsInstance(AudioClassID classID) const;

    //! Get object ID.
    //! Returns objectID selected at construction time.
    AudioObjectID GetID() const;

    //! @}

    //! @name Ownership
    //! @{

    //! Get object owner.
    //! If the object has an owner, returns its ID.
    //! Otherwise, returns @c kAudioObjectUnknown (zero).
    //! @note
    //!  Backs @c kAudioObjectPropertyOwner property.
    AudioObjectID GetOwnerID() const;

    //! Check if the object is part of the hierarchy.
    //! Returns true if GetOwnerID() is not equal to kAudioObjectUnknown.
    //! @remarks
    //!  By default, object does not have an owner. Until the object is
    //!  attached to an owner, it is not part of the plugin object
    //!  hierarchy and is not visible to HAL.
    bool HasOwner() const;

    //! Get owned objects.
    //! Returns the list of objects to which this object is the owner.
    //! @remarks
    //!  Filters the returned list by scope and class.
    //!  Global scope or zero class will match any object.
    //!  Class, if non-zero, is matched using IsInstance() method, so
    //!  parent classes will match derived classes too.
    //! @note
    //!  Backs @c kAudioObjectPropertyOwnedObjects property.
    std::vector<AudioObjectID> GetOwnedObjectIDs(
        AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
        AudioClassID classID = 0) const;

    //! Add object to the list of owned objects.
    //! Also invokes SetOwner() on the added object.
    void AddOwnedObject(std::shared_ptr<Object> object,
        AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal);

    //! Remove object to the list of owned objects.
    //! Also invokes SetOwner() on the removed object.
    void RemoveOwnedObject(AudioObjectID objectID);

    //! @}

    //! @name Notification
    //! @{

    //! Notify HAL that a property was changed.
    //! This is automatically called by all setters.
    void NotifyPropertyChanged(AudioObjectPropertySelector selector,
        AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
        AudioObjectPropertyElement element = kAudioObjectPropertyElementMain) const
    {
        NotifyPropertiesChanged({selector}, scope, element);
    }

    //! Notify HAL that some properties were changed.
    //! This is automatically called by all setters.
    void NotifyPropertiesChanged(std::vector<AudioObjectPropertySelector> selectors,
        AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
        AudioObjectPropertyElement element = kAudioObjectPropertyElementMain) const;

    //! @}

    //! @name Custom properties
    //! @{

    //! Get info about registered custom properties.
    //! Returns list of properties added using RegisterCustomProperty().
    //! @note
    //!  Backs @c kAudioObjectPropertyCustomPropertyInfoList property.
    virtual std::vector<AudioServerPlugInCustomPropertyInfo> GetCustomProperties() const;

    //! Pointer to custom property getter method.
    //! Used in RegisterCustomProperty().
    template <typename ObjectType, typename ValueType>
    using GetterMethod = ValueType (ObjectType::*)() const;

    //! Pointer to custom property setter method.
    //! Used in RegisterCustomProperty().
    template <typename ObjectType, typename ValueType>
    using SetterMethod = void (ObjectType::*)(ValueType);

    //! Register custom property with getter and optional setter.
    //!
    //! This overload allows to use methods as getter and setter:
    //! @code
    //! class MyObject : public aspl::Object
    //! {
    //! public:
    //!   CFStringRef GetMyProperty() const { ... }
    //!   void SetMyProperty(CFStringRef value) { ... }
    //!
    //!   MyObject(...)
    //!     : Object(...)
    //!   {
    //!     RegisterCustomProperty(
    //!       MyPropertySelector, *this, &MyObject::GetMyProperty,
    //!         &MyObject::SetMyProperty);
    //!   }
    //! };
    //! @endcode
    //!
    //! Value type should be either CFStringRef or CFPropertyListRef because
    //! they are the only types allowed by CoreAudio.
    //!
    //! Getter transfers ownership to the caller; the caller will call CFRelease().
    //! Setter does not transfer ownership; the setter should call CFRetain() if
    //! it wants to store the value.
    template <typename ObjectType, typename ValueType>
    void RegisterCustomProperty(AudioObjectPropertySelector selector,
        ObjectType& object,
        GetterMethod<ObjectType, ValueType> getter,
        SetterMethod<ObjectType, ValueType> setter = nullptr)
    {
        static_assert(std::is_same<ValueType, CFStringRef>::value ||
                          std::is_same<ValueType, CFPropertyListRef>::value,
            "ValueType should be CFStringRef or CFPropertyListRef");

        RegisterCustomProperty(selector,
            std::bind(getter, &object),
            setter ? std::bind(setter, &object, std::placeholders::_1)
                   : std::function<void(ValueType)>{});
    }

    //! Register custom property with getter and optional setter.
    //!
    //! This overload is for read-only properties (without setter).
    //!
    //! GetterFunc should be convertible to std::function<ValueType()>, where
    //! value type should be either CFStringRef or CFPropertyListRef (because
    //! they are the only types allowed by CoreAudio).
    //!
    //! Getter transfers ownership to the caller; the caller will call CFRelease().
    template <typename GetterFunc>
    void RegisterCustomProperty(AudioObjectPropertySelector selector, GetterFunc getter)
    {
        using ValueType = decltype(getter());

        static_assert(std::is_same<ValueType, CFStringRef>::value ||
                          std::is_same<ValueType, CFPropertyListRef>::value,
            "GetterFunc() should return CFStringRef or CFPropertyListRef");

        RegisterCustomProperty(selector,
            std::function<ValueType()>(getter),
            std::function<void(ValueType)>{});
    }

    //! Register custom property with getter and optional setter.
    //!
    //! This overload is for properties of type CFStringRef.
    //!
    //! Setter may be null function if the property is read-only.
    //!
    //! Getter transfers ownership to the caller; the caller will call CFRelease().
    //! Setter does not transfer ownership; the setter should call CFRetain() if
    //! it wants to store the value.
    void RegisterCustomProperty(AudioObjectPropertySelector selector,
        std::function<CFStringRef()> getter,
        std::function<void(CFStringRef)> setter);

    //! Register custom property with getter and optional setter.
    //!
    //! This overload is for properties of type CFPropertyListRef.
    //!
    //! Setter may be null function if the property is read-only.
    //!
    //! Getter transfers ownership to the caller; the caller will call CFRelease().
    //! Setter does not transfer ownership; the setter should call CFRetain() if
    //! it wants to store the value.
    void RegisterCustomProperty(AudioObjectPropertySelector selector,
        std::function<CFPropertyListRef()> getter,
        std::function<void(CFPropertyListRef)> setter);

    //! @}

    //! @name Property dispatch
    //! @{

    //! Check whether given property is present.
    //! @note
    //!  Invoked by HAL on non-realtime thread.
    virtual Boolean HasProperty(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address) const;

    //! Check whether given property can be changed.
    //! @note
    //!  Invoked by HAL on non-realtime thread.
    virtual OSStatus IsPropertySettable(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        Boolean* outIsSettable) const;

    //! Get size of property value in bytes.
    //! @note
    //!  Invoked by HAL on non-realtime thread.
    virtual OSStatus GetPropertyDataSize(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32* outDataSize) const;

    //! Get property value.
    //! @note
    //!  Invoked by HAL on non-realtime thread.
    virtual OSStatus GetPropertyData(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32 inDataSize,
        UInt32* outDataSize,
        void* outData) const;

    //! Change property value.
    //! @note
    //!  Invoked by HAL on non-realtime thread.
    virtual OSStatus SetPropertyData(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32 inDataSize,
        const void* inData);

    //! @}

private:
    struct CustomProperty;

    void AttachOwner(Object& owner);
    void DetachOwner();

    Boolean HasPropertyFallback(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address) const;

    OSStatus IsPropertySettableFallback(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        Boolean* outIsSettable) const;

    OSStatus GetPropertyDataSizeFallback(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32* outDataSize) const;

    OSStatus GetPropertyDataFallback(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32 inDataSize,
        UInt32* outDataSize,
        void* outData) const;

    OSStatus SetPropertyDataFallback(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32 inDataSize,
        const void* inData);

    mutable std::mutex writeMutex_;

    const std::shared_ptr<const Context> context_;

    const char* const className_;

    const AudioObjectID objectID_;

    Object* ownerObject_ = nullptr;
    std::atomic<AudioObjectID> ownerObjectID_ = kAudioObjectUnknown;

    DoubleBuffer<std::map<AudioObjectPropertyScope,
        std::map<AudioObjectID, std::shared_ptr<Object>>>>
        ownedObjects_;

    DoubleBuffer<std::map<AudioObjectPropertySelector, std::shared_ptr<CustomProperty>>>
        customProps_;
};

} // namespace aspl
