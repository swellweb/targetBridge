// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/Dispatcher.hpp>
#include <aspl/Object.hpp>

#include <limits>

namespace aspl {

Dispatcher::Dispatcher(std::shared_ptr<Tracer> tracer, AudioObjectID hintMaximumID)
    : tracer_(std::move(tracer))
    , desiredMaximumID_(hintMaximumID)
{
}

std::shared_ptr<Object> Dispatcher::FindObject(AudioObjectID objectID) const
{
    auto readLock = registeredObjects_.GetReadLock();

    const auto& registeredObjects = readLock.GetReference();

    auto iter = registeredObjects.find(objectID);
    if (iter == registeredObjects.end()) {
        if (tracer_) {
            tracer_->Message("Dispatcher::FindObject() objectID=%u not registered",
                unsigned(objectID));
        }
        return {};
    }

    auto& registration = *iter->second;

    std::shared_lock objLock(registration.mutex, std::try_to_lock);

    // The shared lock may fail only if a unique lock is obtained.
    // The only case when it can happen is when UnregisterObject() is in progress.
    // In this case, we should report that there is no such object.
    if (!objLock.owns_lock()) {
        if (tracer_) {
            tracer_->Message("Dispatcher::FindObject() objectID=%u is being unregistered",
                unsigned(objectID));
        }
        return {};
    }

    const auto object = registration.object.load();

    // UnregisterObject() sets object to null before obtaining the lock.
    // In turn, we check the object for null after obtaining the lock.
    if (!object) {
        if (tracer_) {
            tracer_->Message("Dispatcher::FindObject() objectID=%u is being unregistered",
                unsigned(objectID));
        }
        return {};
    }

    try {
        return object->shared_from_this();
    }
    catch (std::bad_weak_ptr&) {
        // The last shared_ptr already destroyed, but didn't call UnregisterObject() yet
        // in this case shared_from_this() throws bad_weak_ptr.
        if (tracer_) {
            tracer_->Message(
                "Dispatcher::FindObject() objectID=%u is dying", unsigned(objectID));
        }
        return {};
    }
}

AudioObjectID Dispatcher::RegisterObject(Object& object, AudioObjectID objectID)
{
    std::lock_guard regLock(registrationMutex_);

    Tracer::Operation op;
    op.Name = "Dispatcher::RegisterObject()";
    op.ObjectID = objectID;

    if (tracer_) {
        tracer_->OperationBegin(op);
    }

    if (objectID == kAudioObjectUnknown) {
        objectID = AllocateID();
    }

    auto registeredObjects = registeredObjects_.Get();

    if (registeredObjects.count(objectID)) {
        if (tracer_) {
            tracer_->Message("objectID=%u already registered", unsigned(objectID));
        }
        objectID = kAudioObjectUnknown;
        goto end;
    }

    registeredObjects[objectID] = std::make_shared<Registration>(&object);
    registeredObjects_.Set(std::move(registeredObjects));

    if (tracer_) {
        tracer_->Message("registered objectID=%u", unsigned(objectID));
    }

end:
    if (tracer_) {
        tracer_->OperationEnd(op, kAudioHardwareNoError);
    }

    return objectID;
}

void Dispatcher::UnregisterObject(AudioObjectID objectID)
{
    std::lock_guard regLock(registrationMutex_);

    Tracer::Operation op;
    op.Name = "Dispatcher::UnregisterObject()";
    op.ObjectID = objectID;

    if (tracer_) {
        tracer_->OperationBegin(op);
    }

    auto registeredObjects = registeredObjects_.Get();

    if (objectID == kAudioObjectUnknown) {
        if (tracer_) {
            tracer_->Message("kAudioObjectUnknown not registered");
        }
        goto end;
    }

    if (!registeredObjects.count(objectID)) {
        if (tracer_) {
            tracer_->Message("objectID=%u not registered", unsigned(objectID));
        }
        goto end;
    }

    {
        // Copy shared pointer to registration.
        auto registration = registeredObjects[objectID];

        // Inform FindObject() that this registration is not usable anymore.
        registration->object.store(nullptr);

        // Remove registration from map.
        // Future FindObject() calls wont find this registration.
        // However it's possible that there are ongoing FindObject() calls that
        // are working with an older version of the map and they can still obtain
        // the registration from it.
        registeredObjects.erase(objectID);
        registeredObjects_.Set(std::move(registeredObjects));

        // Wait until all of them are either before checking the object for null,
        // or are finished. After this, we can be sure that the object is never
        // accessed by other threads, so it's safe to destroy it after we return.
        std::unique_lock objLock(registration->mutex);
    }

    FreeID(objectID);

    if (tracer_) {
        tracer_->Message("unregistered objectID=%u", unsigned(objectID));
    }

end:
    if (tracer_) {
        tracer_->OperationEnd(op, kAudioHardwareNoError);
    }
}

AudioObjectID Dispatcher::AllocateID()
{
    AudioObjectID nextID = lastAllocatedID_ + 1;

    if (nextID >= desiredMaximumID_ && numAllocatedIDs_ > desiredMaximumID_ / 2) {
        if (desiredMaximumID_ <= std::numeric_limits<AudioObjectID>::max() / 2) {
            if (tracer_) {
                tracer_->Message("increasing desired maximum from %u to %u",
                    unsigned(desiredMaximumID_),
                    unsigned(desiredMaximumID_ * 2));
            }
            desiredMaximumID_ *= 2;
        }
    }

    const bool isFree = IsFree(nextID);

    if (tracer_) {
        tracer_->Message("candidate nextID=%u isFree=%d desiredMaximumID=%u",
            unsigned(nextID),
            int(isFree),
            unsigned(desiredMaximumID_));
    }

    if (nextID >= desiredMaximumID_) {
        nextID = FindFreeID(0);
    } else if (!isFree) {
        nextID = FindFreeID(nextID + 1);
    }

    SetFree(nextID, false);
    numAllocatedIDs_++;
    lastAllocatedID_ = nextID;

    if (tracer_) {
        tracer_->Message("allocated objectID=%u numAllocated=%u",
            unsigned(nextID),
            unsigned(numAllocatedIDs_));
    }

    return nextID;
}

void Dispatcher::FreeID(AudioObjectID objectID)
{
    SetFree(objectID, true);
    numAllocatedIDs_--;

    if (tracer_) {
        tracer_->Message("freed objectID=%u numAllocated=%u",
            unsigned(objectID),
            unsigned(numAllocatedIDs_));
    }
}

AudioObjectID Dispatcher::FindFreeID(AudioObjectID startID) const
{
    if (allocatedBits_.size() != 0) {
        const size_t startChunk = startID / BitsPerChunk;

        for (size_t n = 0; n <= allocatedBits_.size(); n++) {
            const size_t chunk = (startChunk + n) % allocatedBits_.size();

            const auto chunkBits = allocatedBits_[chunk];

            if (chunkBits == BitChunk(-1)) {
                continue;
            }

            for (size_t bit = 0; bit < BitsPerChunk; bit++) {
                if ((chunkBits & (BitChunk(1) << bit)) == 0) {
                    const auto objectID = AudioObjectID(chunk * BitsPerChunk + bit);

                    if (n == 0 && objectID < startID) {
                        continue;
                    }

                    if (reservedIDs_.count(objectID)) {
                        continue;
                    }

                    if (tracer_) {
                        tracer_->Message(
                            "selected id inside bitset startID=%u selectedID=%u",
                            unsigned(startID),
                            unsigned(objectID));
                    }

                    return objectID;
                }
            }
        }
    }

    auto objectID = AudioObjectID(allocatedBits_.size() * BitsPerChunk);
    while (reservedIDs_.count(objectID)) {
        objectID++;
    }

    if (tracer_) {
        tracer_->Message("selected id after bitset startID=%u selectedID=%u",
            unsigned(startID),
            unsigned(objectID));
    }

    return objectID;
}

bool Dispatcher::IsFree(AudioObjectID objectID) const
{
    if (reservedIDs_.count(objectID)) {
        return false;
    }

    const size_t chunk = objectID / BitsPerChunk;
    const size_t bit = objectID % BitsPerChunk;

    if (allocatedBits_.size() <= chunk) {
        return true;
    }

    return (allocatedBits_[chunk] & (BitChunk(1) << bit)) == 0;
}

void Dispatcher::SetFree(AudioObjectID objectID, bool free)
{
    const size_t chunk = objectID / BitsPerChunk;
    const size_t bit = objectID % BitsPerChunk;

    if (allocatedBits_.size() <= chunk) {
        allocatedBits_.resize(chunk + 1);
    }

    if (free) {
        allocatedBits_[chunk] &= ~(BitChunk(1) << bit);
    } else {
        allocatedBits_[chunk] |= (BitChunk(1) << bit);
    }
}

} // namespace aspl
