// Copyright (c) libASPL authors
// Licensed under MIT

#include <aspl/Compat.hpp>
#include <aspl/MuteControl.hpp>

#include "Strings.hpp"

namespace aspl {

MuteControl::MuteControl(std::shared_ptr<const Context> context,
    const MuteControlParameters& params)
    : Object(std::move(context), "MuteControl")
    , params_(params)
{
}

AudioObjectPropertyScope MuteControl::GetScope() const
{
    return params_.Scope;
}

AudioObjectPropertyElement MuteControl::GetElement() const
{
    return kAudioObjectPropertyElementMain;
}

bool MuteControl::GetIsMuted() const
{
    return isMuted_;
}

OSStatus MuteControl::SetIsMutedImpl(bool isMuted)
{
    isMuted_ = isMuted;

    return kAudioHardwareNoError;
}

void MuteControl::ApplyProcessing(Float32* frames,
    UInt32 frameCount,
    UInt32 channelCount) const
{
    if (GetIsMuted()) {
        memset(frames, 0, sizeof(Float32) * frameCount * channelCount);
    }
}

} // namespace aspl
