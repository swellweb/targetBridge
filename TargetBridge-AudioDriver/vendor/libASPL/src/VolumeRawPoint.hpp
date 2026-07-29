// Copyright (c) libASPL authors
// Licensed under MIT

// Copyright (c) 2020 Apple Inc.
// Extracted from BuildingAnAudioServerPlugInAndDriverExtension example

#pragma once

#include <CoreFoundation/CoreFoundation.h>

namespace aspl {

struct VolumeRawPoint
{
    SInt32 mMinimum;
    SInt32 mMaximum;

    VolumeRawPoint()
        : mMinimum(0)
        , mMaximum(0)
    {
    }

    VolumeRawPoint(const VolumeRawPoint& inPoint)
        : mMinimum(inPoint.mMinimum)
        , mMaximum(inPoint.mMaximum)
    {
    }

    VolumeRawPoint(SInt32 inMinimum, SInt32 inMaximum)
        : mMinimum(inMinimum)
        , mMaximum(inMaximum)
    {
    }

    VolumeRawPoint& operator=(const VolumeRawPoint& inPoint)
    {
        mMinimum = inPoint.mMinimum;
        mMaximum = inPoint.mMaximum;
        return *this;
    }

    static bool Overlap(const VolumeRawPoint& x, const VolumeRawPoint& y)
    {
        return (x.mMinimum < y.mMaximum) && (x.mMaximum > y.mMinimum);
    }
};

inline bool operator<(const VolumeRawPoint& x, const VolumeRawPoint& y)
{
    return x.mMinimum < y.mMinimum;
}

inline bool operator==(const VolumeRawPoint& x, const VolumeRawPoint& y)
{
    return (x.mMinimum == y.mMinimum) && (x.mMaximum == y.mMaximum);
}

inline bool operator!=(const VolumeRawPoint& x, const VolumeRawPoint& y)
{
    return !(x == y);
}

inline bool operator<=(const VolumeRawPoint& x, const VolumeRawPoint& y)
{
    return (x < y) || (x == y);
}

inline bool operator>=(const VolumeRawPoint& x, const VolumeRawPoint& y)
{
    return !(x < y);
}

inline bool operator>(const VolumeRawPoint& x, const VolumeRawPoint& y)
{
    return !((x < y) || (x == y));
}

} // namespace aspl
