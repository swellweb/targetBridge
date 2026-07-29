// Copyright (c) libASPL authors
// Licensed under MIT

#pragma once

#include <CoreAudio/AudioServerPlugIn.h>

inline bool operator==(const AudioValueRange& a, const AudioValueRange& b)
{
    return a.mMinimum == b.mMinimum && a.mMaximum == b.mMaximum;
}

inline bool operator!=(const AudioValueRange& a, const AudioValueRange& b)
{
    return !(a == b);
}

inline bool operator==(const AudioChannelDescription& a, const AudioChannelDescription& b)
{
    return a.mChannelLabel == b.mChannelLabel && a.mChannelFlags == b.mChannelFlags &&
           a.mCoordinates[0] == b.mCoordinates[0] &&
           a.mCoordinates[1] == b.mCoordinates[2] &&
           a.mCoordinates[1] == b.mCoordinates[2];
}

inline bool operator!=(const AudioChannelDescription& a, const AudioChannelDescription& b)
{
    return !(a == b);
}

inline bool operator==(const AudioStreamBasicDescription& a,
    const AudioStreamBasicDescription& b)
{
    return a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID &&
           a.mFormatFlags == b.mFormatFlags && a.mBitsPerChannel == b.mBitsPerChannel &&
           a.mChannelsPerFrame == b.mChannelsPerFrame &&
           a.mBytesPerFrame == b.mBytesPerFrame &&
           a.mFramesPerPacket == b.mFramesPerPacket &&
           a.mBytesPerPacket == b.mBytesPerPacket;
}

inline bool operator!=(const AudioStreamBasicDescription& a,
    const AudioStreamBasicDescription& b)
{
    return !(a == b);
}

inline bool operator==(const AudioStreamRangedDescription& a,
    const AudioStreamRangedDescription& b)
{
    return a.mFormat == b.mFormat && a.mSampleRateRange == b.mSampleRateRange;
}

inline bool operator!=(const AudioStreamRangedDescription& a,
    const AudioStreamRangedDescription& b)
{
    return !(a == b);
}
