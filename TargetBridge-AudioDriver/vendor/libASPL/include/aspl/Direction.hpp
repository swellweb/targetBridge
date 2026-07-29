// Copyright (c) libASPL authors
// Licensed under MIT

//! @file aspl/Direction.hpp
//! @brief I/O direction.

#pragma once

#include <CoreFoundation/CoreFoundation.h>

namespace aspl {

//! I/O direction.
enum class Direction : UInt32
{
    Output = 0, //!< Output direction.
    Input = 1, //!< Input direction.
};

} // namespace aspl
