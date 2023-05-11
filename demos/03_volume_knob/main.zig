//! A single adc sample takes 96 clock cycles of the ADC clock, which
//! is 48MHz.
//!
//! 96 * (1 / 48MHz) = 2us
//!
//! With a sample rate of 96KHz, we have to provide a sample every
//! 10.4us. If we sat around and waited for the ADC to take a sample,
//! we're wasting almost 20% of our time budget!
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

fn apply_volume(sample: Sample, volume: u12) i16 {
    const result = @as(i32, sample) * volume;
    return @intCast(i16, result >> 12);
}

pub fn main() !void {
    // see blinky for an explanation here:
    button.set_function(.sio);
    button.set_direction(.in);
    button.set_pull(.down);

    pot.init();
    adc.init();
    adc.select_input(pot);
    adc.start_single_conversion();

    // TODO: set up repeated samples, just read off the fifo

    const i2s = I2S.init(.pio0, .{
        .clock_config = rp2040.clock_config,
        .clk_pin = gpio.num(2),
        .word_select_pin = gpio.num(3),
        .data_pin = gpio.num(4),
    });

    var osc = Oscillator(sample_rate).init(440);
    var volume: u12 = 0;

    // lfg
    while (true) {
        if (adc.is_ready()) {
            volume = adc.read_result();
            adc.start_single_conversion();
        }

        if (i2s.is_writable()) {
            const sample: Sample = if (button.read() == 1)
                @intCast(Sample, osc.angle >> 32 - @bitSizeOf(Sample))
            else
                0;

            // let's not make things louder than they need to be
            i2s.write_mono(apply_volume(sample, volume));
        }
    }
}
