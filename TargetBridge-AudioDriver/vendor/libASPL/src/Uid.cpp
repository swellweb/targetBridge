// Copyright (c) libASPL authors
// Licensed under MIT

#include "Uid.hpp"

#include <random>

namespace aspl {

std::string GenerateUID()
{
    constexpr int numDigits = 16;
    constexpr int numGroups = 4;

    const char* digits = "0123456789abcdef";

    static thread_local std::random_device device;
    static thread_local std::mt19937 rng(device());

    std::uniform_int_distribution<int> dist(0, numDigits - 1);

    std::string res;

    for (int g = 0; g < numGroups; g++) {
        if (g != 0) {
            res += "-";
        }
        for (int n = 0; n < numDigits / numGroups; n++) {
            res += digits[dist(rng)];
        }
    }

    return res;
}

} // namespace aspl
