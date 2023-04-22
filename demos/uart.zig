//! This example showcases how to use the serial communication component,
//! the UART.
//!
//! UART stands for Universal Asynchronous Receiver and Transmitter,
//! a device that implements a typical serial communication.
//!
//! The RP2040 has two UART components, we're using the UART 0, which can be
//! connected to pins GP0 (TX) and GP1 (RX).
//!
//! Attach a serial adapter to it to receive the data on your PC.
//! NOTE: Don't forget to cross over the wires, the RP2040 TX must be
//! connected to the serial adapter RX, and the RP2040 RX must be connected
//! to the serial adapter TX. Also make sure that the serial adapter is using
//! 3.3V instead of 5V.
//!
//! This example implements a basic echo example, which will return every character
//! you type except for the ascii characters 'Z', 'I' and 'G'.
//! Typing one of these letters will panic the code to showcase the microzig panic handler.
//!
//! Prerequisites: none
//!

const std = @import("std");
const microzig = @import("microzig");
const rp2040 = microzig.hal;
const time = rp2040.time;
const gpio = rp2040.gpio;

const uart = rp2040.uart.num(0);

// Set up logging via UART
pub const std_options = struct {
    pub const logFn = rp2040.uart.log;
    pub const log_level = .debug;
};

pub fn main() !void {
    // Configure the UART component 0:
    uart.apply(.{
        // This is the symbol rate ("bit rate") of the serial port.
        // Note that this isn't the bandwidth of the port, as the baud rate
        // also contains start and stop bits.
        // As we don't configure word_bits, stop_bits and parity, these values
        // will be the standard "8N1" (8 data bits, no parity, 1 stop bit).
        // This means, our actual transfer rate is:
        // 115200 baud / (8 data bits + 1 start bit + 0 parity bits + 1 stop bit) = 11520 kB/s
        .baud_rate = 115200,
        .tx_pin = gpio.num(0), // Use GP0 for TX
        .rx_pin = gpio.num(1), // Use GP1 for RX

        // initializing the uart requires information about
        // timings, so we're passing that in as well
        .clock_config = rp2040.clock_config,
    });
    // Set the now configured uart as the logging target for microzig.
    rp2040.uart.init_logger(uart);

    // Sleep for a short moment of time to let the serial lanes settle.
    // Otherwise, we'll get spurious characters transmitted after reset.
    // This happens as we reset quite fast, so for a short period, a low
    // level is set on the pin. This will be recognized as a transmission
    // of 0xFF.
    time.sleep_us(100);

    const reader = uart.reader();
    const writer = uart.writer();

    try writer.writeAll("Let's talk!\r\n");

    while (true) {
        const char = try reader.readByte();
        switch (char) {
            'Z', 'I', 'G' => @panic("Illegal character used. Please do not type ZIG."),
            '\r' => try writer.writeAll("\r\n"), // translate CR to CR LF for terminal niceness
            else => try writer.writeByte(char),
        }
    }
}
