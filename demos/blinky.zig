//!
//! This example blinks the LED on the RaspberryPi Pico.
//!
//! Prerequisites: none
//!

const std = @import("std");
const microzig = @import("microzig");
const rp2040 = microzig.hal;
const gpio = rp2040.gpio;
const time = rp2040.time;

const led = gpio.num(29);

pub fn main() void {
    // peripherals on the RP2040 are initialized by reseting their state at the
    // beginning of our program. In this instance this step is actually
    // redundant. You will see that `microzig.hal` has a public function `init`
    // that gets called before main and it resets all the peripherals. Wasteful
    // power-wise but perfect for not shooting yourself in the foot. You can
    // override this function by exporting a `fn init() void` from this file

    // multiple functions can be multiplexed onto one GPIO, during
    // initialization we have to select what the pin is going to do, in our
    // case SIO refers to the SIO subsystem: it's just going to be a regular
    // GPIO.
    led.set_function(.sio);

    // GPIO are high impedance inputs by default.
    led.set_direction(.out);

    while (true) {
        led.toggle();

        // this is based off a hardware timer in the RP2040, this is a blocking
        // operation: it just continually polls the timer to see if the
        // deadline has been hit
        time.sleep_ms(1000);
    }
}
