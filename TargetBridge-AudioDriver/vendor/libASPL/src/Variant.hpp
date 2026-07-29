// Copyright (c) libASPL authors
// Licensed under MIT

#pragma once

#include <memory>
#include <variant>

// Gets std::variant with shared_ptr and raw pointer and returns raw pointer.
template <class T>
T* GetVariantPtr(const std::variant<std::shared_ptr<T>, T*>& variant)
{
    return variant.index() == 0
               // shared_ptr
               ? std::get<0>(variant).get()
               // raw ptr
               : std::get<1>(variant);
}
