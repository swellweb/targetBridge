// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/Storage.hpp
//! @brief Plugin persistent storage.

#pragma once

#include <aspl/Context.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace aspl {

//! Plugin persistent storage.
//!
//! Storage data persists across audio server restart and rebooting.
//! Storage keys for one plug-in do not collide with the keys for other plug-ins.
//!
//! This class is a wrapper for "Storage Operations" API in
//! AudioServerPlugInHostInterface, which is stored in Context.Host. It becomes
//! available during driver initialization; until that, attempt to use Storage
//! methods will lead to errors.
class Storage
{
public:
    //! Construct storage.
    explicit Storage(std::shared_ptr<Context> context);

    Storage(const Storage&) = delete;
    Storage& operator=(const Storage&) = delete;

    //! Get context.
    std::shared_ptr<const Context> GetContext() const;

    //! Read CFData value from storage and decode it into byte array.
    //! @remarks
    //!  Returns error if value does not exist or has wrong type.
    //! @note
    //!  Uses Context.Host.CopyFromStorage.
    std::pair<std::vector<UInt8>, bool> ReadBytes(std::string key) const;

    //! Read CFString value from storage and decode it into UTF-8 string.
    //! @remarks
    //!  Returns error if value does not exist or has wrong type.
    //! @note
    //!  Uses Context.Host.CopyFromStorage.
    std::pair<std::string, bool> ReadString(std::string key) const;

    //! Read CFBoolean value from storage and decode it into bool.
    //! @remarks
    //!  Returns error if value does not exist or has wrong type.
    //! @note
    //!  Uses Context.Host.CopyFromStorage.
    std::pair<bool, bool> ReadBoolean(std::string key) const;

    //! Read CFNumber value from storage and decode it into SInt64.
    //! @remarks
    //!  Returns error if value does not exist, has wrong type,
    //!  or can not be represented as SInt64 without loss.
    //! @note
    //!  Uses Context.Host.CopyFromStorage.
    std::pair<SInt64, bool> ReadInt(std::string key) const;

    //! Read CFNumber value from storage and decode it into Float64.
    //! @remarks
    //!  Returns error if value does not exist, has wrong type,
    //!  or can not be represented as Float64 without loss.
    //! @note
    //!  Uses Context.Host.CopyFromStorage.
    std::pair<Float64, bool> ReadFloat(std::string key) const;

    //! Read CFPropertyList value from storage and return it.
    //! @remarks
    //!  Returns error if value does not exist.
    //!  Caller is responsible to release returned value.
    //! @note
    //!  Uses Context.Host.CopyFromStorage.
    std::pair<CFPropertyListRef, bool> ReadCustom(std::string key) const;

    //! Encode byte array into CFData value and write it to storage.
    //! @remarks
    //!  Returns error if value can not be encoded or written.
    //! @note
    //!  Uses Context.Host.WriteToStorage.
    bool WriteBytes(std::string key, std::vector<UInt8> value);

    //! Encode C++ string into CFString value and write it to storage.
    //! @remarks
    //!  Returns error if value can not be encoded or written.
    //! @note
    //!  Uses Context.Host.WriteToStorage.
    bool WriteString(std::string key, std::string value);

    //! Encode bool into CFBoolean value and write it to storage.
    //! @remarks
    //!  Returns error if value can not be encoded or written.
    //! @note
    //!  Uses Context.Host.WriteToStorage.
    bool WriteBoolean(std::string key, bool value);

    //! Encode SInt64 into CFNumber value and write it to storage.
    //! @remarks
    //!  Returns error if value can not be encoded or written.
    //! @note
    //!  Uses Context.Host.WriteToStorage.
    bool WriteInt(std::string key, SInt64 value);

    //! Encode Float64 into CFNumber value and write it to storage.
    //! @remarks
    //!  Returns error if value can not be encoded or written.
    //! @note
    //!  Uses Context.Host.WriteToStorage.
    bool WriteFloat(std::string key, Float64 value);

    //! Write CFPropertyList value to storage.
    //! @remarks
    //!  Returns error if value can not be encoded or written.
    //!  Does not take ownership of the value.
    //! @note
    //!  Uses Context.Host.WriteToStorage.
    bool WriteCustom(std::string key, CFPropertyListRef value);

    //! Delete value from storage.
    //! @remarks
    //!  Returns error if value does not exist or can not be deleted.
    //! @note
    //!  Uses Context.Host.DeleteFromStorage.
    bool Delete(std::string key);

private:
    template <class T>
    std::pair<T, bool> CopyFromStorage_(const char* type, std::string key) const;

    template <class T>
    bool WriteToStorage_(const char* type, std::string key, T value);

    bool DeleteFromStorage_(std::string key);

    const std::shared_ptr<Context> context_;
};

} // namespace aspl
