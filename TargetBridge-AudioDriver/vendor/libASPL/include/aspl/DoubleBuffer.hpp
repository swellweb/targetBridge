// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/DoubleBuffer.hpp
//! @brief Double buffer.

#pragma once

#include <CoreFoundation/CoreFoundation.h>

#include <atomic>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <utility>

namespace aspl {

//! Doubly-buffered value with non-blocking read and blocking write.
//!
//! Logically, this is a single-value container, which has getter and setter
//! with the following characteristics:
//!
//!  - getters are running concurrently, and setters are serialized
//!
//!  - setter is blocking; it may be blocked by both getters and setters,
//!    but in the average case only by setters
//!
//!  - getter is non-blocking and lock-free; it does not block if a setter
//!    thread is suspended in the middle
//!
//!  - getter is not wait-free though; if setters are called too frequently
//!    and have higher priority, then getter may spin until it has a chance
//!    to cut in between
//!
//!  - sequential consistency is provided; after a setter returns, it's
//!    guaranteed that subsequent getters will observe up-to-date value
//!
//! Physically container is implemented as two copies of the value:
//!
//!  - one copy is read-only and used by getters (concurrently)
//!
//!  - another one is for setters; basically, the setter updates its copy
//!    while it's not visible to getters, waits until all getter using
//!    another copy finish, and switches the copies
//!
//! The algorithm is optimized for the following use case:
//!
//!  - getters are frequent and setters are infrequent
//!
//!  - the value is not very large and it's acceptable to make
//!    extra copies
//!
//! The value stored in the double buffer is immutable after it's set. To
//! change the value, you need to call the getter, make a copy, modify it,
//! and pass it to the setter.
//!
//! The value should have public default and copy constructors. If it also
//! has move constructor, it can be used in setter.
//!
//! If the value has non-trivial destructor, before setter returns, it waits
//! until the previously used value is not accessed by readers anymore and
//! invokes destructor for the old value.
//!
//! Typical reader looks like the following:
//! @code
//!   DoubleBuffer<T> fooBuf;
//!   ...
//!   {
//!     auto readLock = fooBuf.GetReadLock();
//!
//!     const T& fooValue = readLock.GetReference();
//!     // safe read-only access to fooValue until block end
//!   }
//! @endcode
//!
//! Or, if the reader is okay to call the copy constructor:
//! @code
//!   DoubleBuffer<T> fooBuf;
//!   ...
//!   T fooValue = fooBuf.Get();
//! @endcode
//!
//! Typical writer looks like this:
//! @code
//!   DoubleBuffer<T> fooBuf;
//!   ...
//!   T fooValue = fooBuf.Get();
//!   // modify fooValue
//!   fooBuf.Set(std::move(fooValue));
//! @endcode
//!
//! @see ReadLock.
template <typename T>
class DoubleBuffer
{
    using BufferIndex = SInt64;

    struct Buffer
    {
        std::optional<T> value = {};
        std::atomic<BufferIndex> index = -1;
        mutable std::shared_mutex mutex;
    };

public:
    //! Read lock.
    //!
    //! Similar to scoped locks like std::lock_guard, but also provides
    //! GetReference() method to access the value.
    //!
    //! While the lock is alive, it's safe to access the data for reading.
    class ReadLock
    {
    public:
        //! Acquire the lock.
        //! Non-blocking and lock-free.
        //! May spin for a while if a setter is running concurrently, but wont
        //! block if the setter is suspended somewhere on the halfway.
        ReadLock(const DoubleBuffer& doubleBuffer)
        {
            for (;;) {
                // Load current buffer index.
                const auto currentIndex = doubleBuffer.currentIndex_.load();

                // Get reference to the current buffer.
                auto& currentBuffer = doubleBuffer.GetBufferAt(currentIndex);

                // Try to lock buffer for reading.
                //
                // The lock can fail in the case when, after we loaded the current
                // index, but before obtained the lock, the setter was called and
                // finished once, and then was called another time and is currently
                // in progress. Here we should retry and re-read current index.
                //
                // We're still lock-free because even if the ongoing setter is
                // suspended, we wont block. Instead, on the next try we will
                // switch to another buffer and will successfully obtain the lock.
                //
                // However, we're not wait-free because while this situation is
                // repeating and new setters continue to come and preempt us, we'll
                // have to retry. Fortunately, this is very unlikely to happen.
                if (!currentBuffer.mutex.try_lock_shared()) {
                    continue;
                }

                // Check that the buffer index still matches the our current index
                // after obtaining the lock.
                //
                // This check catches the case similar to the above one, but when
                // the second setter is already finished.
                if (currentBuffer.index.load() != currentIndex) {
                    currentBuffer.mutex.unlock_shared();
                    continue;
                }

                // At this point, it is guaranteed that any setter will see that
                // we're using the buffer and wont rewrite it until we release
                // the lock in destructor.
                buffer_ = &currentBuffer;
                return;
            }
        }

        //! Release the lock.
        ~ReadLock()
        {
            if (buffer_) {
                buffer_->mutex.unlock_shared();
            }
        }

        //! Move lock.
        ReadLock(ReadLock&& other)
            : buffer_(other.buffer_)
        {
            other.buffer_ = nullptr;
        }

        ReadLock(const ReadLock&) = delete;
        ReadLock& operator=(const ReadLock&) = delete;
        ReadLock& operator=(ReadLock&&) = delete;

        //! Get read-only reference to the value.
        //! The reference may be used until read lock destructor is called.
        //! The referred value is guaranteed to be immutable until that.
        const T& GetReference() const
        {
            return *buffer_->value;
        }

    private:
        const Buffer* buffer_ = nullptr;
    };

    //! Initialize buffer with given value.
    explicit DoubleBuffer(const T& value)
    {
        Set(value);
    }

    //! Initialize buffer with given value.
    explicit DoubleBuffer(T&& value = T())
    {
        Set(std::move(value));
    }

    ~DoubleBuffer() = default;

    DoubleBuffer(const DoubleBuffer&) = delete;
    DoubleBuffer& operator=(const DoubleBuffer&) = delete;

    //! Get locked read-only reference to the value.
    //! Non-blocking and lock-free, see ReadLock.
    ReadLock GetReadLock() const
    {
        return ReadLock(*this);
    }

    //! Get copy of the value.
    //! Non-blocking and lock-free, see ReadLock.
    T Get() const
    {
        ReadLock readLock(*this);

        return T(readLock.GetReference());
    }

    //! Set value.
    //!
    //! Blocks until all getters, invoked before this call, are finished.
    //! Concurrent setter calls are serialized.
    //!
    //! It is guaranteed that if a getter is called after a setter returns,
    //! the getter will observe the updated value.
    //!
    //! The value is either copied or moved into the internal buffer,
    //! depending on whether an lvalue or rvalue is passed.
    template <typename TT>
    void Set(TT&& value)
    {
        // Serialize setters.
        std::lock_guard writeLock(writeMutex_);

        // Load current buffer index.
        // Since this index is modified only by setters, it's safe to use "relaxed".
        const auto oldIndex = currentIndex_.load(std::memory_order_relaxed);

        // Calculate next index.
        // Maximum signed value overflows to zero.
        // Negative indices are reserved to indicate invalidated buffers.
        const auto newIndex =
            oldIndex < std::numeric_limits<BufferIndex>::max() ? oldIndex + 1 : 0;

        // Get reference to the current buffer.
        auto& oldBuffer = GetBufferAt(oldIndex);

        // Get reference to the next buffer, i.e. not the current one.
        auto& newBuffer = GetBufferAt(newIndex);

        {
            // Notify getters which were started earlier and are either working or going
            // to work with this buffer that the buffer is going to be invalidated.
            newBuffer.index = newIndex;

            // Wait until finishing of ongoing getters that are still using this buffer.
            //
            // After we obtain the lock, we can be sure that old getters are either
            // finished or will see the index which we've updated above and wont use the
            // buffer.
            //
            // Note that since it is the other buffer, not the current one, chances are
            // that there are no getters already, and most times we will acquire the lock
            // immediately here.
            std::unique_lock lock(newBuffer.mutex);

            // Forward the value to the buffer.
            newBuffer.value = std::forward<TT>(value);
        }

        // Switch current buffer index to the new buffer.
        // It is guaranteed that all getters invoked after this point will return
        // the new value.
        currentIndex_ = newIndex;

        if constexpr (!std::is_trivial<T>::value) {
            // Notify getters which were started earlier and are either working or going
            // to work with this buffer that the buffer is going to be invalidated.
            oldBuffer.index = -1;

            // Wait until finishing of ongoing getters that are still using the buffer.
            // Here we can block for a while.
            std::unique_lock lock(oldBuffer.mutex);

            // Destroy value.
            // This is needed to provide semantics of "replacing" value. We've written
            // the new value and we should destroy the old one.
            oldBuffer.value = {};
        }
    }

private:
    friend class ReadLock;

    const Buffer& GetBufferAt(BufferIndex index) const
    {
        return buffers_[index % 2];
    }

    Buffer& GetBufferAt(BufferIndex index)
    {
        return buffers_[index % 2];
    }

    std::mutex writeMutex_;

    Buffer buffers_[2];
    std::atomic<BufferIndex> currentIndex_ = 0;
};

} // namespace aspl
