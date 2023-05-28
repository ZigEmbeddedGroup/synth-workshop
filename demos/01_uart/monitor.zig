const std = @import("std");
const microzig = @import("microzig");
const rp2040 = microzig.hal;
const time = rp2040.time;
const gpio = rp2040.gpio;
const dma = rp2040.dma;

const workshop = @import("workshop");
const monitor = workshop.monitor;

const uart = rp2040.uart.num(0);

// Set up logging via monitor
pub const std_options = struct {
    pub const logFn = monitor.log;
    pub const log_level = .debug;
};

pub const microzig_options = struct {
    pub const interrupts = monitor.interrupts;
};

pub fn main() !void {
    monitor.apply(.{
        // The monitor makes use of a DMA channel. This function returns a
        // channel that's unused or `null` if none are left. The `.?` means
        // "assume that this is not null". Since our application only ever uses
        // one channel this is fine, but if this assumption is incorrect, you
        // would see a panic in Debug and ReleaseSafe build modes, undefined
        // behavior for ReleaseFast and ReleaseSmall build modes.
        .dma_channel = dma.channel(0),
        .uart = rp2040.uart.num(0),
        .baud_rate = 115200,
        .tx_pin = gpio.num(0), // Use GP0 for TX
        .rx_pin = gpio.num(1), // Use GP1 for RX
        .clock_config = rp2040.clock_config,
    });

    rp2040.uart.init_logger(uart);
    time.sleep_us(100);

    while (true) {
        std.log.info("hello!", .{});

        // pretending to do work here:
        time.sleep_ms(1000);
    }
}
