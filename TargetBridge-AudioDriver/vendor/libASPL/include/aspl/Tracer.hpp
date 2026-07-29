// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/Tracer.hpp
//! @brief Operation tracer.

#pragma once

#include <CoreAudio/AudioServerPlugIn.h>

#include <pthread.h>
#include <unistd.h>

#include <string>

namespace aspl {

//! Operation tracer.
//!
//! All objects use tracer to report operations issued by HAL. By default,
//! tracer sends messages to syslog with "[aspl]" prefix.
//!
//! Tracer maintains per-thread operations depth counter. Nested operations
//! are automatically indented.
//!
//! If you want to change formatting, you can use one of the predefined
//! styles or override FormatXXX() methods.
//!
//! If you want to change tracer output, you can use one of the predefined
//! modes or override Print() method.
//!
//! If you want to exclude some operations from trace, you can override
//! ShouldIgnore() method.
class Tracer
{
public:
    //! Tracing mode.
    enum class Mode
    {
        //! No operation.
        //! Don't perform any tracing.
        Noop,

        //! Standard error stream.
        //! Send all messages to stderr.
        Stderr,

        //! System log.
        //! Send all messages to syslog().
        Syslog,

        //! Custom mode.
        //! Use if derived class does something different.
        Custom,
    };

    //! Tracing style.
    enum class Style
    {
        //! Indent nested operations.
        Hierarchical,

        //! No indentation.
        Flat,
    };

    //! Operation flags.
    struct Flags
    {
        //! This operation is read-only, i.e. doesn't change object state.
        static constexpr UInt32 Readonly = (1 << 0);

        //! This operation is intended to be called on real-time thread on hot path.
        //! Such operations are traced only if the user enabled the option
        //! DeviceParameters::EnableRealtimeTracing
        static constexpr UInt32 Realtime = (1 << 1);
    };

    //! Operation info.
    struct Operation
    {
        //! Operation name.
        const char* Name = nullptr;

        //! Operation flags.
        UInt32 Flags = 0;

        //! ID of object for which operation was initiated.
        AudioObjectID ObjectID = 0;

        //! PID of client which initiated operation.
        pid_t ClientPID = 0;

        //! Address of property.
        //! May be null.
        const AudioObjectPropertyAddress* PropertyAddress = nullptr;

        //! Qualifier size.
        //! May be zero.
        UInt32 QualifierDataSize = 0;

        //! Qualifier data.
        //! May be null.
        const void* QualifierData = nullptr;

        //! Input size.
        //! Non-zero for operations that have input or output data.
        UInt32 InDataSize = 0;

        //! Input data.
        //! Non-null for operations that have input data.
        const void* InData = nullptr;

        //! Output size.
        //! Non-null for operations that have output data.
        const UInt32* OutDataSize = nullptr;

        //! Output data.
        //! Non-null for operations that have output data.
        const void* OutData = nullptr;
    };

    //! Initialize tracer.
    //! Mode defines where to send messages.
    //! Style defines how to format messages.
    explicit Tracer(Mode mode = Mode::Syslog, Style style = Style::Hierarchical);

    Tracer(const Tracer&) = delete;
    Tracer& operator=(const Tracer&) = delete;

    virtual ~Tracer() = default;

    //! Called when an operations starts.
    //! Default implementation formats arguments and calls Print().
    virtual void OperationBegin(const Operation& operation);

    //! Called to print message to log.
    //! Default implementation formats arguments and calls Print().
    virtual void Message(const char* format, ...) __attribute__((format(printf, 2, 3)));

    //! Called when an operations completes.
    //! Zero status indicates operation success.
    //! Default implementation formats arguments and calls Print().
    virtual void OperationEnd(const Operation& operation, OSStatus status);

protected:
    //! Format operation begin message into string.
    //! Called by default implementation of OperationBegin().
    virtual std::string FormatOperationBegin(const Operation& operation, UInt32 depth);

    //! Format message into string.
    //! Called by default implementation of Message().
    virtual std::string FormatMessage(const char* message, UInt32 depth);

    //! Format operation end message into string.
    //! Called by default implementation of OperationEnd().
    virtual std::string FormatOperationEnd(const Operation& operation,
        OSStatus status,
        UInt32 depth);

    //! Print message somewhere.
    //! Default implementation sends message to syslog if mode is Mode::Syslog,
    //! or does nothing if mode is Mode::Noop.
    virtual void Print(const char* message);

    //! Check whether the operation should be excluded from tracing.
    //! If this method returns true, the operation itself, as well as
    //! all nested operations, are not printed.
    //! Default implementation always returns false.
    virtual bool ShouldIgnore(const Operation& operation);

private:
    struct ThreadLocalState
    {
        UInt32 DepthCounter = 0;
        UInt32 IgnoreCounter = 0;
    };

    static void* CreateThreadLocalState();
    static void DestroyThreadLocalState(void*);

    ThreadLocalState& GetThreadLocalState();

    static constexpr size_t MaxMessageLen = 1024;

    const Mode mode_;
    const Style style_;

    pthread_key_t threadKey_;
};

} // namespace aspl
