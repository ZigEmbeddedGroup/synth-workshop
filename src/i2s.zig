const std = @import("std");
const assert = std.debug.assert();
const EnumField = std.builtin.Type.EnumField;
const StructField = std.builtin.Type.StructField;

const microzig = @import("microzig");
const rp2040 = microzig.hal;
const clocks = rp2040.clocks;
const gpio = rp2040.gpio;

pub fn I2S(comptime Sample: type, comptime args: struct {
    sample_rate: u32,
}) type {
    switch (args.sample_rate) {
        8_000,
        16_000,
        32_000,
        44_100,
        48_000,
        88_200,
        96_000,
        => {},
        else => @compileError("sample_rate must be 8kHz, 16kHz, 32kHz, 44.1kHz, 48kHz, 88.2kHz or 96kHz"),
    }

    // TODO: signed?
    switch (Sample) {
        i16, i24, i32 => {},
        else => @compileError("sample_type must be i16, i24, or i32"),
    }

    const sample_width = @bitSizeOf(Sample);
    const output = comptime rp2040.pio.assemble(std.fmt.comptimePrint(
        \\.program i2s
        \\.side_set 2
        \\
        \\.define SAMPLE_BITS {}
        \\
        \\  set pindirs, 0x7         side 0x1 ; Set pin to output
        \\.wrap_target
        \\  set x, (SAMPLE_BITS - 2) side 0x1
        \\left_first:
        \\  out pins, 1              side 0x0
        \\  jmp x-- left_first       side 0x1
        \\  out pins, 1              side 0x2
        \\
        \\  set x, (SAMPLE_BITS - 2) side 0x3
        \\right_first:
        \\  out pins, 1              side 0x2
        \\  jmp x-- right_first      side 0x3
        \\  out pins, 1              side 0x0
        \\.wrap
    , .{sample_width}), .{});

    const i2s_program = comptime output.get_program_by_name("i2s");
    return struct {
        pio: rp2040.pio.Pio,
        sm: rp2040.pio.StateMachine,

        const Self = @This();
        pub const InitOptions = struct {
            clock_config: clocks.GlobalConfiguration,
            clk_pin: gpio.Pin,
            word_select_pin: gpio.Pin,
            data_pin: gpio.Pin,
        };

        pub fn init(pio: rp2040.pio.Pio, comptime opts: InitOptions) @This() {
            if (@intFromEnum(opts.word_select_pin) != @intFromEnum(opts.clk_pin) + 1)
                @panic("word select pin must be clk pin + 1");

            if (@intFromEnum(opts.data_pin) != @intFromEnum(opts.word_select_pin) + 1)
                @panic("word select pin must be word_select pin + 1");

            pio.gpio_init(opts.data_pin);
            pio.gpio_init(opts.clk_pin);
            pio.gpio_init(opts.word_select_pin);

            const sm = pio.claim_unused_state_machine() catch unreachable;
            pio.sm_load_and_start_program(sm, i2s_program, .{
                .clkdiv = comptime rp2040.pio.ClkDivOptions.from_float(div: {
                    const sys_clk_freq = @as(f32, @floatFromInt(opts.clock_config.sys.?.output_freq));
                    const i2s_clk_freq = @as(f32, @floatFromInt(args.sample_rate * sample_width * 2));

                    // TODO: 2 or 4 PIO clocks generate one I2S clock cycle
                    const pio_clk_freq = 2 * i2s_clk_freq;
                    break :div sys_clk_freq / pio_clk_freq;
                }),
                .shift = .{
                    .autopull = true,
                    .pull_threshold = @as(u5, @truncate(sample_width)),
                    .join_tx = true,
                    .out_shiftdir = .left,
                },
                .pin_mappings = .{
                    .set = .{
                        .base = @intFromEnum(opts.clk_pin),
                        .count = 3,
                    },
                    .side_set = .{
                        .base = @intFromEnum(opts.clk_pin),
                        .count = 2,
                    },
                    .out = .{
                        .base = @intFromEnum(opts.data_pin),
                        .count = 1,
                    },
                },
            }) catch unreachable;

            pio.sm_set_enabled(sm, true);
            return Self{
                .pio = pio,
                .sm = sm,
            };
        }

        pub fn is_writable(self: Self) bool {
            // the TX FIFO is joined, making a total of 8 entries. We only
            // want to write when there's room for at least two samples
            return self.pio.sm_fifo_level(self.sm, .tx) <= 6;
        }

        const UnsignedSample = std.meta.Int(.unsigned, @bitSizeOf(Sample));
        fn sample_to_fifo_entry(sample: Sample) u32 {
            const sample_shift = comptime 32 - sample_width;
            return @as(
                u32,
                @intCast(@as(UnsignedSample, @bitCast(sample))),
            ) << sample_shift;
        }

        pub fn write_mono(self: Self, sample: Sample) void {
            const value = sample_to_fifo_entry(sample);
            self.pio.sm_write(self.sm, value);
            self.pio.sm_write(self.sm, value);
        }

        pub const StereoSample = struct {
            left: Sample,
            right: Sample,
        };

        pub fn write_stereo(self: Self, sample: StereoSample) void {
            self.pio.sm_write(self.sm, sample_to_fifo_entry(sample.left));
            self.pio.sm_write(self.sm, sample_to_fifo_entry(sample.right));
        }

        pub fn write_stereo_blocking(self: Self, sample: StereoSample) void {
            self.pio.sm_blocking_write(self.sm, sample_to_fifo_entry(sample.left));
            self.pio.sm_blocking_write(self.sm, sample_to_fifo_entry(sample.right));
        }
    };
}
