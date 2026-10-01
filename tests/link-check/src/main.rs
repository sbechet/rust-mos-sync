#![no_std]
#![no_main]

use core::ffi::c_int;
use core::panic::PanicInfo;

#[unsafe(no_mangle)]
pub extern "C" fn main() -> c_int {
    0
}

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    loop {}
}
