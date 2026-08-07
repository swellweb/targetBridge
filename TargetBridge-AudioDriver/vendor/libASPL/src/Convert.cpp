// Copyright (c) libASPL authors
// Licensed under MIT

#include "Convert.hpp"
#include "Strings.hpp"

#include <vector>

namespace aspl {

void Convert::ToFoundation(const std::string& value, CFStringRef& result)
{
    result = CFStringCreateWithCString(
        kCFAllocatorDefault, value.c_str(), kCFStringEncodingUTF8);
}

bool Convert::FromFoundation(CFStringRef value, std::string& result)
{
    if (!value) {
        result = {};
        return false;
    }

    CFIndex length = CFStringGetLength(value);
    CFIndex maxSize =
        CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;

    if (maxSize <= 0) {
        result = {};
        return false;
    }

    std::vector<char> buffer(size_t(maxSize) + 1);
    if (!CFStringGetCString(value, &buffer[0], maxSize, kCFStringEncodingUTF8)) {
        result = {};
        return false;
    }

    result.assign(&buffer[0]);
    return true;
}

void Convert::ToFoundation(const std::string& value, CFURLRef& result)
{
    result = CFURLCreateWithBytes(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(value.c_str()),
        CFIndex(value.size()),
        kCFStringEncodingUTF8,
        nullptr);
}

bool Convert::FromFoundation(CFURLRef value, std::string& result)
{
    CFStringRef stringValue = CFURLGetString(value);

    return FromFoundation(stringValue, result);
}

void Convert::ToFoundation(const std::vector<UInt8>& value, CFPropertyListRef& result)
{
    result = CFDataCreate(kCFAllocatorDefault, value.data(), value.size());
}

bool Convert::FromFoundation(CFPropertyListRef value, std::vector<UInt8>& result)
{
    if (CFGetTypeID(value) != CFDataGetTypeID()) {
        return false;
    }

    CFDataRef dataValue = (CFDataRef)value;

    const UInt8* bytes = CFDataGetBytePtr(dataValue);
    size_t numBytes = CFDataGetLength(dataValue);

    if (bytes && numBytes) {
        result.assign(bytes, bytes + numBytes);
    } else {
        result.clear();
    }

    return true;
}

void Convert::ToFoundation(const std::string& value, CFPropertyListRef& result)
{
    result = CFStringCreateWithCString(
        kCFAllocatorDefault, value.c_str(), kCFStringEncodingUTF8);
}

bool Convert::FromFoundation(CFPropertyListRef value, std::string& result)
{
    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        return false;
    }

    CFStringRef stringValue = (CFStringRef)value;

    return FromFoundation(stringValue, result);
}

void Convert::ToFoundation(bool value, CFPropertyListRef& result)
{
    result = CFPropertyListCreateDeepCopy(kCFAllocatorDefault,
        value ? kCFBooleanTrue : kCFBooleanFalse,
        kCFPropertyListImmutable);
}

bool Convert::FromFoundation(CFPropertyListRef value, bool& result)
{
    if (CFGetTypeID(value) != CFBooleanGetTypeID()) {
        return false;
    }

    CFBooleanRef booleanValue = (CFBooleanRef)value;

    result = CFBooleanGetValue(booleanValue);
    return true;
}

void Convert::ToFoundation(SInt64 value, CFPropertyListRef& result)
{
    result = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value);
}

bool Convert::FromFoundation(CFPropertyListRef value, SInt64& result)
{
    if (CFGetTypeID(value) != CFNumberGetTypeID()) {
        return false;
    }

    CFNumberRef numberValue = (CFNumberRef)value;

    if (!CFNumberGetValue(numberValue, kCFNumberSInt64Type, &result)) {
        result = 0;
        return false;
    }

    return true;
}

void Convert::ToFoundation(Float64 value, CFPropertyListRef& result)
{
    result = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &value);
}

bool Convert::FromFoundation(CFPropertyListRef value, Float64& result)
{
    if (CFGetTypeID(value) != CFNumberGetTypeID()) {
        return false;
    }

    CFNumberRef numberValue = (CFNumberRef)value;

    if (!CFNumberGetValue(numberValue, kCFNumberFloat64Type, &result)) {
        result = 0;
        return false;
    }

    return true;
}

std::string Convert::FormatValue(const AudioValueRange& value)
{
    std::ostringstream ss;

    ss << "{";
    ss << "min:" << value.mMinimum << " ";
    ss << "max:" << value.mMaximum;
    ss << "}";

    return ss.str();
}

std::string Convert::FormatValue(const AudioStreamBasicDescription& value)
{
    std::ostringstream ss;

    ss << "{";
    ss << "id:" << FormatIDToString(value.mFormatID) << " ";
    ss << "flags:" << FormatFlagsToString(value.mFormatFlags) << " ";
    ss << "rate:" << value.mSampleRate << " ";
    ss << "bits:" << value.mBitsPerChannel << " ";
    ss << "chans:" << value.mChannelsPerFrame << " ";
    ss << "pkt:" << value.mFramesPerPacket;
    ss << "}";

    return ss.str();
}

std::string Convert::FormatValue(const AudioStreamRangedDescription& value)
{
    std::ostringstream ss;

    ss << "{";
    ss << "id:" << FormatIDToString(value.mFormat.mFormatID) << " ";
    ss << "flags:" << FormatFlagsToString(value.mFormat.mFormatFlags) << " ";
    ss << "rate:" << value.mFormat.mSampleRate << " ";
    ss << "bits:" << value.mFormat.mBitsPerChannel << " ";
    ss << "chans:" << value.mFormat.mChannelsPerFrame << " ";
    ss << "pkt:" << value.mFormat.mFramesPerPacket << " ";
    ss << "minRate:" << value.mSampleRateRange.mMinimum << " ";
    ss << "maxRate:" << value.mSampleRateRange.mMaximum;
    ss << "}";

    return ss.str();
}

} // namespace aspl
