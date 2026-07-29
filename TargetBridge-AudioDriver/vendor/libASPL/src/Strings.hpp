// Copyright (c) libASPL authors
// Licensed under MIT

#pragma once

#include <CoreAudio/AudioServerPlugIn.h>

#include <string>

namespace aspl {

std::string ClassIDToString(AudioClassID classID);

std::string PropertySelectorToString(AudioObjectPropertySelector selector);
std::string PropertyScopeToString(AudioObjectPropertyScope scope);

std::string OperationIDToString(UInt32 operationID);

std::string StatusToString(OSStatus status);

std::string FormatIDToString(AudioFormatID formatID);
std::string FormatFlagsToString(AudioFormatFlags formatFlags);

std::string CodeToString(UInt32 value);

} // namespace aspl
