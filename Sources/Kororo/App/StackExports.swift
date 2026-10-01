// UI and tests import only KororoCore; re-export the stack modules so they keep working.
// (In the Xcode app target everything is one module, so this is SwiftPM-only.)
#if SWIFT_PACKAGE
@_exported import StackCore
@_exported import StackMCP
@_exported import StackHTTP
#endif
