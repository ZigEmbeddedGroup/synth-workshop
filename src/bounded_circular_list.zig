//! Circular Buffer with max length

pub fn BoundedCircularBuffer(comptime T: type, comptime max_len: usize) type {
    return struct {
        items: [max_len]T,
        start: usize,
        len: usize,

        const Self = @This();

        pub fn init() Self {
            return Self{
                .items = undefined,
                .start = 0,
                .len = 0,
            };
        }
    };
}
