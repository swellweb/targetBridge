// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/Tracer.hpp>

#include "Strings.hpp"

#include <cstdarg>
#include <cstdio>
#include <sstream>

#include <pthread.h>
#include <syslog.h>

namespace aspl {

namespace {

enum
{
    DepthSoftLimit = 10,
    DepthHardLimit = 1000,
};

unsigned long GetThreadID()
{
    UInt64 tid = 0;
    pthread_threadid_np(nullptr, &tid);

    return static_cast<unsigned long>(tid);
}

} // namespace

Tracer::Tracer(Mode mode, Style style)
    : mode_(mode)
    , style_(style)
{
    pthread_key_create(&threadKey_, DestroyThreadLocalState);
}

void* Tracer::CreateThreadLocalState()
{
    return new ThreadLocalState;
}

void Tracer::DestroyThreadLocalState(void* ptr)
{
    delete static_cast<ThreadLocalState*>(ptr);
}

Tracer::ThreadLocalState& Tracer::GetThreadLocalState()
{
    void* ptr = pthread_getspecific(threadKey_);

    if (!ptr) {
        ptr = CreateThreadLocalState();
        pthread_setspecific(threadKey_, ptr);
    }

    return *static_cast<ThreadLocalState*>(ptr);
}

void Tracer::OperationBegin(const Operation& op)
{
    if (mode_ == Mode::Noop) {
        return;
    }

    auto& threadState = GetThreadLocalState();

    if (threadState.DepthCounter < DepthHardLimit) {
        threadState.DepthCounter++;
    } else {
        Print(
            "Tracer: detected unpaired OperationBegin/OperationEnd"
            " or infinite recursion");
    }

    if (threadState.IgnoreCounter != 0 &&
        threadState.DepthCounter >= threadState.IgnoreCounter) {
        return;
    }

    if (ShouldIgnore(op)) {
        threadState.IgnoreCounter = threadState.DepthCounter;
        return;
    }

    const auto str = FormatOperationBegin(op, threadState.DepthCounter);

    Print(str.c_str());
}

void Tracer::Message(const char* format, ...)
{
    if (mode_ == Mode::Noop) {
        return;
    }

    auto& threadState = GetThreadLocalState();

    if (threadState.IgnoreCounter != 0 &&
        threadState.DepthCounter >= threadState.IgnoreCounter) {
        return;
    }

    char message[MaxMessageLen] = {};

    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);

    const auto str = FormatMessage(message, threadState.DepthCounter);

    Print(str.c_str());
}

void Tracer::OperationEnd(const Operation& op, OSStatus status)
{
    if (mode_ == Mode::Noop) {
        return;
    }

    auto& threadState = GetThreadLocalState();

    if (threadState.IgnoreCounter != 0 &&
        threadState.DepthCounter >= threadState.IgnoreCounter) {
        if (threadState.DepthCounter == threadState.IgnoreCounter) {
            threadState.IgnoreCounter = 0;
        }
        threadState.DepthCounter--;
        return;
    }

    const auto str = FormatOperationEnd(op, status, threadState.DepthCounter);

    Print(str.c_str());

    if (threadState.DepthCounter != 0) {
        threadState.DepthCounter--;
    } else {
        Print("Tracer: detected unpaired OperationBegin/OperationEnd");
    }
}

std::string Tracer::FormatOperationBegin(const Operation& op, UInt32 depth)
{
    if (depth > DepthSoftLimit) {
        depth = DepthSoftLimit;
    }

    std::ostringstream ss;

    if (style_ == Style::Hierarchical) {
        ss << "|";
        for (UInt32 i = 0; i < depth; i++) {
            ss << "-";
        }
        ss << " ";
    }

    ss << op.Name << " begin";

    if (op.PropertyAddress) {
        ss << " " << PropertySelectorToString(op.PropertyAddress->mSelector);
    }

    if (op.ClientPID != 0) {
        ss << " clientPID=" << op.ClientPID;
    }

    ss << " objectID=" << op.ObjectID;

    if (op.PropertyAddress) {
        ss << " scope=" << PropertyScopeToString(op.PropertyAddress->mScope);
    }

    if (op.InDataSize != 0 || op.InData != nullptr) {
        ss << " inSize=" << op.InDataSize;
    }

    if (op.QualifierDataSize != 0 || op.QualifierData != nullptr) {
        ss << " qualSize=" << op.QualifierDataSize;
    }

    return ss.str();
}

std::string Tracer::FormatMessage(const char* message, UInt32 depth)
{
    if (depth > DepthSoftLimit) {
        depth = DepthSoftLimit;
    }

    std::ostringstream ss;

    if (style_ == Style::Hierarchical) {
        ss << "|";
        for (UInt32 i = 0; i <= depth; i++) {
            ss << "-";
        }
        ss << " ";
    }

    ss << message;

    return ss.str();
}

std::string Tracer::FormatOperationEnd(const Operation& op, OSStatus status, UInt32 depth)
{
    if (depth > DepthSoftLimit) {
        depth = DepthSoftLimit;
    }

    std::ostringstream ss;

    if (style_ == Style::Hierarchical) {
        ss << "|";
        for (UInt32 i = 0; i < depth; i++) {
            ss << "-";
        }
        ss << " ";
    }

    ss << op.Name << " end";

    ss << " status=" << StatusToString(status);

    if (status == kAudioHardwareNoError && op.OutDataSize != nullptr) {
        ss << " outSize=" << *op.OutDataSize;
    }

    return ss.str();
}

void Tracer::Print(const char* message)
{
    switch (mode_) {
    case Mode::Noop:
        return;

    case Mode::Stderr:
        fprintf(stderr, "[aspl] %s\n", message);
        return;

    case Mode::Syslog:
        syslog(LOG_NOTICE, "[aspl] [tid:%lu] %s", GetThreadID(), message);
        return;

    case Mode::Custom:
        return;
    }
}

bool Tracer::ShouldIgnore(const Operation& operation)
{
    (void)operation;

    return false;
}

} // namespace aspl
