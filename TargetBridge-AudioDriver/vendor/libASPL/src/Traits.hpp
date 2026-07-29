// Copyright (c) libASPL authors
// Licensed under MIT

#pragma once

#include <tuple>
#include <type_traits>
#include <vector>

namespace aspl {

template <typename T>
struct is_vector : public std::false_type
{
};

template <typename T, typename A>
struct is_vector<std::vector<T, A>> : public std::true_type
{
};

template <typename Func>
class method_return_type
{
    template <typename Class, typename Return, typename... Args>
    static Return return_of(Return (Class::*)(Args...));

    template <typename Class, typename Return, typename... Args>
    static Return return_of(Return (Class::*)(Args...) const);

    template <typename Class, typename Return, typename... Args>
    static Return return_of(Return (Class::*)(Args...) const volatile);

public:
    using type = std::remove_cv_t<
        std::remove_reference_t<decltype(return_of(std::declval<Func>()))>>;
};

template <typename Method>
using method_return_type_t = typename method_return_type<Method>::type;

template <typename Func, size_t ArgIndex>
class method_argument_type
{
    template <typename... Args>
    using nth_argument_t =
        typename std::tuple_element<ArgIndex, std::tuple<Args...>>::type;

    template <typename Class, typename Return, typename... Args>
    static nth_argument_t<Args...> nth_argument_of(Return (Class::*)(Args...));

    template <typename Class, typename Return, typename... Args>
    static nth_argument_t<Args...> nth_argument_of(Return (Class::*)(Args...) const);

    template <typename Class, typename Return, typename... Args>
    static nth_argument_t<Args...> nth_argument_of(
        Return (Class::*)(Args...) const volatile);

public:
    using type = std::remove_cv_t<
        std::remove_reference_t<decltype(nth_argument_of(std::declval<Func>()))>>;
};

template <typename Method, size_t ArgIndex>
using method_argument_type_t = typename method_argument_type<Method, ArgIndex>::type;

} // namespace aspl
