/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "ABI46_0_0RCTProfile.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>

#import <UIKit/UIKit.h>

#import "ABI46_0_0RCTAssert.h"
#import "ABI46_0_0RCTBridge+Private.h"
#import "ABI46_0_0RCTBridge.h"
#import "ABI46_0_0RCTComponentData.h"
#import "ABI46_0_0RCTDefines.h"
#import "ABI46_0_0RCTLog.h"
#import "ABI46_0_0RCTModuleData.h"
#import "ABI46_0_0RCTReloadCommand.h"
#import "ABI46_0_0RCTUIManager.h"
#import "ABI46_0_0RCTUIManagerUtils.h"
#import "ABI46_0_0RCTUtils.h"

NSString *const ABI46_0_0RCTProfileDidStartProfiling = @"ABI46_0_0RCTProfileDidStartProfiling";
NSString *const ABI46_0_0RCTProfileDidEndProfiling = @"ABI46_0_0RCTProfileDidEndProfiling";

const uint64_t ABI46_0_0RCTProfileTagAlways = 1L << 0;

#if ABI46_0_0RCT_PROFILE

#pragma mark - Constants

static NSString *const kProfileTraceEvents = @"traceEvents";
static NSString *const kProfileSamples = @"samples";
static NSString *const kProfilePrefix = @"rct_profile_";

#pragma mark - Variables

static atomic_bool ABI46_0_0RCTProfileProfiling = ATOMIC_VAR_INIT(NO);

static NSDictionary *ABI46_0_0RCTProfileInfo;
static NSMutableDictionary *ABI46_0_0RCTProfileOngoingEvents;
static NSTimeInterval ABI46_0_0RCTProfileStartTime;
static NSUInteger ABI46_0_0RCTProfileEventID = 0;
static CADisplayLink *ABI46_0_0RCTProfileDisplayLink;
static __weak ABI46_0_0RCTBridge *_ABI46_0_0RCTProfilingBridge;
static UIWindow *ABI46_0_0RCTProfileControlsWindow;

#pragma mark - Macros

#define ABI46_0_0RCTProfileAddEvent(type, props...) \
  [ABI46_0_0RCTProfileInfo[type] addObject:@{@"pid" : @([[NSProcessInfo processInfo] processIdentifier]), props}];

#define CHECK(...)                \
  if (!ABI46_0_0RCTProfileIsProfiling()) { \
    return __VA_ARGS__;           \
  }

#pragma mark - systrace glue code

static ABI46_0_0RCTProfileCallbacks *callbacks;
static char *systrace_buffer;

static systrace_arg_t *newSystraceArgsFromDictionary(NSDictionary<NSString *, NSString *> *args)
{
  if (args.count == 0) {
    return NULL;
  }

  systrace_arg_t *systrace_args = malloc(sizeof(systrace_arg_t) * args.count);
  if (systrace_args) {
    __block size_t i = 0;
    [args enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
      systrace_args[i].key = [key UTF8String];
      systrace_args[i].key_len = [key length];
      systrace_args[i].value = [value UTF8String];
      systrace_args[i].value_len = [value length];
      i++;
    }];
  }
  return systrace_args;
}

void ABI46_0_0RCTProfileRegisterCallbacks(ABI46_0_0RCTProfileCallbacks *cb)
{
  callbacks = cb;
}

#pragma mark - Private Helpers

static ABI46_0_0RCTBridge *ABI46_0_0RCTProfilingBridge(void)
{
  return _ABI46_0_0RCTProfilingBridge ?: [ABI46_0_0RCTBridge currentBridge];
}

static NSNumber *ABI46_0_0RCTProfileTimestamp(NSTimeInterval timestamp)
{
  return @((timestamp - ABI46_0_0RCTProfileStartTime) * 1e6);
}

static NSString *ABI46_0_0RCTProfileMemory(vm_size_t memory)
{
  double mem = ((double)memory) / 1024 / 1024;
  return [NSString stringWithFormat:@"%.2lfmb", mem];
}

static NSDictionary *ABI46_0_0RCTProfileGetMemoryUsage(void)
{
  struct task_basic_info info;
  mach_msg_type_number_t size = sizeof(info);
  kern_return_t kerr = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &size);
  if (kerr == KERN_SUCCESS) {
    return @{
      @"suspend_count" : @(info.suspend_count),
      @"virtual_size" : ABI46_0_0RCTProfileMemory(info.virtual_size),
      @"resident_size" : ABI46_0_0RCTProfileMemory(info.resident_size),
    };
  } else {
    return @{};
  }
}

#pragma mark - Module hooks

static const char *ABI46_0_0RCTProfileProxyClassName(Class class)
{
  return [kProfilePrefix stringByAppendingString:NSStringFromClass(class)].UTF8String;
}

static dispatch_group_t ABI46_0_0RCTProfileGetUnhookGroup(void)
{
  static dispatch_group_t unhookGroup;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    unhookGroup = dispatch_group_create();
  });

  return unhookGroup;
}

// Used by ABI46_0_0RCTProfileTrampoline assembly file to call libc`malloc
ABI46_0_0RCT_EXTERN void *ABI46_0_0RCTProfileMalloc(size_t size);
void *ABI46_0_0RCTProfileMalloc(size_t size)
{
  return malloc(size);
}

// Used by ABI46_0_0RCTProfileTrampoline assembly file to call libc`free
ABI46_0_0RCT_EXTERN void ABI46_0_0RCTProfileFree(void *buf);
void ABI46_0_0RCTProfileFree(void *buf)
{
  free(buf);
}

ABI46_0_0RCT_EXTERN IMP ABI46_0_0RCTProfileGetImplementation(id obj, SEL cmd);
IMP ABI46_0_0RCTProfileGetImplementation(id obj, SEL cmd)
{
  return class_getMethodImplementation([obj class], cmd);
}

/**
 * For the profiling we have to execute some code before and after every
 * function being profiled, the only way of doing that with pure Objective-C is
 * by using `-forwardInvocation:`, which is slow and could skew the profile
 * results.
 *
 * The alternative in assembly is much simpler, we just need to store all the
 * state at the beginning of the function, start the profiler, restore all the
 * state, call the actual function we want to profile and stop the profiler.
 *
 * The implementation can be found in ABI46_0_0RCTProfileTrampoline-<arch>.s where arch
 * is one of: i386, x86_64, arm, arm64.
 */
#if defined(__i386__) || defined(__x86_64__) || defined(__arm__) || defined(__arm64__)

ABI46_0_0RCT_EXTERN void ABI46_0_0RCTProfileTrampoline(void);
#else
static void *ABI46_0_0RCTProfileTrampoline = NULL;
#endif

ABI46_0_0RCT_EXTERN void ABI46_0_0RCTProfileTrampolineStart(id, SEL);
void ABI46_0_0RCTProfileTrampolineStart(id self, SEL cmd)
{
  /**
   * This call might be during dealloc, so we shouldn't retain the object in the
   * block.
   */
  Class klass = [self class];
  ABI46_0_0RCT_PROFILE_BEGIN_EVENT(
      ABI46_0_0RCTProfileTagAlways, ([NSString stringWithFormat:@"-[%s %s]", class_getName(klass), sel_getName(cmd)]), nil);
}

ABI46_0_0RCT_EXTERN void ABI46_0_0RCTProfileTrampolineEnd(void);
void ABI46_0_0RCTProfileTrampolineEnd(void)
{
  ABI46_0_0RCT_PROFILE_END_EVENT(ABI46_0_0RCTProfileTagAlways, @"objc_call,modules,auto");
}

static UIView *(*originalCreateView)(ABI46_0_0RCTComponentData *, SEL, NSNumber *, NSNumber *);
static UIView *ABI46_0_0RCTProfileCreateView(ABI46_0_0RCTComponentData *self, SEL _cmd, NSNumber *tag, NSNumber *rootTag)
{
  UIView *view = originalCreateView(self, _cmd, tag, rootTag);
  ABI46_0_0RCTProfileHookInstance(view);
  return view;
}

static void ABI46_0_0RCTProfileHookUIManager(ABI46_0_0RCTUIManager *uiManager)
{
  dispatch_async(dispatch_get_main_queue(), ^{
    for (id view in [uiManager valueForKey:@"viewRegistry"]) {
      ABI46_0_0RCTProfileHookInstance([uiManager viewForABI46_0_0ReactTag:view]);
    }

    Method createView = class_getInstanceMethod([ABI46_0_0RCTComponentData class], @selector(createViewWithTag:rootTag:));

    if (method_getImplementation(createView) != (IMP)ABI46_0_0RCTProfileCreateView) {
      originalCreateView = (typeof(originalCreateView))method_getImplementation(createView);
      method_setImplementation(createView, (IMP)ABI46_0_0RCTProfileCreateView);
    }
  });
}

void ABI46_0_0RCTProfileHookInstance(id instance)
{
  Class moduleClass = object_getClass(instance);

  /**
   * We swizzle the instance -class method to return the original class, but
   * object_getClass will return the actual class.
   *
   * If they are different, it means that the object is returning the original
   * class, but it's actual class is the proxy subclass we created.
   */
  if ([instance class] != moduleClass) {
    return;
  }

  Class proxyClass = objc_allocateClassPair(moduleClass, ABI46_0_0RCTProfileProxyClassName(moduleClass), 0);

  if (!proxyClass) {
    proxyClass = objc_getClass(ABI46_0_0RCTProfileProxyClassName(moduleClass));
    if (proxyClass) {
      object_setClass(instance, proxyClass);
    }
    return;
  }

  unsigned int methodCount;
  Method *methods = class_copyMethodList(moduleClass, &methodCount);
  for (NSUInteger i = 0; i < methodCount; i++) {
    Method method = methods[i];
    SEL selector = method_getName(method);

    /**
     * Bail out on struct returns (except arm64) - we don't use it enough
     * to justify writing a stret version
     */
#ifdef __arm64__
    BOOL returnsStruct = NO;
#else
    const char *typeEncoding = method_getTypeEncoding(method);
    // bail out on structs and unions (since they might contain structs)
    BOOL returnsStruct = typeEncoding[0] == '{' || typeEncoding[0] == '(';
#endif

    /**
     * Avoid hooking into NSObject methods, methods generated by ABI46_0_0React Native
     * and special methods that start `.` (e.g. .cxx_destruct)
     */
    if ([NSStringFromSelector(selector) hasPrefix:@"rct"] || [NSObject instancesRespondToSelector:selector] ||
        sel_getName(selector)[0] == '.' || returnsStruct) {
      continue;
    }

    const char *types = method_getTypeEncoding(method);
    class_addMethod(proxyClass, selector, (IMP)ABI46_0_0RCTProfileTrampoline, types);
  }
  free(methods);

  class_replaceMethod(
      object_getClass(proxyClass),
      @selector(initialize),
      imp_implementationWithBlock(^{
      }),
      "v@:");

  for (Class cls in @[ proxyClass, object_getClass(proxyClass) ]) {
    Method oldImp = class_getInstanceMethod(cls, @selector(class));
    class_replaceMethod(
        cls,
        @selector(class),
        imp_implementationWithBlock(^{
          return moduleClass;
        }),
        method_getTypeEncoding(oldImp));
  }

  objc_registerClassPair(proxyClass);
  object_setClass(instance, proxyClass);

  if (moduleClass == [ABI46_0_0RCTUIManager class]) {
    ABI46_0_0RCTProfileHookUIManager((ABI46_0_0RCTUIManager *)instance);
  }
}

void ABI46_0_0RCTProfileHookModules(ABI46_0_0RCTBridge *bridge)
{
  _ABI46_0_0RCTProfilingBridge = bridge;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wtautological-pointer-compare"
  if (ABI46_0_0RCTProfileTrampoline == NULL) {
    return;
  }
#pragma clang diagnostic pop

  ABI46_0_0RCT_PROFILE_BEGIN_EVENT(ABI46_0_0RCTProfileTagAlways, @"ABI46_0_0RCTProfileHookModules", nil);
  for (ABI46_0_0RCTModuleData *moduleData in [bridge valueForKey:@"moduleDataByID"]) {
    // Only hook modules with an instance, to prevent initializing everything
    if ([moduleData hasInstance]) {
      [bridge
          dispatchBlock:^{
            ABI46_0_0RCTProfileHookInstance(moduleData.instance);
          }
                  queue:moduleData.methodQueue];
    }
  }
  ABI46_0_0RCT_PROFILE_END_EVENT(ABI46_0_0RCTProfileTagAlways, @"");
}

static void ABI46_0_0RCTProfileUnhookInstance(id instance)
{
  if ([instance class] != object_getClass(instance)) {
    object_setClass(instance, [instance class]);
  }
}

void ABI46_0_0RCTProfileUnhookModules(ABI46_0_0RCTBridge *bridge)
{
  _ABI46_0_0RCTProfilingBridge = nil;

  dispatch_group_enter(ABI46_0_0RCTProfileGetUnhookGroup());

  NSDictionary *moduleDataByID = [bridge valueForKey:@"moduleDataByID"];
  for (ABI46_0_0RCTModuleData *moduleData in moduleDataByID) {
    if ([moduleData hasInstance]) {
      ABI46_0_0RCTProfileUnhookInstance(moduleData.instance);
    }
  }

  if ([bridge moduleIsInitialized:[ABI46_0_0RCTUIManager class]]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      for (id view in [bridge.uiManager valueForKey:@"viewRegistry"]) {
        ABI46_0_0RCTProfileUnhookInstance([bridge.uiManager viewForABI46_0_0ReactTag:view]);
      }

      dispatch_group_leave(ABI46_0_0RCTProfileGetUnhookGroup());
    });
  }
}

#pragma mark - Private ObjC class only used for the vSYNC CADisplayLink target

@interface ABI46_0_0RCTProfile : NSObject
@end

@implementation ABI46_0_0RCTProfile

+ (void)vsync:(CADisplayLink *)displayLink
{
  ABI46_0_0RCTProfileImmediateEvent(ABI46_0_0RCTProfileTagAlways, @"VSYNC", displayLink.timestamp, 'g');
}

+ (void)reload
{
  ABI46_0_0RCTTriggerReloadCommandListeners(@"Profiling controls");
}

+ (void)toggle:(UIButton *)target
{
  BOOL isProfiling = ABI46_0_0RCTProfileIsProfiling();

  // Start and Stop are switched here, since we're going to toggle isProfiling
  [target setTitle:isProfiling ? @"Start" : @"Stop" forState:UIControlStateNormal];

  if (isProfiling) {
    ABI46_0_0RCTProfileEnd(ABI46_0_0RCTProfilingBridge(), ^(NSString *result) {
      NSString *outFile = [NSTemporaryDirectory() stringByAppendingString:@"tmp_trace.json"];
      [result writeToFile:outFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
      UIActivityViewController *activityViewController =
          [[UIActivityViewController alloc] initWithActivityItems:@[ [NSURL fileURLWithPath:outFile] ]
                                            applicationActivities:nil];
      activityViewController.completionWithItemsHandler =
          ^(__unused UIActivityType activityType,
            __unused BOOL completed,
            __unused NSArray *items,
            __unused NSError *error) {
            ABI46_0_0RCTProfileControlsWindow.hidden = NO;
          };
      ABI46_0_0RCTProfileControlsWindow.hidden = YES;
      dispatch_async(dispatch_get_main_queue(), ^{
        [[[[ABI46_0_0RCTSharedApplication() delegate] window] rootViewController] presentViewController:activityViewController
                                                                                      animated:YES
                                                                                    completion:nil];
      });
    });
  } else {
    ABI46_0_0RCTProfileInit(ABI46_0_0RCTProfilingBridge());
  }
}

+ (void)drag:(UIPanGestureRecognizer *)gestureRecognizer
{
  CGPoint translation = [gestureRecognizer translationInView:ABI46_0_0RCTProfileControlsWindow];
  ABI46_0_0RCTProfileControlsWindow.center =
      CGPointMake(ABI46_0_0RCTProfileControlsWindow.center.x + translation.x, ABI46_0_0RCTProfileControlsWindow.center.y + translation.y);
  [gestureRecognizer setTranslation:CGPointMake(0, 0) inView:ABI46_0_0RCTProfileControlsWindow];
}

@end

#pragma mark - Public Functions

dispatch_queue_t ABI46_0_0RCTProfileGetQueue(void)
{
  static dispatch_queue_t queue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    queue = dispatch_queue_create("com.facebook.ABI46_0_0React.Profiler", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

BOOL ABI46_0_0RCTProfileIsProfiling(void)
{
  return atomic_load(&ABI46_0_0RCTProfileProfiling);
}

void ABI46_0_0RCTProfileInit(ABI46_0_0RCTBridge *bridge)
{
  // TODO: enable assert JS thread from any file (and assert here)
  BOOL wasProfiling = atomic_fetch_or(&ABI46_0_0RCTProfileProfiling, 1);
  if (wasProfiling) {
    return;
  }

  if (callbacks != NULL) {
    systrace_buffer = callbacks->start();
  } else {
    NSTimeInterval time = CACurrentMediaTime();
    dispatch_async(ABI46_0_0RCTProfileGetQueue(), ^{
      ABI46_0_0RCTProfileStartTime = time;
      ABI46_0_0RCTProfileOngoingEvents = [NSMutableDictionary new];
      ABI46_0_0RCTProfileInfo = @{
        kProfileTraceEvents : [NSMutableArray new],
        kProfileSamples : [NSMutableArray new],
      };
    });
  }

  // Set up thread ordering
  dispatch_async(ABI46_0_0RCTProfileGetQueue(), ^{
    NSArray *orderedThreads =
        @[ @"JS async", @"ABI46_0_0RCTPerformanceLogger", @"com.facebook.ABI46_0_0React.JavaScript", @(ABI46_0_0RCTUIManagerQueueName), @"main" ];
    [orderedThreads enumerateObjectsUsingBlock:^(NSString *thread, NSUInteger idx, __unused BOOL *stop) {
      ABI46_0_0RCTProfileAddEvent(
          kProfileTraceEvents,
          @"ph"
          : @"M", // metadata event
            @"name"
          : @"thread_sort_index", @"tid"
          : thread, @"args"
          :
          @{@"sort_index" : @(-1000 + (NSInteger)idx)});
    }];
  });

  ABI46_0_0RCTProfileHookModules(bridge);

  ABI46_0_0RCTProfileDisplayLink = [CADisplayLink displayLinkWithTarget:[ABI46_0_0RCTProfile class] selector:@selector(vsync:)];
  [ABI46_0_0RCTProfileDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

  [[NSNotificationCenter defaultCenter] postNotificationName:ABI46_0_0RCTProfileDidStartProfiling object:bridge];
}

void ABI46_0_0RCTProfileEnd(ABI46_0_0RCTBridge *bridge, void (^callback)(NSString *))
{
  // assert JavaScript thread here again
  BOOL wasProfiling = atomic_fetch_and(&ABI46_0_0RCTProfileProfiling, 0);
  if (!wasProfiling) {
    return;
  }

  [[NSNotificationCenter defaultCenter] postNotificationName:ABI46_0_0RCTProfileDidEndProfiling object:bridge];

  [ABI46_0_0RCTProfileDisplayLink invalidate];
  ABI46_0_0RCTProfileDisplayLink = nil;

  ABI46_0_0RCTProfileUnhookModules(bridge);

  if (callbacks != NULL) {
    if (systrace_buffer) {
      callbacks->stop();
      callback(@(systrace_buffer));
    }
  } else {
    dispatch_async(ABI46_0_0RCTProfileGetQueue(), ^{
      NSString *log = ABI46_0_0RCTJSONStringify(ABI46_0_0RCTProfileInfo, NULL);
      ABI46_0_0RCTProfileEventID = 0;
      ABI46_0_0RCTProfileInfo = nil;
      ABI46_0_0RCTProfileOngoingEvents = nil;

      callback(log);
    });
  }
}

static NSMutableArray<NSArray *> *ABI46_0_0RCTProfileGetThreadEvents(NSThread *thread)
{
  static NSString *const ABI46_0_0RCTProfileThreadEventsKey = @"ABI46_0_0RCTProfileThreadEventsKey";
  NSMutableArray<NSArray *> *threadEvents = thread.threadDictionary[ABI46_0_0RCTProfileThreadEventsKey];
  if (!threadEvents) {
    threadEvents = [NSMutableArray new];
    thread.threadDictionary[ABI46_0_0RCTProfileThreadEventsKey] = threadEvents;
  }
  return threadEvents;
}

void _ABI46_0_0RCTProfileBeginEvent(
    NSThread *calleeThread,
    NSTimeInterval time,
    uint64_t tag,
    NSString *name,
    NSDictionary<NSString *, NSString *> *args)
{
  CHECK();

  if (callbacks != NULL) {
    systrace_arg_t *systraceArgs = newSystraceArgsFromDictionary(args);
    callbacks->begin_section(tag, name.UTF8String, args.count, systraceArgs);
    free(systraceArgs);
    return;
  }

  dispatch_async(ABI46_0_0RCTProfileGetQueue(), ^{
    NSMutableArray *events = ABI46_0_0RCTProfileGetThreadEvents(calleeThread);
    [events addObject:@[
      ABI46_0_0RCTProfileTimestamp(time),
      name,
      ABI46_0_0RCTNullIfNil(args),
    ]];
  });
}

void _ABI46_0_0RCTProfileEndEvent(
    NSThread *calleeThread,
    NSString *threadName,
    NSTimeInterval time,
    uint64_t tag,
    NSString *category)
{
  CHECK();

  if (callbacks != NULL) {
    callbacks->end_section(tag, 0, nil);
    return;
  }

  dispatch_async(ABI46_0_0RCTProfileGetQueue(), ^{
    NSMutableArray<NSArray *> *events = ABI46_0_0RCTProfileGetThreadEvents(calleeThread);
    NSArray *event = events.lastObject;
    [events removeLastObject];

    if (!event) {
      return;
    }

    NSNumber *start = event[0];
    ABI46_0_0RCTProfileAddEvent(kProfileTraceEvents, @"tid"
                       : threadName, @"name"
                       : event[1], @"cat"
                       : category, @"ph"
                       : @"X", @"ts"
                       : start, @"dur"
                       : @(ABI46_0_0RCTProfileTimestamp(time).doubleValue - start.doubleValue), @"args"
                       : event[2], );
  });
}

NSUInteger ABI46_0_0RCTProfileBeginAsyncEvent(uint64_t tag, NSString *name, NSDictionary<NSString *, NSString *> *args)
{
  CHECK(0);

  static NSUInteger eventID = 0;

  NSTimeInterval time = CACurrentMediaTime();
  NSUInteger currentEventID = ++eventID;

  if (callbacks != NULL) {
    systrace_arg_t *systraceArgs = newSystraceArgsFromDictionary(args);
    callbacks->begin_async_section(tag, name.UTF8String, (int)(currentEventID % INT_MAX), args.count, systraceArgs);
    free(systraceArgs);
  } else {
    dispatch_async(ABI46_0_0RCTProfileGetQueue(), ^{
      ABI46_0_0RCTProfileOngoingEvents[@(currentEventID)] = @[
        ABI46_0_0RCTProfileTimestamp(time),
        name,
        ABI46_0_0RCTNullIfNil(args),
      ];
    });
  }

  return currentEventID;
}

void ABI46_0_0RCTProfileEndAsyncEvent(uint64_t tag, NSString *category, NSUInteger cookie, NSString *name, NSString *threadName)
{
  CHECK();

  if (callbacks != NULL) {
    callbacks->end_async_section(tag, name.UTF8String, (int)(cookie % INT_MAX), 0, nil);
    return;
  }

  NSTimeInterval time = CACurrentMediaTime();

  dispatch_async(ABI46_0_0RCTProfileGetQueue(), ^{
    NSArray *event = ABI46_0_0RCTProfileOngoingEvents[@(cookie)];

    if (event) {
      NSNumber *endTimestamp = ABI46_0_0RCTProfileTimestamp(time);

      ABI46_0_0RCTProfileAddEvent(kProfileTraceEvents, @"tid"
                         : threadName, @"name"
                         : event[1], @"cat"
                         : category, @"ph"
                         : @"X", @"ts"
                         : event[0], @"dur"
                         : @(endTimestamp.doubleValue - [event[0] doubleValue]), @"args"
                         : event[2], );
      [ABI46_0_0RCTProfileOngoingEvents removeObjectForKey:@(cookie)];
    }
  });
}

void ABI46_0_0RCTProfileImmediateEvent(uint64_t tag, NSString *name, NSTimeInterval time, char scope)
{
  CHECK();

  if (callbacks != NULL) {
    callbacks->instant_section(tag, name.UTF8String, scope);
    return;
  }

  NSString *threadName = ABI46_0_0RCTCurrentThreadName();

  dispatch_async(ABI46_0_0RCTProfileGetQueue(), ^{
    ABI46_0_0RCTProfileAddEvent(kProfileTraceEvents, @"tid"
                       : threadName, @"name"
                       : name, @"ts"
                       : ABI46_0_0RCTProfileTimestamp(time), @"scope"
                       : @(scope), @"ph"
                       : @"i", @"args"
                       : ABI46_0_0RCTProfileGetMemoryUsage(), );
  });
}

NSUInteger _ABI46_0_0RCTProfileBeginFlowEvent(void)
{
  static NSUInteger flowID = 0;

  CHECK(0);

  NSUInteger cookie = ++flowID;
  if (callbacks != NULL) {
    callbacks->begin_async_flow(1, "flow", (int)cookie);
    return cookie;
  }

  NSTimeInterval time = CACurrentMediaTime();
  NSString *threadName = ABI46_0_0RCTCurrentThreadName();

  dispatch_async(ABI46_0_0RCTProfileGetQueue(), ^{
    ABI46_0_0RCTProfileAddEvent(kProfileTraceEvents, @"tid"
                       : threadName, @"name"
                       : @"flow", @"id"
                       : @(cookie), @"cat"
                       : @"flow", @"ph"
                       : @"s", @"ts"
                       : ABI46_0_0RCTProfileTimestamp(time), );
  });

  return cookie;
}

void _ABI46_0_0RCTProfileEndFlowEvent(NSUInteger cookie)
{
  CHECK();

  if (callbacks != NULL) {
    callbacks->end_async_flow(1, "flow", (int)cookie);
    return;
  }

  NSTimeInterval time = CACurrentMediaTime();
  NSString *threadName = ABI46_0_0RCTCurrentThreadName();

  dispatch_async(ABI46_0_0RCTProfileGetQueue(), ^{
    ABI46_0_0RCTProfileAddEvent(kProfileTraceEvents, @"tid"
                       : threadName, @"name"
                       : @"flow", @"id"
                       : @(cookie), @"cat"
                       : @"flow", @"ph"
                       : @"f", @"ts"
                       : ABI46_0_0RCTProfileTimestamp(time), );
  });
}

void ABI46_0_0RCTProfileSendResult(ABI46_0_0RCTBridge *bridge, NSString *route, NSData *data)
{
  if (![bridge.bundleURL.scheme hasPrefix:@"http"]) {
    ABI46_0_0RCTLogWarn(
        @"Cannot upload profile information because you're not connected to the packager. The profiling data is still saved in the app container.");
    return;
  }

  NSURL *URL = [NSURL URLWithString:[@"/" stringByAppendingString:route] relativeToURL:bridge.bundleURL];

  NSMutableURLRequest *URLRequest = [NSMutableURLRequest requestWithURL:URL];
  URLRequest.HTTPMethod = @"POST";
  [URLRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

  NSURLSessionTask *task = [[NSURLSession sharedSession]
      uploadTaskWithRequest:URLRequest
                   fromData:data
          completionHandler:^(NSData *responseData, __unused NSURLResponse *response, NSError *error) {
            if (error) {
              ABI46_0_0RCTLogError(@"%@", error.localizedDescription);
            } else {
              NSString *message = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];

              if (message.length) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  UIAlertController *alertController =
                      [UIAlertController alertControllerWithTitle:@"Profile"
                                                          message:message
                                                   preferredStyle:UIAlertControllerStyleAlert];
                  [alertController addAction:[UIAlertAction actionWithTitle:@"OK"
                                                                      style:UIAlertActionStyleCancel
                                                                    handler:nil]];
                  [ABI46_0_0RCTPresentedViewController() presentViewController:alertController animated:YES completion:nil];
                });
              }
            }
          }];

  [task resume];
}

void ABI46_0_0RCTProfileShowControls(void)
{
  static const CGFloat height = 30;
  static const CGFloat width = 60;

  UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(20, 80, width * 2, height)];
  window.windowLevel = UIWindowLevelAlert + 1000;
  window.hidden = NO;
  window.backgroundColor = [UIColor lightGrayColor];
  window.layer.borderColor = [UIColor grayColor].CGColor;
  window.layer.borderWidth = 1;
  window.alpha = 0.8;

  UIButton *startOrStop = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, width, height)];
  [startOrStop setTitle:ABI46_0_0RCTProfileIsProfiling() ? @"Stop" : @"Start" forState:UIControlStateNormal];
  [startOrStop addTarget:[ABI46_0_0RCTProfile class] action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
  startOrStop.titleLabel.font = [UIFont systemFontOfSize:12];

  UIButton *reload = [[UIButton alloc] initWithFrame:CGRectMake(width, 0, width, height)];
  [reload setTitle:@"Reload" forState:UIControlStateNormal];
  [reload addTarget:[ABI46_0_0RCTProfile class] action:@selector(reload) forControlEvents:UIControlEventTouchUpInside];
  reload.titleLabel.font = [UIFont systemFontOfSize:12];

  [window addSubview:startOrStop];
  [window addSubview:reload];

  UIPanGestureRecognizer *gestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:[ABI46_0_0RCTProfile class]
                                                                                      action:@selector(drag:)];
  [window addGestureRecognizer:gestureRecognizer];

  ABI46_0_0RCTProfileControlsWindow = window;
}

void ABI46_0_0RCTProfileHideControls(void)
{
  ABI46_0_0RCTProfileControlsWindow.hidden = YES;
  ABI46_0_0RCTProfileControlsWindow = nil;
}

#endif
