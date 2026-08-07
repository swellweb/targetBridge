// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/Context.hpp
//! @brief Context.

#pragma once

#include <aspl/Dispatcher.hpp>
#include <aspl/Tracer.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <atomic>
#include <memory>

namespace aspl {

//! Common object context.
//! Shared between objects which belong to the same driver.
struct Context
{
    //! Object dispatcher.
    //! Maps object identifiers to objects.
    //! Object ID is unique within a dispatcher.
    const std::shared_ptr<Dispatcher> Dispatcher;

    //! Object operation tracer.
    //! All objects use it for logging.
    const std::shared_ptr<Tracer> Tracer;

    //! Plugin host.
    //! Contains method table of HAL.
    //! Initially host is null. It is set during plugin initialization.
    std::atomic<AudioServerPlugInHostRef> Host = nullptr;

    //! Create context.
    //! If dispatcher or tracer is not specified, default one is created.
    //! Default tracer sends output to syslog.
    explicit Context(std::shared_ptr<aspl::Tracer> tracer = {},
        std::shared_ptr<aspl::Dispatcher> dispatcher = {})
        : Dispatcher(
              dispatcher ? std::move(dispatcher) : std::make_shared<aspl::Dispatcher>())
        , Tracer(tracer ? std::move(tracer) : std::make_shared<aspl::Tracer>())
    {
    }
};

} // namespace aspl
