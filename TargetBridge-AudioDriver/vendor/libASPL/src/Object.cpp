// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/Object.hpp>

#include "Strings.hpp"

#include <algorithm>

namespace aspl {

struct Object::CustomProperty
{
    UInt32 type = 0;
    UInt32 size = 0;

    std::function<void(void*)> getter = {};
    std::function<void(const void*)> setter = {};

    template <class ValueType>
    static std::shared_ptr<CustomProperty> Create(UInt32 type,
        std::function<ValueType()> getter,
        std::function<void(ValueType)> setter)
    {
        auto prop = std::make_shared<CustomProperty>();

        prop->type = type;
        prop->size = sizeof(ValueType);

        if (getter) {
            prop->getter = [getter](void* output) {
                *static_cast<ValueType*>(output) = getter();
            };
        }

        if (setter) {
            prop->setter = [setter](const void* input) {
                setter(*static_cast<const ValueType*>(input));
            };
        }

        return prop;
    }
};

Object::Object(std::shared_ptr<const Context> context,
    const char* className,
    AudioObjectID objectID)
    : context_(std::move(context))
    , className_(className)
    , objectID_(context_->Dispatcher->RegisterObject(*this, objectID))
{
    GetContext()->Tracer->Message(
        "%s::%s() objectID=%u", className_, className_, unsigned(GetID()));
}

Object::~Object()
{
    GetContext()->Tracer->Message(
        "%s::~%s() objectID=%u", className_, className_, unsigned(GetID()));

    GetContext()->Dispatcher->UnregisterObject(objectID_);
}

std::shared_ptr<const Context> Object::GetContext() const
{
    return context_;
}

AudioObjectID Object::GetID() const
{
    return objectID_;
}

AudioObjectID Object::GetOwnerID() const
{
    return ownerObjectID_;
}

bool Object::HasOwner() const
{
    return ownerObjectID_ != kAudioObjectUnknown;
}

std::vector<AudioObjectID> Object::GetOwnedObjectIDs(AudioObjectPropertyScope scope,
    AudioClassID classID) const
{
    auto readLock = ownedObjects_.GetReadLock();

    std::vector<AudioObjectID> objectIDList;

    for (const auto& [objectScope, objectMap] : readLock.GetReference()) {
        if (scope != kAudioObjectPropertyScopeGlobal && scope != objectScope) {
            continue;
        }
        for (const auto& [objectID, object] : objectMap) {
            if (classID != 0 && !object->IsInstance(classID)) {
                continue;
            }
            objectIDList.push_back(objectID);
        }
    }

    return objectIDList;
}

void Object::AddOwnedObject(std::shared_ptr<Object> object,
    AudioObjectPropertyScope scope)
{
    std::lock_guard writeLock(writeMutex_);

    if (!object) {
        GetContext()->Tracer->Message(
            "Object::AddOwnedObject()"
            " owner:(objectID=%u classID=%s) not adding null object",
            unsigned(GetID()),
            ClassIDToString(GetClass()).c_str());

        return;
    }

    if (object.get() == this) {
        GetContext()->Tracer->Message(
            "Object::AddOwnedObject()"
            " owner:(objectID=%u classID=%s) not adding self",
            unsigned(GetID()),
            ClassIDToString(GetClass()).c_str());

        return;
    }

    auto ownedObjects = ownedObjects_.Get();

    ownedObjects[scope][object->GetID()] = object;
    ownedObjects_.Set(std::move(ownedObjects));

    object->AttachOwner(*this);

    GetContext()->Tracer->Message(
        "Object::AddOwnedObject()"
        " owner:(objectID=%u classID=%s) owned:(objectID=%u classID=%s)",
        unsigned(GetID()),
        ClassIDToString(GetClass()).c_str(),
        unsigned(object->GetID()),
        ClassIDToString(object->GetClass()).c_str());
}

void Object::RemoveOwnedObject(AudioObjectID objectID)
{
    std::lock_guard writeLock(writeMutex_);

    auto ownedObjects = ownedObjects_.Get();

    for (auto& [_, objectMap] : ownedObjects) {
        auto iter = objectMap.find(objectID);
        if (iter == objectMap.end()) {
            continue;
        }

        auto object = iter->second;

        GetContext()->Tracer->Message(
            "Object::RemoveOwnedObject()"
            " owner:(objectID=%u classID=%s) owned:(objectID=%u classID=%s)",
            unsigned(GetID()),
            ClassIDToString(GetClass()).c_str(),
            unsigned(object->GetID()),
            ClassIDToString(object->GetClass()).c_str());

        object->DetachOwner();
        objectMap.erase(iter);

        ownedObjects_.Set(std::move(ownedObjects));

        return;
    }

    GetContext()->Tracer->Message(
        "Object::RemoveOwnedObject()"
        " owner:(objectID=%u classID=%s)"
        " not removing objectID=%u because it's not owned",
        unsigned(GetID()),
        ClassIDToString(GetClass()).c_str(),
        unsigned(objectID));
}

void Object::AttachOwner(Object& owner)
{
    std::lock_guard writeLock(writeMutex_);

    if (ownerObject_) {
        GetContext()->Tracer->Message(
            "detaching previous owner before attaching a new one");
        ownerObject_->RemoveOwnedObject(GetID());
    }

    ownerObject_ = &owner;
    ownerObjectID_ = owner.GetID();
}

void Object::DetachOwner()
{
    std::lock_guard writeLock(writeMutex_);

    ownerObjectID_ = kAudioObjectUnknown;
    ownerObject_ = nullptr;
}

void Object::NotifyPropertiesChanged(std::vector<AudioObjectPropertySelector> selectors,
    AudioObjectPropertyScope scope,
    AudioObjectPropertyElement element) const
{
    if (selectors.empty()) {
        return;
    }

    auto host = GetContext()->Host.load();
    if (!host) {
        return;
    }

    std::vector<AudioObjectPropertyAddress> props;
    std::string propNames;

    for (auto selector : selectors) {
        AudioObjectPropertyAddress prop;
        prop.mSelector = selector;
        prop.mScope = scope;
        prop.mElement = element;

        props.push_back(prop);

        if (!propNames.empty()) {
            propNames += ", ";
        }
        propNames += PropertySelectorToString(selector);
    }

    GetContext()->Tracer->Message(
        "Object::NotifyPropertiesChanged() sending notification for %s",
        propNames.c_str());

    host->PropertiesChanged(host, GetID(), UInt32(props.size()), props.data());
}

std::vector<AudioServerPlugInCustomPropertyInfo> Object::GetCustomProperties() const
{
    auto readLock = customProps_.GetReadLock();

    std::vector<AudioServerPlugInCustomPropertyInfo> infoList;

    for (const auto& [propSelector, prop] : readLock.GetReference()) {
        AudioServerPlugInCustomPropertyInfo info = {};

        info.mSelector = propSelector;
        info.mPropertyDataType = prop->type;
        info.mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;

        infoList.push_back(info);
    }

    return infoList;
}

void Object::RegisterCustomProperty(AudioObjectPropertySelector selector,
    std::function<CFStringRef()> getter,
    std::function<void(CFStringRef)> setter)
{
    std::lock_guard writeLock(writeMutex_);

    auto customProps = customProps_.Get();

    customProps[selector] = CustomProperty::Create<CFStringRef>(
        kAudioServerPlugInCustomPropertyDataTypeCFString, getter, setter);

    customProps_.Set(std::move(customProps));
}

void Object::RegisterCustomProperty(AudioObjectPropertySelector selector,
    std::function<CFPropertyListRef()> getter,
    std::function<void(CFPropertyListRef)> setter)
{
    std::lock_guard writeLock(writeMutex_);

    auto customProps = customProps_.Get();

    customProps[selector] = CustomProperty::Create<CFPropertyListRef>(
        kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, getter, setter);

    customProps_.Set(std::move(customProps));
}

Boolean Object::HasPropertyFallback(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address) const
{
    auto readLock = customProps_.GetReadLock();

    const auto& customProps = readLock.GetReference();

    if (objectID == GetID()) {
        if (customProps.count(address->mSelector)) {
            GetContext()->Tracer->Message(
                "property found in custom property map, returning HasProperty=true");
            return true;
        }

        GetContext()->Tracer->Message("property not found");
        return false;
    }

    GetContext()->Tracer->Message("object not found");
    return false;
}

OSStatus Object::IsPropertySettableFallback(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    Boolean* outIsSettable) const
{
    auto readLock = customProps_.GetReadLock();

    const auto& customProps = readLock.GetReference();

    if (objectID == GetID()) {
        auto it = customProps.find(address->mSelector);

        if (it == customProps.end()) {
            GetContext()->Tracer->Message("property not found");
            return kAudioHardwareUnknownPropertyError;
        }

        if (outIsSettable) {
            *outIsSettable = bool(it->second->setter);
            GetContext()->Tracer->Message(
                "property found in custom property map, returning IsSettable=%s",
                *outIsSettable ? "true" : "false");
        } else {
            GetContext()->Tracer->Message("output buffer is null");
        }

        return kAudioHardwareNoError;
    }

    GetContext()->Tracer->Message("object not found");
    return kAudioHardwareBadObjectError;
}

OSStatus Object::GetPropertyDataSizeFallback(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32* outDataSize) const
{
    auto readLock = customProps_.GetReadLock();

    const auto& customProps = readLock.GetReference();

    if (objectID == GetID()) {
        auto it = customProps.find(address->mSelector);

        if (it == customProps.end()) {
            GetContext()->Tracer->Message("property not found");
            return kAudioHardwareUnknownPropertyError;
        }

        if (outDataSize) {
            *outDataSize = it->second->size;
            GetContext()->Tracer->Message(
                "property found in custom property map, returning PropertySize=%u",
                unsigned(*outDataSize));
        } else {
            GetContext()->Tracer->Message("output buffer is null");
        }

        return kAudioHardwareNoError;
    }

    GetContext()->Tracer->Message("object not found");
    return kAudioHardwareBadObjectError;
}

OSStatus Object::GetPropertyDataFallback(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32 inDataSize,
    UInt32* outDataSize,
    void* outData) const
{
    auto readLock = customProps_.GetReadLock();

    const auto& customProps = readLock.GetReference();

    if (objectID == GetID()) {
        auto it = customProps.find(address->mSelector);

        if (it == customProps.end()) {
            GetContext()->Tracer->Message("property not found");
            return kAudioHardwareUnknownPropertyError;
        }

        if (!it->second->getter) {
            GetContext()->Tracer->Message("property does not have getter");
            return kAudioHardwareUnknownPropertyError;
        }

        if (inDataSize < it->second->size) {
            GetContext()->Tracer->Message("not enough space: need %u, avail %u",
                unsigned(it->second->size),
                unsigned(inDataSize));
            return kAudioHardwareBadPropertySizeError;
        }

        if (outDataSize) {
            *outDataSize = it->second->size;
        } else {
            GetContext()->Tracer->Message("size buffer is null");
        }

        if (outData) {
            GetContext()->Tracer->Message("returning property from custom property map");
            it->second->getter(outData);
        } else {
            GetContext()->Tracer->Message("data buffer is null");
        }

        return kAudioHardwareNoError;
    }

    GetContext()->Tracer->Message("object not found");
    return kAudioHardwareBadObjectError;
}

OSStatus Object::SetPropertyDataFallback(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32 inDataSize,
    const void* inData)
{
    auto readLock = customProps_.GetReadLock();

    const auto& customProps = readLock.GetReference();

    if (objectID == GetID()) {
        auto it = customProps.find(address->mSelector);

        if (it == customProps.end()) {
            GetContext()->Tracer->Message("property not found");
            return kAudioHardwareUnknownPropertyError;
        }

        if (!it->second->setter) {
            GetContext()->Tracer->Message("property does not have setter");
            return kAudioHardwareUnknownPropertyError;
        }

        if (inDataSize != it->second->size) {
            GetContext()->Tracer->Message("invalid size: should be %u, got %u",
                unsigned(it->second->size),
                unsigned(inDataSize));
            return kAudioHardwareBadPropertySizeError;
        }

        if (!inData) {
            GetContext()->Tracer->Message("input buffer is null");
            return kAudioHardwareIllegalOperationError;
        }

        GetContext()->Tracer->Message("setting property in custom property map");
        it->second->setter(inData);

        return kAudioHardwareNoError;
    }

    GetContext()->Tracer->Message("object not found");
    return kAudioHardwareBadObjectError;
}

} // namespace aspl
