#import <AppKit/AppKit.h>
#include <node_api.h>

// Observe only this application's events. No event tap, global monitoring or
// Accessibility permission is required, and the original event is untouched.
struct Monitor {
  id token;
  napi_threadsafe_function callback;
};

static void Deliver(napi_env env, napi_value callback, void *, void *data) {
  double *timestamp = static_cast<double *>(data);
  if (env && callback) {
    napi_value value, receiver, result;
    napi_create_double(env, *timestamp, &value);
    napi_get_undefined(env, &receiver);
    napi_call_function(env, receiver, callback, 1, &value, &result);
  }
  delete timestamp;
}

static void Cleanup(void *data) {
  Monitor *monitor = static_cast<Monitor *>(data);
  [NSEvent removeMonitor:monitor->token];
  napi_release_threadsafe_function(monitor->callback, napi_tsfn_abort);
  delete monitor;
}

static napi_value Start(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value callback, name;
  napi_get_cb_info(env, info, &argc, &callback, nullptr, nullptr);
  napi_valuetype type;
  if (argc != 1 || napi_typeof(env, callback, &type) != napi_ok || type != napi_function) {
    napi_throw_type_error(env, nullptr, "Expected a gesture callback"); return nullptr;
  }
  auto *monitor = new Monitor{};
  napi_create_string_utf8(env, "ScrollGesture", NAPI_AUTO_LENGTH, &name);
  if (napi_create_threadsafe_function(env, callback, nullptr, name, 0, 1, nullptr, nullptr, nullptr, Deliver, &monitor->callback) != napi_ok) {
    delete monitor; napi_throw_error(env, nullptr, "Could not create gesture callback"); return nullptr;
  }
  napi_unref_threadsafe_function(env, monitor->callback);
  monitor->token = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel handler:^NSEvent *(NSEvent *event) {
    if ((event.phase & NSEventPhaseBegan) && event.momentumPhase == NSEventPhaseNone) {
      // Preserve the original time even if delivery to JavaScript is delayed.
      auto *timestamp = new double(([NSDate timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970 -
        ([NSProcessInfo processInfo].systemUptime - event.timestamp)) * 1000);
      if (napi_call_threadsafe_function(monitor->callback, timestamp, napi_tsfn_nonblocking) != napi_ok) delete timestamp;
    }
    return event;
  }];
  napi_add_env_cleanup_hook(env, Cleanup, monitor);
  napi_value result;
  napi_get_undefined(env, &result);
  return result;
}

static napi_value Init(napi_env env, napi_value exports) {
  napi_value start;
  napi_create_function(env, "start", NAPI_AUTO_LENGTH, Start, nullptr, &start);
  napi_set_named_property(env, exports, "start", start);
  return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
