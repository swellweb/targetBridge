// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/Client.hpp>

namespace aspl {

Client::Client(const ClientInfo& clientInfo)
    : info_(clientInfo)
{
}

UInt32 Client::GetClientID() const
{
    return info_.ClientID;
}

pid_t Client::GetProcessID() const
{
    return info_.ProcessID;
}

bool Client::GetIsNativeEndian() const
{
    return info_.IsNativeEndian;
}

std::string Client::GetBundleID() const
{
    return info_.BundleID;
}

} // namespace aspl
