// ODataIncrementalStore — modern Objective-C runtime contract.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This library targets libobjc2 (the GNUstep modern runtime) or Apple's
// runtime. GCC's libobjc (fragile ABI, no ARC, no non-fragile ivars, no
// zeroing weak) is not a supported platform.
//
//   clang -fobjc-runtime=gnustep-2.0 -fobjc-arc -fblocks \
//         -fconstant-string-class=NSConstantString

#pragma once

#if !defined(__clang__)
#error "OIS requires clang. GCC's Objective-C compiler and libobjc are the old runtime."
#endif

#if !defined(__APPLE__) && !defined(__OBJC2__)
#error "OIS requires the modern Objective-C runtime (libobjc2). Compile with clang -fobjc-runtime=gnustep-2.0 -fobjc-arc -fblocks"
#endif

#if defined(__OBJC__) && !__has_feature(objc_arc)
#error "OIS requires ARC (-fobjc-arc). Manual retain/release is not supported."
#endif

#if defined(__OBJC__) && !__has_feature(blocks) && !__has_extension(blocks)
#error "OIS requires blocks (-fblocks). libobjc2 provides the block runtime."
#endif

#import <Foundation/Foundation.h>
#import <stdint.h>

#ifndef NSErrorDomain
typedef NSString *NSErrorDomain;
#endif

#ifndef NS_ENUM
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
#endif

#ifndef NS_ASSUME_NONNULL_BEGIN
#define NS_ASSUME_NONNULL_BEGIN
#define NS_ASSUME_NONNULL_END
#endif

#ifndef NS_DESIGNATED_INITIALIZER
#define NS_DESIGNATED_INITIALIZER
#endif

#ifndef NS_UNAVAILABLE
#define NS_UNAVAILABLE __attribute__((unavailable))
#endif
