#import <AppKit/AppKit.h>
#include <node_api.h>

// Post only to the isolated test application's event queue, never the system.
static napi_value Begin(napi_env env, napi_callback_info) {
  CGEventRef event = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2, 0, 0);
  CGEventSetTimestamp(event, (CGEventTimestamp)([NSProcessInfo processInfo].systemUptime * 1000000000));
  CGEventSetIntegerValueField(event, kCGScrollWheelEventScrollPhase, kCGScrollPhaseBegan);
  [NSApp postEvent:[NSEvent eventWithCGEvent:event] atStart:NO];
  CFRelease(event);
  napi_value result;
  napi_get_undefined(env, &result);
  return result;
}

static napi_value Init(napi_env env, napi_value exports) {
  napi_value begin;
  napi_create_function(env, "begin", NAPI_AUTO_LENGTH, Begin, nullptr, &begin);
  napi_set_named_property(env, exports, "begin", begin);
  return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
