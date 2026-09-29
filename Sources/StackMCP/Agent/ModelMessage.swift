#if SWIFT_PACKAGE
import StackCore
#endif

// Files that import the MCP SDK see two `Message` types (its own and StackCore's).
// This file doesn't import MCP, so the name is unambiguous here.
typealias ModelMessage = Message
