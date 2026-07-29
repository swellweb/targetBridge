// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/IORequestHandler.hpp
//! @brief Handler for I/O requests to device.

#pragma once

#include <aspl/Client.hpp>
#include <aspl/Stream.hpp>

#include <CoreFoundation/CoreFoundation.h>

#include <cstring>
#include <memory>

namespace aspl {

//! Handler for I/O requests to device.
//!
//! Device invokes methods of this class when HAL requests it to perform I/O
//! operations. All actual I/O happens here.
//!
//! What methods are invoked depends on whether the device has input and output
//! streams and what is the value of DeviceParameters::EnableMixing.
//!
//! All methods of this class are invoked on realtime thread and thus they
//! should not call blocking operations.
//!
//! It's safe to invoke any GetXXX() and ApplyProcessing() method. It's not
//! safe to invoke any SetXXX() and AddXXX() method and any other method
//! that is modifying object's state.
class IORequestHandler
{
public:
    IORequestHandler() = default;

    IORequestHandler(const IORequestHandler&) = delete;
    IORequestHandler& operator=(const IORequestHandler&) = delete;

    virtual ~IORequestHandler() = default;

    //! @name Reading per-client samples from device
    //! @{

    //! Read data from device to client.
    //!
    //! Invoked by Device::DoIOOperation() on realtime thread.
    //!
    //! Should fill the destination buffer with the requested number of bytes
    //! with data from device's stream, at given offset (timestamp).
    //!
    //! The output data should be in device's stream native format.
    //!
    //! Provided with the current current zero timestamp (last value returned by
    //! GetZeroTimestamp()), and requested timestamp (offset of the data).
    //! Both timestamps are measured in number of frames.
    //!
    //! Default implementation fills buffer with zeros.
    virtual void OnReadClientInput(const std::shared_ptr<Client>& client,
        const std::shared_ptr<Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount)
    {
        memset(bytes, 0, bytesCount);
    }

    //! Process data returned by ReadClientInput() before passing it to client.
    //!
    //! Invoked by Device::DoIOOperation() on realtime thread.
    //!
    //! Should modify the passed frames according to per-client or per-stream
    //! processing rules.
    //!
    //! The samples are in canonical format, i.e. native endian 32-bit
    //! interleaved floats.
    //!
    //! The provided buffer contains exactly @p frameCount * @p channelCount samples.
    //!
    //! Default implementation just invokes Stream::ApplyProcessing().
    virtual void OnProcessClientInput(const std::shared_ptr<Client>& client,
        const std::shared_ptr<Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount)
    {
        stream->ApplyProcessing(frames, frameCount, channelCount);
    }

    //! @}

    //! @name Writing per-client samples to device
    //! @{

    //! Process data from client before passing it to WriteClientOutput().
    //!
    //! Invoked by Device::DoIOOperation() on realtime thread.
    //!
    //! Should modify the passed samples according to per-client or per-stream
    //! processing rules.
    //!
    //! The samples are in canonical format, i.e. native endian 32-bit
    //! interleaved floats.
    //!
    //! The provided buffer contains exactly @p frameCount * @p channelCount samples.
    //!
    //! Default implementation just invokes Stream::ApplyProcessing().
    virtual void OnProcessClientOutput(const std::shared_ptr<Client>& client,
        const std::shared_ptr<Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount)
    {
        stream->ApplyProcessing(frames, frameCount, channelCount);
    }

    //! Write data from client to device.
    //!
    //! Invoked by Device::DoIOOperation() on realtime thread.
    //! Used only if DeviceParameters::EnableMixing is false.
    //!
    //! Should read the requested number of bytes from the provided buffer and
    //! mix them into device at given offset (timestamp).
    //!
    //! The input data is already in device's stream native format.
    //!
    //! Provided with the current current zero timestamp (last value returned by
    //! GetZeroTimestamp()), and requested timestamp (offset of the data).
    //! Both timestamps are measured in number of frames.
    //!
    //! Default implementation does nothing.
    virtual void OnWriteClientOutput(const std::shared_ptr<Client>& client,
        const std::shared_ptr<Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount)
    {
    }

    //! @}

    //! @name Writing mixed samples to device
    //! @{

    //! Process data from client before passing it to WriteMixedOutput().
    //!
    //! Invoked by Device::DoIOOperation() on realtime thread.
    //!
    //! Should modify the passed samples according to per-client or per-stream
    //! processing rules.
    //!
    //! The samples are in canonical format, i.e. native endian 32-bit
    //! interleaved floats.
    //!
    //! The provided buffer contains exactly @p frameCount * @p channelCount samples.
    //!
    //! Default implementation just invokes Stream::ApplyProcessing().
    virtual void OnProcessMixedOutput(const std::shared_ptr<Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount)
    {
        stream->ApplyProcessing(frames, frameCount, channelCount);
    }

    //! Write mixed data from all clients to device.
    //!
    //! Invoked by Device::DoIOOperation() on realtime thread.
    //! Used only if DeviceParameters::EnableMixing is true.
    //!
    //! Should read the requested number of bytes from the provided buffer and
    //! write them into device at given offset (timestamp).
    //!
    //! The input data is already in device's stream native format.
    //!
    //! Provided with the current current zero timestamp (last value returned by
    //! GetZeroTimestamp()), and requested timestamp (offset of the data).
    //! Both timestamps are measured in number of frames.
    //!
    //! Default implementation does nothing.
    virtual void OnWriteMixedOutput(const std::shared_ptr<Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount)
    {
    }

    //! @}
};

} // namespace aspl
