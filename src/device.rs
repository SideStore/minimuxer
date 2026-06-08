use std::{
    sync::{atomic::Ordering, Mutex},
    time::Duration,
};

use crate::{muxer::STARTED, Errors, Res};
use log::{error, info, warn};
use once_cell::sync::Lazy;
use rusty_libimobiledevice::idevice::{self, Device};

/// Cached UDID from the pairing file — fallback when C library can't detect device (iOS 26+)
pub static PAIRING_UDID: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

/// Called by muxer after parsing the pairing file to cache the UDID
pub fn set_pairing_udid(udid: String) {
    if let Ok(mut cache) = PAIRING_UDID.lock() {
        *cache = Some(udid);
        info!("Cached pairing UDID for fallback");
    }
}

#[swift_bridge::bridge]
mod ffi {
    #[swift_bridge(already_declared, swift_name = "MinimuxerError")]
    enum Errors {}

    extern "Rust" {
        fn fetch_udid() -> Option<String>;
        fn test_device_connection() -> bool;
    }
}

/// Waits for the muxer to return the device
///
/// This ensures that the muxer is running
///
/// Returns an error once the timeout expires
///
/// Timeout is 5 seconds, 250 ms sleep between attempts
///
/// On iOS 26+, the C library may fail to detect the device even when the
/// pairing file is valid. This function falls back to constructing a Device
/// from the cached pairing UDID when the C library returns no devices.
pub fn fetch_first_device() -> Res<Device> {
    const TIMEOUT: u16 = 5000;
    const SLEEP: u16 = 250;

    let mut t = TIMEOUT;
    loop {
        match idevice::get_first_device() {
            Ok(d) => return Ok(d),
            Err(_e) => {
                t -= SLEEP;
                if t == 0 {
                    break;
                }
            }
        }
        std::thread::sleep(Duration::from_millis(SLEEP.into()));
    }

    // C library failed — try the pairing file UDID fallback (iOS 26 fix)
    warn!("C library could not find device, trying pairing file UDID fallback");
    if let Ok(cache) = PAIRING_UDID.lock() {
        if let Some(ref udid) = *cache {
            info!("Using cached pairing UDID: {}", udid);
            let ip = Some(std::net::IpAddr::V4(std::net::Ipv4Addr::new(10, 7, 0, 1)));
            return Ok(Device::new(udid.clone(), ip, 420));
        }
    }

    error!("No device found via C library or pairing file fallback");
    Err(Errors::NoDevice)
}

/// Tests if the device is on and listening without jumping through hoops
pub fn test_device_connection() -> bool {
    #[cfg(test)]
    {
        info!("Skipping device connection test since we're in a test");
        true
    }

    #[cfg(not(test))]
    {
        use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpStream};

        // Connect to lockdownd's socket
        TcpStream::connect_timeout(
            &SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(10, 7, 0, 1), 62078)),
            Duration::from_millis(100),
        )
        .is_ok()
    }
}

pub fn fetch_udid() -> Option<String> {
    info!("Getting UDID for first device");

    if !STARTED.load(Ordering::Relaxed) {
        error!("minimuxer has not started!");
        return None;
    }

    match fetch_first_device().map(|d| d.get_udid()) {
        Ok(s) => {
            info!("Success: {}", s);
            Some(s)
        }
        _ => {
            error!("Failed to get UDID! Device not connected?");
            None
        }
    }
}
