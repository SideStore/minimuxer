
use log::{error, trace};
use crate::{errors::Errors, fetch_first_device, test_device_connection};
use rusty_libimobiledevice::{ service::ServiceClient};

#[no_mangle]
/// is device connect
/// # Safety
/// Don't be stupid
pub unsafe extern "C" fn minimuxer_isconnect() -> libc::c_int {

    if !test_device_connection() {
        return Errors::NoConnection.into();
    }

    trace!("Getting device from muxer");
    let _device = match fetch_first_device(Some(5000)) {
        Ok(d) => d,
        Err(e) => {
            error!("Unable to get device: {:?}", e);
            return Errors::NoDevice.into();
        }
    };

    return Errors::Success.into();
}

#[no_mangle]
/// set ios location
/// # Safety
/// Don't be stupid
pub unsafe extern "C" fn minimuxer_set_location(latitude: *mut libc::c_char,longitude: *mut libc::c_char,mode:libc::c_int) -> libc::c_int {
    if latitude.is_null() ||  longitude.is_null(){
        return Errors::FunctionArgs.into();
    }

    // let mode = 0;

    let latitude_c_str = std::ffi::CStr::from_ptr(latitude);

    let latitude = match latitude_c_str.to_str() {
        Ok(s) => s,
        Err(_) => return Errors::FunctionArgs.into(),
    }
    .to_string();

    let longitude_c_str = std::ffi::CStr::from_ptr(longitude);

    let longitude = match longitude_c_str.to_str() {
        Ok(s) => s,
        Err(_) => return Errors::FunctionArgs.into(),
    }
    .to_string();

    if !test_device_connection() {
        return Errors::NoConnection.into();
    }

    trace!("Getting device from muxer");
    let device = match fetch_first_device(Some(5000)) {
        Ok(d) => d,
        Err(e) => {
            error!("Unable to get device: {:?}", e);
            return Errors::NoDevice.into();
        }
    };

    // Start a generic service on the device. rusty_libimobiledevice currently doesn't have built in abstractions
    // for location services, but we can manually send packets through a generic service.
    let mut lockdown_client = match device.new_lockdownd_client("idevicelocation") {
        Ok(l) => l,
        Err(e) => {
            println!("Error starting lockdown client: {:?}", e);
            return Errors::NoConnection.into();
        }
    };
    let service = match lockdown_client.start_service("com.apple.dt.simulatelocation", false) {
        Ok(s) => s,
        Err(e) => {
            println!("Unable to start service: {:?}", e);
            return Errors::NoConnection.into();
        }
    };
    let service = match ServiceClient::new(&device, service) {
        Ok(s) => s,
        Err(e) => {
            println!("Unable to convert service client: {:?}", e);
            return Errors::NoConnection.into();
        }
    };

    if mode == 0 {
        // Send the starting bytes
        match service.send([0, 0, 0, 0].to_vec()) {
            Ok(_) => {}
            Err(e) => {
                println!("Error sending start byte: {:?}", e);
                return Errors::NoConnection.into();
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
                println!("Unable to send latitude length: {:?}", e);
                return Errors::NoConnection.into();
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
                println!("Unable to send latitude: {:?}", e);
                return Errors::NoConnection.into();
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
                println!("Unable to send longitude length: {:?}", e);
                return Errors::NoConnection.into();
            }
        }
        let longitude = longitude
            .as_bytes()
            .iter()
            .map(|x| *x as i8)
            .collect::<Vec<i8>>()
            .to_vec();
        match service.send(longitude) {
            Ok(_) => {}
            Err(e) => {
                println!("Unable to send longitude: {:?}", e);
                return Errors::NoConnection.into();
            }
        }

        println!("Done");
        return Errors::Success.into();
    }else{
        match service.send([0, 0, 0, 1].to_vec()) {
            Ok(_) => {
                println!("Stopped successfully");
                return Errors::Success.into();
            }
            Err(e) => {
                println!("Error stopping: {:?}", e);
                return Errors::NoConnection.into();
            }
        }
    }

}
