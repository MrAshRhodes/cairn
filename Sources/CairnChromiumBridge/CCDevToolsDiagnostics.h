// Smoke-only DevTools correlation. Never pass expressions, parameters, URLs, results or errors here.
#pragma once
#import <Foundation/Foundation.h>
#include <cstdio>
#include <cstdlib>

namespace cc {

inline void TraceDevTools(const char *stage, int browserID, int suggestedID, int assignedID,
                          NSString *method = nil, int success = -1, int pending = -1) {
  // The bundled smoke already sets this marker. Only test for its presence; never log its value.
  const char *smoke = std::getenv("CAIRN_SMOKE_URL");
  if (!smoke || !*smoke) return;
  // -1 means the field is not known/applicable at this stage. Timestamps are monotonic seconds.
  std::fprintf(stderr, "CAIRN_SMOKE_DEVTOOLS t=%.6f stage=%s browser=%d suggested=%d assigned=%d "
                       "method=%s success=%d pending=%d\n",
               NSProcessInfo.processInfo.systemUptime, stage, browserID, suggestedID, assignedID,
               method ? method.UTF8String : "-", success, pending);
  std::fflush(stderr);
}

}  // namespace cc
