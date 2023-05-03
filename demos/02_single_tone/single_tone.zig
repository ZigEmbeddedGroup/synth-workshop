const std = @import("std");
const microzig = @import("microzig");
const cpu = microzig.cpu;
const rp2040 = microzig.hal;
const gpio = rp2040.gpio;
const irq = rp2040.irq;

// code for this workshop
const workshop = @import("workshop");
const Oscillator = workshop.Oscillator;
const I2S = workshop.I2S(.{
    .sample_rate = sample_rate,
    .sample_type = u32,
});

// configuration
const sample_rate = 44_100;
const SampleType = u32;

// hardware blocks
const uart = rp2040.uart.num(0);
const button = gpio.num(9);

pub fn main() !void {
    // see blinky.zig for an explanation here:
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
            osc.update();

            // our sample size is 32 bits, and it just so happens that the
            // maximum value of the oscillator corresponds to 2π radians. We
            // get a sawtooth waveform if we use the angle as the magnitude of
            // our generated wave.
            var sample: SampleType = if (button.read() == 1)
                @truncate(SampleType, osc.angle >> 32 - @bitSizeOf(SampleType))
            else
                (std.math.maxInt(SampleType) / 2);

            // let's not make things louder than they need to be
            sample >>= 4;
            i2s.write(.{
                // The amplifier takes a left and right input as part of the
                // I2S standard and averages both channels to the single
                // speaker. In order to take advantage of the full volume range
                // we'll assign the same value to both channels
                .right = sample,
                .left = sample,
            });
        }
    }
}
