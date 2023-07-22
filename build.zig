const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;

const rp2040 = @import("rp2040");
const uf2 = @import("uf2");

const Demo = struct {
    name: []const u8,
    path: []const u8,
};

const demos: []const Demo = &.{
    // zig fmt: off
    .{ .name = "blinky",                 .path = "demos/00_blinky/main.zig" },
    .{ .name = "uart",                   .path = "demos/01_uart/uart.zig" },
    .{ .name = "uart_monitor",           .path = "demos/01_uart/monitor.zig" },
    .{ .name = "single_tone",            .path = "demos/02_single_tone/main.zig" },
    .{ .name = "volume_knob",            .path = "demos/03_volume_knob/main.zig" },
    .{ .name = "monophonic_keypad",      .path = "demos/04_monophonic_keypad/main.zig" },
    .{ .name = "adsr",                   .path = "demos/05_adsr/main.zig" },
    .{ .name = "additive_synthesis",     .path = "demos/06_additive_synthesis/main.zig" },
    .{ .name = "fm_synthesis_lfo",       .path = "demos/07_fm_synthesis/lfo.zig" },
    .{ .name = "fm_synthesis_operators", .path = "demos/07_fm_synthesis/operators.zig" },
    // zig fmt: on
};

pub fn build(b: *Builder) void {
    const optimize = b.standardOptimizeOption(.{});

    const raylib_zig_dep = b.dependency("raylib_zig", .{
        .optimize = optimize,
    });

    const raylib_dep = b.dependency("raylib", .{
        .optimize = optimize,
    });

    const uf2_dep = b.dependency("uf2", .{});
    for (demos) |demo| {
        const workshop_module = b.createModule(.{
            .source_file = .{
                .path = "src/workshop.zig",
            },
        });
        const exe = rp2040.addPiPicoExecutable(b, .{
            .name = demo.name,
            .source_file = .{
                .path = demo.path,
            },
            .optimize = optimize,
        });
        exe.addAppDependency("workshop", workshop_module, .{
            .depend_on_microzig = true,
        });
        exe.installArtifact(b);

        const uf2_file = uf2.from_elf(uf2_dep, exe.inner, .{ .family_id = .RP2040 });
        _ = b.addInstallFile(uf2_file, b.fmt("bin/{s}.uf2", .{demo.name}));
    }

    // monitor application
    const monitor_exe = b.addExecutable(.{
        .name = "monitor",
        .root_source_file = .{ .path = "src/monitor_exe.zig" },
        .optimize = optimize,
    });

    monitor_exe.addModule("raylib", raylib_zig_dep.module("raylib"));
    monitor_exe.linkLibrary(raylib_dep.artifact("raylib"));

    const monitor_run = b.addRunArtifact(monitor_exe);
    const monitor_step = b.step("monitor", "Run monitor application");
    monitor_step.dependOn(&monitor_run.step);

    // tools
    const os_str = comptime enum_to_string(builtin.os.tag);
    const arch_str = comptime enum_to_string(builtin.cpu.arch);

    // openocd
    const openocd_subdir = comptime std.fmt.comptimePrint("tools/openocd/{s}-{s}", .{ arch_str, os_str });
    const openocd_exe = if (builtin.os.tag == .linux)
        "tools/openocd/bring-your-own/install/bin/openocd"
    else
        comptime std.fmt.comptimePrint("{s}/bin/openocd{s}", .{
        openocd_subdir,
        if (builtin.os.tag == .windows) ".exe" else "",
    });

    // zig fmt: off
    const run_openocd = b.addSystemCommand(&.{
        openocd_exe,
        "-f", "interface/cmsis-dap.cfg",
        "-f", "target/rp2040.cfg",
        "-c", "adapter speed 5000",
    });
    // zig fmt: on

    // linux users need to build their own openocd
    if (builtin.os.tag == .linux) {
        run_openocd.addArgs(&.{ "-s", "tools/openocd/bring-your-own/install/share/openocd/scripts" });
    }

    const openocd = b.step("openocd", "run openocd for your debugger");
    openocd.dependOn(&run_openocd.step);
}

fn enum_to_string(comptime val: anytype) []const u8 {
    const Enum = @TypeOf(val);
    return inline for (@typeInfo(Enum).Enum.fields) |field| {
        if (val == @field(Enum, field.name))
            break field.name;
    } else unreachable;
}
