// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/Client.hpp
//! @brief Client.

#pragma once

#include <CoreFoundation/CoreFoundation.h>

#include <string>

#include <unistd.h>

namespace aspl {

//! Information about client.
struct ClientInfo
{
    //! Client identifier.
    //! Allows for differentiating multiple clients in the same process.
    UInt32 ClientID = 0;

    //! Client PID.
    //! The pid_t of the process that contains the client.
    pid_t ProcessID = 0;

    //! Client endianness.
    //! Indicating whether or not the client has the same endianness as the server.
    bool IsNativeEndian = false;

    //! Client bundle.
    //! Bundle ID of the main bundle of the process that contains the client.
    std::string BundleID = "";
};

//! Device client.
//!
//! Represents connection between an app and device. Typically an app has at most
//! one client, but this is not a requirement.
//!
//! Devices asks RequestHandler to create Client object when a new client comes
//! to the devices, and asks to remove it when the client leaves.
//!
//! You may subclass Client if you need to keep additional per-client state. To
//! incorporate your own client class, you'll need to set custom RequestHandler.
class Client
{
public:
    //! Construct client from ClientInfo.
    Client(const ClientInfo& clientInfo);

    Client(const Client&) = delete;
    Client& operator=(const Client&) = delete;

    virtual ~Client() = default;

    //! Client identifier.
    //! Allows for differentiating multiple clients in the same process.
    UInt32 GetClientID() const;

    //! Client PID.
    //! The pid_t of the process that contains the client.
    pid_t GetProcessID() const;

    //! Client endianness.
    //! Indicating whether or not the client has the same endianness as the server.
    bool GetIsNativeEndian() const;

    //! Client bundle.
    //! Bundle ID of the main bundle of the process that contains the client.
    std::string GetBundleID() const;

private:
    const ClientInfo info_;
};

} // namespace aspl
