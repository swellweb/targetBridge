// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/DriverRequestHandler.hpp
//! @brief Handler for HAL requests to driver.

#pragma once

namespace aspl {

//! Handler for HAL requests to driver.
//!
//! You may subclass this class if you want to implement custom handling.
class DriverRequestHandler
{
public:
    DriverRequestHandler() = default;

    DriverRequestHandler(const DriverRequestHandler&) = delete;
    DriverRequestHandler& operator=(const DriverRequestHandler&) = delete;

    virtual ~DriverRequestHandler() = default;

    //! Invoked during asynchronous driver initialization.
    virtual OSStatus OnInitialize()
    {
        return kAudioHardwareNoError;
    }
};

} // namespace aspl
