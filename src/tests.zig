//! The single root of the test build.
//!
//! Zig only compiles what something references, so a test file nothing imports
//! is silently skipped. Every test file is therefore named here explicitly.

test {
    _ = @import("zroar_test.zig");
    _ = @import("container_test.zig");
    _ = @import("setutil_test.zig");
    _ = @import("keys_test.zig");
    _ = @import("prop_test.zig");
}
