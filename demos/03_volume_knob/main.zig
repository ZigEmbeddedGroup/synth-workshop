const std = @import("std");
const microzig = @import("microzig");
const cpu = microzig.cpu;
const rp2040 = microzig.hal;
const gpio = rp2040.gpio;
const irq = rp2040.irq;
const adc = rp2040.adc;

// code for this workshop
const workshop = @import("workshop");
const Oscillator = workshop.Oscillator;

// configuration
const sample_rate = 96_000;
const Sample = i16;

// hardware blocks
const button = gpio.num(9);
const pot = adc.num(2);
const I2S = workshop.I2S(Sample, .{ .sample_rate = sample_rate });

pub fn main() !void {
    // see blinky for an explanation here:
    button.set_function(.sio);
    button.set_direction(.in);
    button.set_pull(.down);

    const i2s = I2S.init(.pio0, .{
        .clock_config = rp2040.clock_config,
        .clk_pin = gpio.num(2),
        .word_select_pin = gpio.num(3),
        .data_pin = gpio.num(4),
    });

    var osc = Oscillator(sample_rate).init(440);

    // lfg
    cpu.enable_interrupts();
    while (true) {
        if (i2s.is_writable()) {
            var sample: Sample = 0;

            // let's not make things louder than they need to be
            sample >>= 4;
            i2s.write_mono(sample);
        }
    }
}
