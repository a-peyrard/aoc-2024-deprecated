//! Default test runner for unit tests.
const std = @import("std");
const io = std.io;
const builtin = @import("builtin");

pub const std_options = .{
    .logFn = log,
};

var log_err_count: usize = 0;
var cmdline_buffer: [4096]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&cmdline_buffer);

pub fn main() void {
    if (builtin.zig_backend == .stage2_riscv64) return mainExtraSimple() catch @panic("test failure");

    if (builtin.zig_backend == .stage2_aarch64) {
        return mainSimple() catch @panic("test failure");
    }

    const args = std.process.argsAlloc(fba.allocator()) catch
        @panic("unable to parse command line args");

    var listen = false;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            listen = true;
        } else {
            @panic("unrecognized command line argument");
        }
    }

    if (listen) {
        return mainServer() catch @panic("internal test runner failure");
    } else {
        return mainTerminal();
    }
}

fn mainServer() !void {
    var server = try std.zig.Server.init(.{
        .gpa = fba.allocator(),
        .in = std.io.getStdIn(),
        .out = std.io.getStdOut(),
        .zig_version = builtin.zig_version_string,
    });
    defer server.deinit();

    while (true) {
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            .exit => {
                return std.process.exit(0);
            },
            .query_test_metadata => {
                std.testing.allocator_instance = .{};
                defer if (std.testing.allocator_instance.deinit() == .leak) {
                    @panic("internal test runner memory leak");
                };

                var string_bytes: std.ArrayListUnmanaged(u8) = .{};
                defer string_bytes.deinit(std.testing.allocator);
                try string_bytes.append(std.testing.allocator, 0); // Reserve 0 for null.

                const test_fns = builtin.test_functions;
                const names = try std.testing.allocator.alloc(u32, test_fns.len);
                defer std.testing.allocator.free(names);
                const expected_panic_msgs = try std.testing.allocator.alloc(u32, test_fns.len);
                defer std.testing.allocator.free(expected_panic_msgs);

                for (test_fns, names, expected_panic_msgs) |test_fn, *name, *expected_panic_msg| {
                    name.* = @as(u32, @intCast(string_bytes.items.len));
                    try string_bytes.ensureUnusedCapacity(std.testing.allocator, test_fn.name.len + 1);
                    string_bytes.appendSliceAssumeCapacity(test_fn.name);
                    string_bytes.appendAssumeCapacity(0);
                    expected_panic_msg.* = 0;
                }

                try server.serveTestMetadata(.{
                    .names = names,
                    .expected_panic_msgs = expected_panic_msgs,
                    .string_bytes = string_bytes.items,
                });
            },

            .run_test => {
                std.testing.allocator_instance = .{};
                log_err_count = 0;
                const index = try server.receiveBody_u32();
                const test_fn = builtin.test_functions[index];
                var fail = false;
                var skip = false;
                var leak = false;
                test_fn.func() catch |err| switch (err) {
                    error.SkipZigTest => skip = true,
                    else => {
                        fail = true;
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpStackTrace(trace.*);
                        }
                    },
                };
                leak = std.testing.allocator_instance.deinit() == .leak;
                try server.serveTestResults(.{
                    .index = index,
                    .flags = .{
                        .fail = fail,
                        .skip = skip,
                        .leak = leak,
                        .log_err_count = std.math.lossyCast(
                            @TypeOf(@as(std.zig.Server.Message.TestResults.Flags, undefined).log_err_count),
                            log_err_count,
                        ),
                    },
                });
            },

            else => {
                std.debug.print("unsupported message: {x}", .{@intFromEnum(hdr.tag)});
                std.process.exit(1);
            },
        }
    }
}

fn mainTerminal() void {
    const test_fn_list = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    const root_node = std.Progress.start(.{
        .root_name = "Test",
        .estimated_total_items = test_fn_list.len,
    });

    var async_frame_buffer: []align(builtin.target.stackAlignment()) u8 = undefined;
    async_frame_buffer = &[_]u8{};

    const suite_start_time = std.time.nanoTimestamp();
    var leaks: usize = 0;
    for (test_fn_list, 0..) |test_fn, i| {
        const start_time = std.time.nanoTimestamp();

        std.testing.allocator_instance = .{};
        defer {
            if (std.testing.allocator_instance.deinit() == .leak) {
                leaks += 1;
            }
        }
        std.testing.log_level = .warn;

        const test_node = root_node.start(test_fn.name, 0);
        std.debug.print("\x1b[36m{d}/{d} {s}\x1b[0m...\n", .{ i + 1, test_fn_list.len, test_fn.name });

        if (test_fn.func()) |_| {
            ok_count += 1;
            const duration = std.time.nanoTimestamp() - start_time;
            test_node.end();
            std.debug.print("  \x1b[32m✔\x1b[0m {s} ({d} ms)\n", .{ test_fn.name, @divTrunc(duration, 1_000_000) });
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                test_node.end();
                std.debug.print("  \x1b[33m⚠ SKIP {s}\x1b[0m\n", .{ test_fn.name });
            },
            else => {
                fail_count += 1;
                test_node.end();
                std.debug.print("  \x1b[31m✘ FAIL {s}\x1b[0m ({s})\n", .{ test_fn.name, @errorName(err) });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            },
        }
    }
    const suite_end_time = std.time.nanoTimestamp();
    const total_duration = suite_end_time - suite_start_time;

    root_node.end();

    std.debug.print("\nResults:\n", .{});
    if (ok_count > 0) std.debug.print("  \x1b[32m✔ {d} passed\x1b[0m\n", .{ok_count});
    if (skip_count > 0) std.debug.print("  \x1b[33m⚠ {d} skipped\x1b[0m\n", .{skip_count});
    if (fail_count > 0) std.debug.print("  \x1b[31m✘ {d} failed\x1b[0m\n", .{fail_count});

    std.debug.print("\nTotal duration: {d} ms\n", .{@divTrunc(total_duration, 1_000_000)});

    if (log_err_count != 0) {
        std.debug.print("\n  \x1b[31m{d} errors were logged.\x1b[0m\n", .{log_err_count});
    }
    if (leaks != 0) {
        std.debug.print("\n  \x1b[31m{d} tests leaked memory.\x1b[0m\n", .{leaks});
    }

    if (leaks != 0 or log_err_count != 0 or fail_count != 0) {
        std.process.exit(1);
    }
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(std.testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}

/// Simpler main(), exercising fewer language features, so that
/// work-in-progress backends can handle it.
pub fn mainSimple() anyerror!void {
    const enable_print = false;
    const print_all = false;

    var passed: u64 = 0;
    var skipped: u64 = 0;
    var failed: u64 = 0;
    const stderr = if (enable_print) std.io.getStdErr() else {};
    for (builtin.test_functions) |test_fn| {
        if (enable_print and print_all) {
            stderr.writeAll(test_fn.name) catch {};
            stderr.writeAll("... ") catch {};
        }
        test_fn.func() catch |err| {
            if (enable_print and !print_all) {
                stderr.writeAll(test_fn.name) catch {};
                stderr.writeAll("... ") catch {};
            }
            if (err != error.SkipZigTest) {
                if (enable_print) stderr.writeAll("FAIL\n") catch {};
                failed += 1;
                if (!enable_print) return err;
                continue;
            }
            if (enable_print) stderr.writeAll("SKIP\n") catch {};
            skipped += 1;
            continue;
        };
        if (enable_print and print_all) stderr.writeAll("PASS\n") catch {};
        passed += 1;
    }
    if (enable_print) {
        stderr.writer().print("{} passed, {} skipped, {} failed\n", .{ passed, skipped, failed }) catch {};
        if (failed != 0) std.process.exit(1);
    }
}

pub fn mainExtraSimple() !void {
    var fail_count: u8 = 0;

    for (builtin.test_functions) |test_fn| {
        test_fn.func() catch |err| {
            if (err != error.SkipZigTest) {
                fail_count += 1;
                continue;
            }
            continue;
        };
    }

    if (fail_count != 0) std.process.exit(1);
}
