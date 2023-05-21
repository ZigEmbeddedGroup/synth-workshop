//! A single adc sample takes 96 clock cycles of the ADC clock, which
//! is 48MHz.
//!
//! 96 * (1 / 48MHz) = 2us
//!
//! With a sample rate of 96KHz, we have to provide a sample every
//! 10.4us. If we sat around and waited for the ADC to take a sample,
//! we'd be wasting almost 20% of our time budget!
const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("microzig");
const cpu = microzig.cpu;
const rp2040 = microzig.hal;
const gpio = rp2040.gpio;
const irq = rp2040.irq;
const adc = rp2040.adc;

// code for this workshop
const workshop = @import("workshop");
const Oscillator = workshop.Oscillator;
const apply_volume = workshop.apply_volume;

// configuration
const sample_rate = 96_000;
const Sample = i16;

// hardware blocks
const button = gpio.num(9);
const pot = adc.input(2);
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

    // configure the ADC to sample the potentiometer input 1000 times a second.
    pot.configure_gpio_pin();
    adc.apply(.{ .sample_frequency = 1000 });
    adc.select_input(pot);
    adc.start(.free_running);

    var osc = Oscillator(sample_rate).init(440);
    var volume: u12 = 0;

    // lfg
    while (true) {
        if (i2s.is_writable()) {
            // ADC conversions _can_ fail, if it does then don't change the
            // volume.
            volume = adc.read_result() catch volume;

            osc.tick();

            const sample: Sample = if (button.read() == 1)
                osc.to_sawtooth(Sample)
            else
                0;

            i2s.write_mono(apply_volume(sample, volume));
        }
    }
}
