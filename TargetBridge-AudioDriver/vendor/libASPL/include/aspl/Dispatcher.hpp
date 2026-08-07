// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/Dispatcher.hpp
//! @brief Object dispatcher.

#pragma once

#include <aspl/DoubleBuffer.hpp>
#include <aspl/Tracer.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace aspl {

class Object;

//! Object dispatcher.
//!
//! Every object registers itself here in its constructor, and
//! unregisters in destructor.
//!
//! Dispatcher allocates object identifiers and maps identifiers to objects.
//! Freed identifiers are reused.
//!
//! The allocation algorithm tries to delay identifier reuse for a while, to
//! give you a chance to catch bugs with looking up recently freed objects.
//!
//! Dispatcher stores weak references to objects and thus does not affect
//! their reference counter.
class Dispatcher
{
public:
    //! Construct dispatcher.
    //! Use tracer if you want to debug dispatcher itself, it is quite verbose.
    Dispatcher(std::shared_ptr<Tracer> tracer = {}, AudioObjectID hintMaximumID = 1000);

    Dispatcher(const Dispatcher&) = delete;
    Dispatcher& operator=(const Dispatcher&) = delete;

    //! Find registered object by ID.
    //! Returns null if there is no such object.
    //! @note
    //!  This method can be called from realtime threads.
    std::shared_ptr<Object> FindObject(AudioObjectID objectID) const;

    //! Register new object.
    //! If objectID is kAudioObjectUnknown (zero), a new ID is allocated.
    //! Otherwise, given ID is used.
    //! @note
    //!  This method should not be called from realtime threads.
    AudioObjectID RegisterObject(Object& object,
        AudioObjectID objectID = kAudioObjectUnknown);

    //! Unregister previously registered object.
    //! It's guaranteed that after this method returns, the registered
    //! object is not accessed by dispatcher anymore and can be destroyed.
    //! @note
    //!  This method should not be called from realtime threads.
    void UnregisterObject(AudioObjectID objectID);

private:
    struct Registration
    {
        explicit Registration(Object* obj)
            : object(obj)
        {
        }

        std::atomic<Object*> object;
        std::shared_mutex mutex;
    };

    AudioObjectID AllocateID();
    void FreeID(AudioObjectID objectID);

    AudioObjectID FindFreeID(AudioObjectID startID) const;
    bool IsFree(AudioObjectID objectID) const;
    void SetFree(AudioObjectID objectID, bool free);

    using BitChunk = UInt64;
    static constexpr size_t BitsPerChunk = sizeof(BitChunk) * 8;

    // Optional tracer.
    const std::shared_ptr<Tracer> tracer_;

    // Identifiers that should not be auto-allocated.
    const std::unordered_set<AudioObjectID> reservedIDs_ = {
        kAudioObjectUnknown,
        kAudioObjectPlugInObject,
    };

    // Registered objects.
    // We store raw pointers instead of shared_ptr to allow object registration
    // to happen in Object constructor. At that point, there is no shared_ptr
    // yet and shared_from_this() can't be used either. Thus, we delay
    // shared_from_this() call to the time when FindObject() is called.
    DoubleBuffer<std::unordered_map<AudioObjectID, std::shared_ptr<Registration>>>
        registeredObjects_;

    // Serializes (de)registration operations and protects fields below.
    std::mutex registrationMutex_;

    // Bitset with allocated identifiers.
    std::vector<BitChunk> allocatedBits_;

    size_t numAllocatedIDs_ = 0;
    AudioObjectID lastAllocatedID_ = 0;

    // The maximum value below which we're currently trying to keep identifiers.
    // If the next identifier exceeds this value, and there are quite a lot of
    // free identifiers below the maximum, we'll reuse one of them. Otherwise,
    // if there are too little free identifiers below the maximum, we'll increase
    // the maximum instead.
    AudioObjectID desiredMaximumID_;
};

} // namespace aspl
