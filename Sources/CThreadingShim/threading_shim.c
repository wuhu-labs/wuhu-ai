// Workaround for Swift 6.2 Linux linker bug:
// libswiftObservation.so references swift::threading::fatal() which is
// defined in libswiftCore.so but marked as a local (non-exported) symbol.
//
// This shim provides the missing symbol so executables linking against
// modules that use Observation (e.g. TUIkit) can link on Linux.
//
// Swift bug: https://github.com/swiftlang/swift/issues/75670
// Fix (not yet in 6.2): https://github.com/swiftlang/swift/pull/81185
//
// Remove this shim once Swift ships a release with the fix.

#ifdef __linux__

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>

void _ZN5swift9threading5fatalEPKcz(const char *fmt, ...) __attribute__((visibility("default")));

void _ZN5swift9threading5fatalEPKcz(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fprintf(stderr, "\n");
    abort();
}

#endif
