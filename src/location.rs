// Original author: https://github.com/hw-1/minimuxer
// Modified to adapt `swift_bridge`

use log::{error, info};
use rusty_libimobiledevice::{ service::ServiceClient};

use crate::{
    device::{fetch_first_device, test_device_connection},
    Errors, Res, 
};

#[swift_bridge::bridge]
mod ffi {
    #[swift_bridge(already_declared, swift_name = "MinimuxerError")]
    enum Errors {}

    extern "Rust" {
        fn set_location(latitude: String, longitude: String, mode: i32) -> Result<(), Errors>;
    }
}

/// Set or reset device location
///
/// latitude / longitude: The decimal string
/// mode : 0 (set location) or 1 (reset location [May not work])
pub fn set_location(latitude: String, longitude: String, mode: i32) -> Res<()> {
    info!("Set location at LON {}, LAT {}", latitude, longitude);

    if !test_device_connection() {
        return Err(Errors::NoConnection);
    }

    let device  = fetch_first_device()?;

    // Start a generic service on the device. rusty_libimobiledevice currently doesn't have built in abstractions
    // for location services, but we can manually send packets through a generic service.
    let mut lockdown_client = match device.new_lockdownd_client("idevicelocation") {
        Ok(l) => l,
        Err(e) => {
            error!("Error starting lockdown client: {:?}", e);
            return Err(Errors::LockdownClient);
        }
    };

    let service = match lockdown_client.start_service("com.apple.dt.simulatelocation", false) {
        Ok(s) => s,
        Err(e) => {
            error!("Error starting simulatelocation service: {:?}\nMake sure a developer disk image is mounted!", e);
            return Err(Errors::StartLocService);
        }
    };

    let service = match ServiceClient::new(&device, service) {
        Ok(s) => s,
        Err(e) => {
            error!("Error connecting to simulatelocation service {:?}", e);
            return Err(Errors::ConnectLocService);
        }
    };

    if mode == 0 {
        // Send the starting bytes
        match service.send([0, 0, 0, 0].to_vec()) {
            Ok(_) => {}
            Err(e) => {
                error!("Error sending start byte: {:?}", e);
                return Err(Errors::SendLocData);
            }
        }

        // Send latitude
        let lat_len = (latitude.len() as u32).to_be_bytes();
        let lat_len = lat_len
            .iter()
            .map(|x| *x as i8)
            .collect::<Vec<i8>>()
            .to_vec();
        match service.send(lat_len) {
            Ok(_) => {}
            Err(e) => {
                error!("Error sending latitude length: {:?}", e);
                return Err(Errors::SendLocData);
            }
        }
        let latitude = latitude
            .as_bytes()
            .iter()
            .map(|x| *x as i8)
            .collect::<Vec<i8>>()
            .to_vec();
        match service.send(latitude) {
            Ok(_) => {}
            Err(e) => {
                error!("Error sending latitude: {:?}", e);
                return Err(Errors::SendLocData);
            }
        }

        // Send longitude
        let lon_len = (longitude.len() as u32).to_be_bytes();
        let lon_len = lon_len
            .iter()
            .map(|x| *x as i8)
            .collect::<Vec<i8>>()
            .to_vec();
        match service.send(lon_len) {
            Ok(_) => {}
            Err(e) => {
                error!("Error sending longitude length: {:?}", e);
                return Err(Errors::SendLocData);
            }
        }
        let longitude = longitude
            .as_bytes()
            .iter()
            .map(|x| *x as i8)
            .collect::<Vec<i8>>()
            .to_vec();
        match service.send(longitude) {
            Ok(res) => {
                info!("Successfully set location: {:?}", res);
                Ok(())
            }
            Err(e) => {
                error!("Error sending longitude: {:?}", e);
                return Err(Errors::SendLocData);
            }
        }
    }else{
        // Reset location
        match service.send([0, 0, 0, 1].to_vec()) {
            Ok(res) => {
                info!("Successfully reset location: {:?}", res);
                Ok(())
            }
            Err(e) => {
                error!("Error sending start byte: {:?}", e);
                return Err(Errors::SendLocData);
            }
        }
    }
}