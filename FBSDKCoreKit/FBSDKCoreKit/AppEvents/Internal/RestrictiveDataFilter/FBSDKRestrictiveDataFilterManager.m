// Copyright (c) 2014-present, Facebook, Inc. All rights reserved.
//
// You are hereby granted a non-exclusive, worldwide, royalty-free license to use,
// copy, modify, and distribute this software in source code or binary form for use
// in connection with the web services and APIs provided by Facebook.
//
// As with any software that integrates with the Facebook platform, your use of
// this software is subject to the Facebook Developer Principles and Policies
// [http://developers.facebook.com/policy/]. This copyright notice shall be
// included in all copies or substantial portions of the software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import "FBSDKRestrictiveDataFilterManager.h"

#import "FBSDKBasicUtility.h"
#import "FBSDKTypeUtility.h"

static NSString *const replacementString = @"_removed_";

static NSString *const RESTRICTIVE_PARAM_KEY = @"restrictive_param";
static NSString *const DEPRECATED_PARAM_KEY = @"deprecated_param";
static NSString *const PROCESS_EVENT_NAME_KEY = @"process_event_name";
static NSString *const DEPRECATED_EVENT_KEY = @"is_deprecated_event";

@interface FBSDKRestrictiveEventFilter : NSObject

@property (nonatomic, readonly, copy) NSString *eventName;
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, id> *restrictiveParams;
@property (nonatomic, readonly, copy, nullable) NSSet<NSString *> *deprecatedParams;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

-(instancetype)initWithEventName:(NSString *)eventName
               restrictiveParams:(NSDictionary<NSString *, id> *)restrictiveParams
                deprecatedParams:(NSSet<NSString *> *)deprecatedParams;

@end

@implementation FBSDKRestrictiveEventFilter

-(instancetype)initWithEventName:(NSString *)eventName
               restrictiveParams:(nullable NSDictionary<NSString *, id> *)restrictiveParams
                deprecatedParams:(nullable NSSet<NSString *> *)deprecatedParams
{
  self = [super init];
  if (self) {
    _eventName = eventName;
    _restrictiveParams = restrictiveParams;
    _deprecatedParams = deprecatedParams;
  }

  return self;
}

@end

@implementation FBSDKRestrictiveDataFilterManager

static BOOL isRestrictiveEventFilterEnabled = NO;

static NSMutableArray<FBSDKRestrictiveEventFilter *>  *_params;
static NSMutableSet<NSString *> *_deprecatedEvents;
static NSMutableSet<NSString *> *_restrictedEvents;

+ (void)updateFilters:(nullable NSDictionary<NSString *, id> *)restrictiveParams
{
  if (!isRestrictiveEventFilterEnabled) {
    return;
  }
  if (restrictiveParams.count > 0) {
    [_params removeAllObjects];
    [_deprecatedEvents removeAllObjects];
    [_restrictedEvents removeAllObjects];
    NSMutableArray<FBSDKRestrictiveEventFilter *> *eventFilterArray = [NSMutableArray array];
    NSMutableSet<NSString *> *deprecatedEventSet = [NSMutableSet set];
    NSMutableSet<NSString *> *restrictedEventSet = [NSMutableSet set];
    for (NSString *eventName in restrictiveParams.allKeys) {
      NSDictionary<NSString *, id> *eventInfo = restrictiveParams[eventName];
      if (!eventInfo) {
        return;
      }
      if (eventInfo[DEPRECATED_EVENT_KEY]) {
        [deprecatedEventSet addObject:eventName];
      }
      if (eventInfo[RESTRICTIVE_PARAM_KEY] || eventInfo[DEPRECATED_PARAM_KEY]) {
        FBSDKRestrictiveEventFilter *restrictiveEventFilter = [[FBSDKRestrictiveEventFilter alloc] initWithEventName:eventName
                                                                                                   restrictiveParams:eventInfo[RESTRICTIVE_PARAM_KEY] deprecatedParams:[NSSet setWithArray:eventInfo[DEPRECATED_PARAM_KEY]]];
        [eventFilterArray addObject:restrictiveEventFilter];
      }
      if (eventInfo[PROCESS_EVENT_NAME_KEY]) {
        [restrictedEventSet addObject:eventName];
      }
    }
    _params = eventFilterArray;
    _deprecatedEvents = deprecatedEventSet;
    _restrictedEvents = restrictedEventSet;
  }
}

+ (nullable NSString *)getMatchedDataTypeWithEventName:(NSString *)eventName
                                              paramKey:(NSString *)paramKey
{
  // match by params in custom events with event name
  for (FBSDKRestrictiveEventFilter *filter in _params) {
    if ([filter.eventName isEqualToString:eventName]) {
      NSString *type = [FBSDKTypeUtility stringValue:filter.restrictiveParams[paramKey]];
      if (type) {
        return type;
      }
      if (filter.deprecatedParams && [filter.deprecatedParams containsObject:paramKey]) {
        return DEPRECATED_EVENT_KEY;
      }
    }
  }
  return nil;
}

+ (BOOL)isDeprecatedEvent:(NSString *)eventName
{
  return [_deprecatedEvents containsObject:eventName];
}

+ (BOOL)isRestrictedEvent:(NSString *)eventName
{
  return [_restrictedEvents containsObject:eventName];
}

+ (void)processEvents:(NSMutableArray<NSDictionary<NSString *, id> *> *)events
{
  if (!isRestrictiveEventFilterEnabled) {
    return;
  }

  NSMutableArray<NSDictionary<NSString *, id> *> *eventsToRemove = [NSMutableArray array];
  for (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *event in events) {
    if ([FBSDKRestrictiveDataFilterManager isDeprecatedEvent:event[@"event"][@"_eventName"]]) {
      [eventsToRemove addObject:event];
    } else if ([FBSDKRestrictiveDataFilterManager isRestrictedEvent:event[@"event"][@"_eventName"]]) {
      [event[@"event"] setValue:replacementString forKey:@"_eventName"];
    }
  }
  [events removeObjectsInArray:eventsToRemove];
}

+ (NSDictionary<NSString *,id> *)processParameters:(NSDictionary<NSString *,id> *)parameters
                                         eventName:(NSString *)eventName
{
  if (!isRestrictiveEventFilterEnabled) {
    return parameters;
  }
  if (parameters) {
    NSMutableDictionary<NSString *, id> *params = [NSMutableDictionary dictionaryWithDictionary:parameters];
    NSMutableDictionary<NSString *, NSString *> *restrictedParams = [NSMutableDictionary dictionary];

    for (NSString *key in [parameters keyEnumerator]) {
      NSString *type = [FBSDKRestrictiveDataFilterManager getMatchedDataTypeWithEventName:eventName
                                                                                 paramKey:key];
      if ([type isEqualToString:DEPRECATED_EVENT_KEY]) {
        [params removeObjectForKey:key];
      } else if (type) {
        [restrictedParams setObject:type forKey:key];
        [params removeObjectForKey:key];
      }
    }

    if ([[restrictedParams allKeys] count] > 0) {
      NSString *restrictedParamsJSONString = [FBSDKBasicUtility JSONStringForObject:restrictedParams
                                                                              error:NULL
                                                               invalidObjectHandler:NULL];
      [FBSDKBasicUtility dictionary:params setObject:restrictedParamsJSONString forKey:@"_restrictedParams"];
    }

    return [params copy];
  }

  return nil;
}

+ (void)enable
{
  isRestrictiveEventFilterEnabled = YES;
}

#pragma mark Helper functions

+ (BOOL)isMatchedWithPattern:(NSString *)pattern
                        text:(NSString *)text
{
  NSRegularExpression *regex = [[NSRegularExpression alloc] initWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
  NSUInteger matches = [regex numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)];
  return matches > 0;
}

@end
