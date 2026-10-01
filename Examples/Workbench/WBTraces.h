// The traces of what the Workbench does, kept in memory and shown: each
// fetch and save of the store, the requests they send, and (at the built-in
// service) its planning and store requests, one tree per trace.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <AppKit/AppKit.h>
#import <OTelKit/OTelKit.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main thread when traces have come or gone (at most a few
// times a second).
FOUNDATION_EXPORT NSString * const WBTracesDidChangeNotification;

// One trace: its spans, as they ended.
@interface WBTrace : NSObject
@property (nonatomic, readonly, copy) NSString *traceID;
@property (nonatomic, readonly, copy) NSArray<OTSpan *> *spans;
// The earliest span with no parent in the trace (the work that began it).
@property (nonatomic, readonly, nullable) OTSpan *root;
@property (nonatomic, readonly) uint64_t startTime;
@property (nonatomic, readonly) uint64_t endTime;
@end

// Spans kept by trace, the last `limit` traces (default 200).
@interface WBTraceRecorder : NSObject <OTSpanExporter>
@property (nonatomic) NSUInteger limit;
// Newest first.
@property (nonatomic, readonly, copy) NSArray<WBTrace *> *traces;
- (nullable WBTrace *)traceWithID:(NSString *)traceID;
- (void)clear;
@end

// The process's tracing, as the Workbench has it: every span recorded and
// kept (the recorder); and sent to a collector too when the environment
// names one (OTEL_EXPORTER_OTLP_ENDPOINT, as ois-serve reads it).
FOUNDATION_EXPORT OTTracerProvider *WBTracerProvider(WBTraceRecorder *recorder);

// The trace an exchange is part of, by its request's traceparent; and the
// span that sent it.
FOUNDATION_EXPORT NSString *_Nullable WBTraceIDOfHeaders(NSDictionary<NSString *, NSString *> *_Nullable headers);
FOUNDATION_EXPORT NSString *_Nullable WBSpanIDOfHeaders(NSDictionary<NSString *, NSString *> *_Nullable headers);

// The window: the traces at the left, newest first; the selected one's
// spans as a tree, when each began after the trace did and how long it
// took; under them, the selected span's attributes and events (the plan's
// tree among them).
@interface WBTraceWindow : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate>
- (instancetype)initWithRecorder:(WBTraceRecorder *)recorder NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) NSWindow *window;
@property (nonatomic, readonly) NSTableView *traceTable;
@property (nonatomic, readonly) NSOutlineView *spanOutline;
@property (nonatomic, readonly) NSTextView *detailView;
- (void)show;
// That trace selected, all of it expanded, and the span chosen when given
// (the one that sent an exchange); the window brought out, not made key.
// NO when the trace is not (or no longer) kept.
- (BOOL)showTraceWithID:(NSString *)traceID spanID:(nullable NSString *)spanID;
@end

NS_ASSUME_NONNULL_END
