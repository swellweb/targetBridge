// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/Compat.hpp
//! @brief Compatibility definitions.

#pragma once

#include <CoreAudio/AudioServerPlugIn.h>

namespace aspl {

// Backward compatibility with macOS before 12.0
#if !defined(MAC_OS_VERSION_12_0) || MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_VERSION_12_0
enum
{
    kAudioObjectPropertyElementMain = kAudioObjectPropertyElementMaster
};
#endif

} // namespace aspl
