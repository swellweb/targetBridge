// Copyright (c) libASPL authors
// Licensed under MIT

// Copyright (c) 2020 Apple Inc.
// Extracted from BuildingAnAudioServerPlugInAndDriverExtension example

#pragma once

#include <CoreFoundation/CoreFoundation.h>

namespace aspl {

struct VolumeDecibelPoint
{
    Float32 mMinimum;
    Float32 mMaximum;

    VolumeDecibelPoint()
        : mMinimum(0)
        , mMaximum(0)
    {
    }

    VolumeDecibelPoint(const VolumeDecibelPoint& inPoint)
        : mMinimum(inPoint.mMinimum)
        , mMaximum(inPoint.mMaximum)
    {
    }

    VolumeDecibelPoint(Float32 inMinimum, Float32 inMaximum)
        : mMinimum(inMinimum)
        , mMaximum(inMaximum)
    {
    }

    VolumeDecibelPoint& operator=(const VolumeDecibelPoint& inPoint)
    {
        mMinimum = inPoint.mMinimum;
        mMaximum = inPoint.mMaximum;
        return *this;
    }

    static bool Overlap(const VolumeDecibelPoint& x, const VolumeDecibelPoint& y)
    {
        return (x.mMinimum < y.mMaximum) && (x.mMaximum >= y.mMinimum);
    }
};

inline bool operator<(const VolumeDecibelPoint& x, const VolumeDecibelPoint& y)
{
    return x.mMinimum < y.mMinimum;
}

inline bool operator==(const VolumeDecibelPoint& x, const VolumeDecibelPoint& y)
{
    return (x.mMinimum == y.mMinimum) && (x.mMaximum == y.mMaximum);
}

inline bool operator!=(const VolumeDecibelPoint& x, const VolumeDecibelPoint& y)
{
    return !(x == y);
}

inline bool operator<=(const VolumeDecibelPoint& x, const VolumeDecibelPoint& y)
{
    return (x < y) || (x == y);
}

inline bool operator>=(const VolumeDecibelPoint& x, const VolumeDecibelPoint& y)
{
    return !(x < y);
}

inline bool operator>(const VolumeDecibelPoint& x, const VolumeDecibelPoint& y)
{
    return !((x < y) || (x == y));
}

} // namespace aspl
