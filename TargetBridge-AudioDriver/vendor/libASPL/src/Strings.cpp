// Copyright (c) libASPL authors
// Licensed under MIT

#include "Strings.hpp"

#include <sstream>

namespace aspl {

std::string CodeToString(UInt32 value)
{
    const char* bytes = reinterpret_cast<const char*>(&value);

    std::stringstream ss;

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    ss << "'" << bytes[0] << bytes[1] << bytes[2] << bytes[3] << "'";
#else
    ss << "'" << bytes[3] << bytes[2] << bytes[1] << bytes[0] << "'";
#endif

    ss << " (0x" << std::hex << value << ")";

    return ss.str();
}

} // namespace aspl
