const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;

const rp2040 = @import("deps/raspberrypi-rp2040/build.zig");
const uf2 = @import("deps/uf2/src/main.zig");

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
    .{ .name = "rick", .path = "demos/08_rick/main.zig" },
    // zig fmt: on
};

pub fn build(b: *Builder) void {
    const optimize = b.standardOptimizeOption(.{});
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

        const uf2_step = uf2.Uf2Step.create(exe.inner, .{ .family_id = .RP2040 });
        uf2_step.install();
    }

    // tools
    const os_str = comptime enum_to_string(builtin.os.tag);
    const arch_str = comptime enum_to_string(builtin.cpu.arch);

    // openocd
    const openocd_subdir = comptime std.fmt.comptimePrint("tools/openocd/{s}-{s}", .{ arch_str, os_str });
    const openocd_scripts_dir = comptime std.fmt.comptimePrint("{s}/share/openocd/scripts", .{openocd_subdir});
    const openocd_exe = if (builtin.os.tag == .linux)
        "openocd"
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
        run_openocd.addArgs(&.{ "-s", openocd_scripts_dir });
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
