const std = @import("std");
const assert = std.debug.assert();
const EnumField = std.builtin.Type.EnumField;
const StructField = std.builtin.Type.StructField;

const microzig = @import("microzig");
const rp2040 = microzig.hal;
const clocks = rp2040.clocks;
const gpio = rp2040.gpio;

pub fn I2S(comptime args: struct {
    sample_rate: u32,
    sample_type: type,
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
    switch (args.sample_type) {
        u16, u24, u32 => {},
        else => @compileError("sample_type must be u16, u24, or u32"),
    }

    const sample_width = @bitSizeOf(args.sample_type);
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
        pub const Options = struct {
            clock_config: clocks.GlobalConfiguration,
            clk_pin: gpio.Gpio,
            word_select_pin: gpio.Gpio,
            data_pin: gpio.Gpio,
        };

        pub fn init(pio: rp2040.pio.Pio, comptime options: Options) @This() {
            if (@enumToInt(options.word_select_pin) != @enumToInt(options.clk_pin) + 1)
                @panic("word select pin must be clk pin + 1");

            if (@enumToInt(options.data_pin) != @enumToInt(options.word_select_pin) + 1)
                @panic("word select pin must be word_select pin + 1");

            pio.gpio_init(options.data_pin);
            pio.gpio_init(options.clk_pin);
            pio.gpio_init(options.word_select_pin);

            const sm = pio.claim_unused_state_machine() catch unreachable;
            pio.sm_load_and_start_program(sm, i2s_program, .{
                .clkdiv = comptime rp2040.pio.ClkDivOptions.from_float(div: {
                    const sys_clk_freq = @intToFloat(f32, options.clock_config.sys.?.output_freq);
                    const i2s_clk_freq = @intToFloat(f32, args.sample_rate * sample_width * 2);

                    // TODO: 2 or 4 PIO clocks generate one I2S clock cycle
                    const pio_clk_freq = 2 * i2s_clk_freq;
                    break :div sys_clk_freq / pio_clk_freq;
                }),
                .shift = .{
                    .autopull = true,
                    .pull_threshold = @truncate(u5, sample_width),
                    .join_tx = true,
                },
                .pin_mappings = .{
                    .set = .{
                        .base = @enumToInt(options.clk_pin),
                        .count = 3,
                    },
                    .side_set = .{
                        .base = @enumToInt(options.clk_pin),
                        .count = 2,
                    },
                    .out = .{
                        .base = @enumToInt(options.data_pin),
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

        const sample_shift = 32 - sample_width;
        pub const Sample = struct {
            left: args.sample_type,
            right: args.sample_type,
        };

        pub fn write(self: Self, sample: Sample) void {
            self.pio.sm_write(self.sm, sample.left << sample_shift);
            self.pio.sm_write(self.sm, sample.right << sample_shift);
        }

        pub fn write_blocking(self: Self, sample: Sample) void {
            self.pio.sm_blocking_write(self.sm, sample.left << sample_shift);
            self.pio.sm_blocking_write(self.sm, sample.right << sample_shift);
        }
    };
}
