//! This module provides a view of your synth on the RP2040 by sending data
//! over the UART. It has global fields because it assumes exclusive use of the
//! second core for an FFT transform
//!
//! Assuming a baud rate of 115200, it aims to fill half that bandwidth with
//! FFT frames for visualization on your PC.
const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("microzig");
const rp2040 = microzig.hal;
const gpio = rp2040.gpio;
const clocks = rp2040.clocks;
const time = rp2040.time;
const irq = rp2040.irq;
const dma = rp2040.dma;
const fifo = rp2040.multicore.fifo;

const workshop = @import("workshop.zig");
const Volatile = workshop.Volatile;

const log_length_max = 80;
const buffered_logs_max = 16;
const fft_samples = 32;
const stack_trace_depth_max = 16;

var logs = LogBuffers.init();
var dma_running = Volatile(bool).init(false);
var uart: rp2040.uart.UART = undefined;
var channel: dma.Channel = undefined;

pub const Message = extern struct {
    kind: Kind,

    pub const Kind = enum(u8) {
        log,
        fft,
    };

    pub const LogHeader = packed struct {
        level: std.log.Level,
        len: u16,
    };

    pub const FftHeader = packed struct {
        sample_rate: u24,
        len: u16,
    };
};

pub const interrupts = struct {
    /// This handler runs when the DMA transfer is complete.
    pub fn DMA_IRQ_0() void {
        channel.acknowledge_irq0();
        assert(!channel.is_busy());

        // we're done with the front of the queue
        logs.pop_buffer();

        // TODO: pick highest priority message
        if (!logs.is_empty())
            trigger_dma()
        else
            dma_running.store(false);
    }
};

pub const Config = struct {
    dma_channel: dma.Channel,
    uart: rp2040.uart.UART,
    baud_rate: u32,
    tx_pin: gpio.Pin,
    rx_pin: gpio.Pin,
    clock_config: rp2040.clocks.GlobalConfiguration,
};

pub fn apply(comptime config: Config) void {
    uart = config.uart;
    uart.apply(.{
        .baud_rate = config.baud_rate,
        .tx_pin = config.tx_pin,
        .rx_pin = config.rx_pin,
        .clock_config = config.clock_config,
    });

    channel = config.dma_channel;
    channel.claim();
    channel.set_irq0_enabled(true);

    irq.enable("DMA_IRQ_0");

    std.log.info("================ STARTING MONITOR SESSION ================", .{});
}

pub fn trigger_dma() void {
    assert(!channel.is_busy());

    const first = logs.get_first();
    channel.trigger_transfer(
        @ptrToInt(uart.tx_fifo()),
        @ptrToInt(&first.buffer.buffer),
        first.buffer.len,
        .{
            .transfer_size_bytes = 1,
            .dreq = uart.dreq_tx(),
            .enable = true,
            .read_increment = true,
            .write_increment = false,
        },
    );

    dma_running.store(true);
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_prefix = comptime "[{}.{:0>6}] " ++ level.asText();
    const prefix = comptime level_prefix ++ " ({}) " ++ switch (scope) {
        .default => ": ",
        else => " (" ++ @tagName(scope) ++ "): ",
    };

    // need these off to check on the DMA channel and ensure we don't
    // have a race condition
    microzig.cpu.disable_interrupts();
    defer microzig.cpu.enable_interrupts();

    // If there's no more space then we drop the log
    // TODO: log for how many logs were missed
    if (logs.acquire_buffer()) |volatile_log_entry| {
        const current_time = time.get_time_since_boot();
        const seconds = current_time.to_us() / std.time.us_per_s;
        const microseconds = current_time.to_us() % std.time.us_per_s;

        const log_entry = @volatileCast(volatile_log_entry);
        // if we fail to print a log then something is fishy
        log_entry.buffer.writer().print(prefix ++ format ++ "\r\n", .{ seconds, microseconds, log_entry.missed } ++ args) catch {
            @panic("failed to print a log, maybe buffer was too small?");
        };

        // if the channel is busy then we can rely on the interrupt
        // handler to continue processing logs. But if it stopped then we
        // need to trigger another transfer
        if (!dma_running.load_with_disabled_irqs())
            trigger_dma();
    } else {
        // There are no more log buffers, we will increment the number of
        // missed logs on the newest entry to the queue
        logs.get_last().missed += 1;
    }
}

const LogBuffers = struct {
    items: [buffered_logs_max]Log,
    start: u32,
    len: u32,

    const Self = @This();
    const Log = struct {
        missed: usize,
        buffer: std.BoundedArray(u8, 3 + log_length_max),
    };

    pub fn init() Self {
        return Self{
            .items = undefined,
            .start = 0,
            .len = 0,
        };
    }

    pub fn is_empty(self: *const volatile Self) bool {
        return self.len == 0;
    }

    pub fn is_full(self: *const volatile Self) bool {
        return self.len == self.items.len;
    }

    pub fn get_first(self: *const volatile Self) *const volatile Log {
        assert(!self.is_empty());

        return &self.items[self.start];
    }

    pub fn get_last(self: *volatile Self) *volatile Log {
        return &self.items[(self.start + self.len) % buffered_logs_max];
    }

    pub fn acquire_buffer(self: *volatile Self) ?*volatile Log {
        if (self.len >= buffered_logs_max)
            return null;

        const index = (self.start + self.len) % buffered_logs_max;
        self.len += 1;

        const ret = &self.items[index];
        ret.buffer.len = 0;
        ret.missed = 0;
        return ret;
    }

    pub fn pop_buffer(self: *volatile Self) void {
        self.len -= 1;
        self.start += 1;
        self.start %= buffered_logs_max;
    }
};
