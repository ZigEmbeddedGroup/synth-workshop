const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("microzig");
const cpu = microzig.cpu;
const rp2040 = microzig.hal;
const gpio = rp2040.gpio;
const irq = rp2040.irq;
const time = rp2040.time;

// code for this workshop
const workshop = @import("workshop");
const Oscillator = workshop.Oscillator;

// configuration
const sample_rate = 44_100;
const Sample = i16;

// hardware blocks
const I2S = workshop.I2S(Sample, .{ .sample_rate = sample_rate });

const uart = rp2040.uart.num(0);

const bruh = @embedFile("rick.raw");

pub fn main() !void {
    const i2s = I2S.init(.pio0, .{
        .clock_config = rp2040.clock_config,
        .clk_pin = gpio.num(2),
        .word_select_pin = gpio.num(3),
        .data_pin = gpio.num(4),
    });

    var fbs = std.io.fixedBufferStream(bruh);

    while (true) {
        if (!i2s.is_writable())
            continue;

        i2s.write_mono(fbs.reader().readIntLittle(i16) catch @panic("NO!"));
    }
}
