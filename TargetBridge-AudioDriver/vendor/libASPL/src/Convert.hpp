// Copyright (c) libASPL authors
// Licensed under MIT

#pragma once

#include "Traits.hpp"

#include <CoreAudio/AudioServerPlugIn.h>

#include <sstream>
#include <string>
#include <type_traits>
#include <vector>

namespace aspl {

class Convert
{
public:
    template <typename T>
    static std::string ToString(const T& value)
    {
        if constexpr (std::is_convertible<T, std::string>::value) {
            return value;
        }

        if constexpr (std::is_arithmetic<T>::value) {
            return std::to_string(value);
        }

        if constexpr (std::is_enum<T>::value) {
            return std::to_string(static_cast<typename std::underlying_type_t<T>>(value));
        }

        if constexpr (std::is_array<T>::value || is_vector<T>::value) {
            return FormatArray(value);
        }

        if constexpr (std::is_same<T, AudioValueRange>::value) {
            return FormatValue(value);
        }

        if constexpr (std::is_same<T, AudioStreamBasicDescription>::value) {
            return FormatValue(value);
        }

        if constexpr (std::is_same<T, AudioStreamRangedDescription>::value) {
            return FormatValue(value);
        }

        return "...";
    }

    template <typename T,
        typename = typename std::enable_if_t<std::is_trivially_copyable<T>::value, void>>
    static void ToFoundation(const T& value, T& result)
    {
        result = value;
    }

    template <typename T,
        typename = typename std::enable_if_t<std::is_trivially_copyable<T>::value, void>>
    static bool FromFoundation(const T& value, T& result)
    {
        result = value;
        return true;
    }

    template <typename T,
        typename = typename std::enable_if_t<std::is_enum<T>::value, void>>
    static void ToFoundation(T value, typename std::underlying_type_t<T>& result)
    {
        result = static_cast<typename std::underlying_type_t<T>>(value);
    }

    template <typename T,
        typename = typename std::enable_if_t<std::is_enum<T>::value, void>>
    static bool FromFoundation(typename std::underlying_type_t<T> value, T& result)
    {
        result = static_cast<T>(value);
        return true;
    }

    static void ToFoundation(bool value, UInt32& result)
    {
        result = (value ? 1 : 0);
    }

    static bool FromFoundation(UInt32 value, bool& result)
    {
        result = (value != 0);
        return true;
    }

    static void ToFoundation(const std::string& value, CFStringRef& result);
    static bool FromFoundation(CFStringRef value, std::string& result);

    static void ToFoundation(const std::string& value, CFURLRef& result);
    static bool FromFoundation(CFURLRef value, std::string& result);

    static void ToFoundation(const std::vector<UInt8>& value, CFPropertyListRef& result);
    static bool FromFoundation(CFPropertyListRef value, std::vector<UInt8>& result);

    static void ToFoundation(const std::string& value, CFPropertyListRef& result);
    static bool FromFoundation(CFPropertyListRef value, std::string& result);

    static void ToFoundation(bool value, CFPropertyListRef& result);
    static bool FromFoundation(CFPropertyListRef value, bool& result);

    static void ToFoundation(SInt64 value, CFPropertyListRef& result);
    static bool FromFoundation(CFPropertyListRef value, SInt64& result);

    static void ToFoundation(Float64 value, CFPropertyListRef& result);
    static bool FromFoundation(CFPropertyListRef value, Float64& result);

private:
    static std::string FormatValue(const AudioValueRange& value);
    static std::string FormatValue(const AudioStreamBasicDescription& value);
    static std::string FormatValue(const AudioStreamRangedDescription& value);

    template <typename T>
    static std::string FormatArray(const T& array)
    {
        std::ostringstream ss;

        std::string sep = "[";
        for (const auto& elem : array) {
            ss << sep << ToString(elem);
            sep = ", ";
        }
        ss << "]";

        return ss.str();
    }
};

} // namespace aspl
