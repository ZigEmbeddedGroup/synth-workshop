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
    .{ .name = "blinky",                         .path = "demos/00_blinky/main.zig" },
    .{ .name = "uart",                           .path = "demos/01_uart/main.zig" },
    .{ .name = "single_tone",                    .path = "demos/02_single_tone/main.zig" },
    .{ .name = "volume_knob",                    .path = "demos/03_volume_knob/main.zig" },
    .{ .name = "changing_pitch",                 .path = "demos/04_changing_pitch/main.zig" },
    .{ .name = "monophonic_keypad",              .path = "demos/05_monophonic_keypad/main.zig" },
    .{ .name = "adsr",                           .path = "demos/06_adsr/main.zig" },
    .{ .name = "additive_synthesis",             .path = "demos/07_additive_synthesis/main.zig" },
    .{ .name = "frequency_modulation_synthesis", .path = "demos/08_frequency_modulation_synthesis/main.zig" },
    .{ .name = "drums",                          .path = "demos/09_drums/main.zig" },
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
    const openocd_scripts_dir = comptime project_root(std.fmt.comptimePrint("{s}/share/openocd/scripts", .{openocd_subdir}));
    const openocd_exe = comptime project_root(std.fmt.comptimePrint("{s}/bin/openocd{s}", .{
        openocd_subdir,
        if (builtin.os.tag == .windows) ".exe" else "",
    }));

    // zig fmt: off
    const run_openocd = b.addSystemCommand(&.{
        openocd_exe,
        "-s", openocd_scripts_dir,
        "-f", "interface/cmsis-dap.cfg",
        "-f", "target/rp2040.cfg",
        "-c", "adapter speed 5000",
    });
    // zig fmt: on

    const openocd = b.step("openocd", "run openocd for your debugger");
    openocd.dependOn(&run_openocd.step);
}

fn project_root(comptime path: []const u8) []const u8 {
    const root_dir = std.fs.path.dirname(@src().file) orelse unreachable;
    return std.fmt.comptimePrint("{s}/{s}", .{ root_dir, path });
}

fn enum_to_string(comptime val: anytype) []const u8 {
    const Enum = @TypeOf(val);
    return inline for (@typeInfo(Enum).Enum.fields) |field| {
        if (val == @field(Enum, field.name))
            break field.name;
    } else unreachable;
}
