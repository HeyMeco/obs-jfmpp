// For building OBS against Qt older than 6.7 (Ubuntu Noble has 6.4). build-obs.sh
// includes this at the top of every OBS source file that calls
// QMetaObject::invokeMethod, and points those calls at ObsQtCompat::invokeMethod.
//
// Qt 6.7 added invokeMethod(object, &Class::method, [type,] args...); OBS 33 uses it
// all over. Older Qt only takes a functor, so the call and its arguments are wrapped
// in one. Everything older Qt does support is passed through unchanged.
#pragma once

// Also included by files that some targets compile without Qt (obs-browser's CEF helper).
#if __has_include(<QMetaObject>)
#include <QMetaObject>
#include <QObject>

#include <tuple>
#include <type_traits>
#include <utility>

namespace ObsQtCompat {
namespace detail {
template<typename Void, typename... Args> struct QtAccepts : std::false_type {};
template<typename... Args>
struct QtAccepts<std::void_t<decltype(QMetaObject::invokeMethod(std::declval<Args>()...))>, Args...>
	: std::true_type {};

template<typename Obj, typename Fn, typename... Args>
constexpr bool needsWrapper = std::is_member_function_pointer_v<Fn> &&
			      std::is_invocable_v<Fn, Obj, const std::decay_t<Args> &...>;
} // namespace detail

template<typename... Args, std::enable_if_t<detail::QtAccepts<void, Args...>::value, int> = 0>
bool invokeMethod(Args &&...args)
{
	return QMetaObject::invokeMethod(std::forward<Args>(args)...);
}

template<typename Obj, typename Fn, typename... Args,
	 std::enable_if_t<!detail::QtAccepts<void, Obj, Fn, Qt::ConnectionType, Args...>::value &&
				  detail::needsWrapper<Obj, Fn, Args...>,
			  int> = 0>
bool invokeMethod(Obj obj, Fn fn, Qt::ConnectionType type, Args &&...args)
{
	// Copies of the arguments, like Qt makes for a queued call.
	auto call = [obj, fn, saved = std::make_tuple(std::decay_t<Args>(std::forward<Args>(args))...)]() {
		std::apply([&](const auto &...a) { (obj->*fn)(a...); }, saved);
	};
	return QMetaObject::invokeMethod(obj, std::move(call), type);
}

template<typename Obj, typename Fn, typename Arg, typename... Args,
	 std::enable_if_t<!std::is_same_v<std::decay_t<Arg>, Qt::ConnectionType> &&
				  !detail::QtAccepts<void, Obj, Fn, Arg, Args...>::value &&
				  detail::needsWrapper<Obj, Fn, Arg, Args...>,
			  int> = 0>
bool invokeMethod(Obj obj, Fn fn, Arg &&arg, Args &&...args)
{
	return invokeMethod(obj, fn, Qt::AutoConnection, std::forward<Arg>(arg), std::forward<Args>(args)...);
}
} // namespace ObsQtCompat
#endif
