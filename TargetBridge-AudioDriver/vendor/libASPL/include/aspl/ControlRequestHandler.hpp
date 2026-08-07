// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/ControlRequestHandler.hpp
//! @brief Handler for control requests to device.

#pragma once

#include <aspl/Client.hpp>

#include <CoreAudio/AudioHardwareBase.h>

#include <memory>

namespace aspl {

//! Handler for control requests to device.
//!
//! You may subclass this class if you want to implement custom handling or
//! inject custom Client implementation.
class ControlRequestHandler
{
public:
    ControlRequestHandler() = default;

    ControlRequestHandler(const ControlRequestHandler&) = delete;
    ControlRequestHandler& operator=(const ControlRequestHandler&) = delete;

    virtual ~ControlRequestHandler() = default;

    //! @name Start / stop
    //! @{

    //! Invoked by Device when the very first client wants to start I/O.
    //! If desired, may block to perform all necessary initialization.
    //! If error is returned, device reports error to clients.
    //! After this call, StopIO() will invoked eventually.
    //! After that, StartIO() may be called again.
    virtual OSStatus OnStartIO()
    {
        return kAudioHardwareNoError;
    }

    //! Invoked by Device when the last client has stopped I/O.
    //! After this call, StartIO() may be called again.
    virtual void OnStopIO()
    {
    }

    //! @}

    //! @name Clients
    //! @{

    //! Invoked by Device when a new client attaches to it.
    //! Override to handle client creation.
    //! Should construct a Client bases on provided ClientInfo.
    virtual std::shared_ptr<Client> OnAddClient(const ClientInfo& clientInfo)
    {
        return std::make_shared<Client>(clientInfo);
    }

    //! Invoked by Device when a client detaches from it.
    //! Override to handle client removal.
    //! The provided shared pointer is the last reference to the client.
    virtual void OnRemoveClient(std::shared_ptr<Client> client)
    {
    }

    //! @}
};

} // namespace aspl
