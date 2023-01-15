// Jackson Coxson

use libc::{c_int, c_uint};
use log::{error, info};
use plist_plus::Plist;
use rusty_libimobiledevice::idevice;

use crate::{errors::Errors, fetch_first_device, test_device_connection};

#[no_mangle]
/// Installs a provisioning profile on the device
/// # Arguments
/// Pass a pointer to a plist
/// # Returns
/// 0 on success
/// # Safety
/// Don't be stupid
pub unsafe extern "C" fn minimuxer_install_provisioning_profile(
    pointer: *mut u8,
    len: c_uint,
) -> c_int {
    let len = len as usize;
    let data = Vec::from_raw_parts(pointer, len, len);
    let plist = Plist::new_data(&data);
    std::mem::forget(data);

    if !test_device_connection() {
        return Errors::NoConnection.into();
    }

    let device = match fetch_first_device(Some(5000)) {
        Ok(d) => d,
        Err(_) => return Errors::NoDevice.into(),
    };
    let mis_client = match device.new_misagent_client("minimuxer-install-prov") {
        Ok(m) => m,
        Err(_) => {
            return Errors::CreateMisagent.into();
        }
    };
    match mis_client.install(plist) {
        Ok(_) => {}
        Err(e) => {
            error!("Unable to install provisioning profile: {:?}", e);
            return Errors::ProfileInstall.into();
        }
    }
    info!("Minimuxer finished installing profile!!");

    Errors::Success.into()
}

#[no_mangle]
/// Removes a provisioning profile
/// # Safety
/// Don't be stupid
pub unsafe extern "C" fn minimuxer_remove_provisioning_profile(id: *mut libc::c_char) -> c_int {
    if id.is_null() {
        return Errors::FunctionArgs.into();
    }

    let c_str = std::ffi::CStr::from_ptr(id);

    let id = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return Errors::FunctionArgs.into(),
    }
    .to_string();

    if !test_device_connection() {
        return Errors::NoConnection.into();
    }

    let device = match idevice::get_first_device() {
        Ok(d) => d,
        Err(_) => return Errors::NoDevice.into(),
    };
    let mis_client = match device.new_misagent_client("minimuxer-install-prov") {
        Ok(m) => m,
        Err(_) => {
            return Errors::CreateInstproxy.into();
        }
    };
    match mis_client.remove(id) {
        Ok(_) => {}
        Err(e) => {
            error!("Unable to remove provisioning profile: {:?}", e);
            return Errors::ProfileRemove.into();
        }
    }
    info!("Minimuxer finished removing profile!!");

    Errors::Success.into()
}

#[no_mangle]
/// Removes provisioning profiles excluding the passed ids
/// NOTE: Unfinished, WIP
/// # Safety
/// Don't be stupid
pub unsafe extern "C" fn minimuxer_remove_inactive_profiles(ids: *const *const libc::c_char, count: c_int) -> c_int {
    if !test_device_connection() {
        return Errors::NoConnection.into();
    }

    let device = match idevice::get_first_device() {
        Ok(d) => d,
        Err(_) => return Errors::NoDevice.into(),
    };

    let mis_client = match device.new_misagent_client("minimuxer-install-prov") {
        Ok(m) => m,
        Err(_) => {
            return Errors::CreateInstproxy.into();
        }
    };

    let mut i: i32 = 0;
    while i != count {
        let id = std::ffi::CStr::from_ptr(*ids.add(i.try_into().unwrap()));
        let id_str = id.to_str().unwrap();
        println!("Rust ID: {}", id_str); // Just to confirm we received the correct Swift strings
        i += 1;
    }

    // Get all certs from misagent service, so we can check against them
    let all_ids = match mis_client.copy(false) {
        Ok(m) => m,
        Err(_) => {
            return Errors::ProfileRemove.into();
        }
    };

    // Get array size, otherwise we can't iter over the plist at all(?)
    println!("all_ids plist array size: {:?}", all_ids.clone().array_get_size().unwrap());
    let p_size = match all_ids.clone().array_get_size() {
        Ok(m) => m,
        Err(_) => {
            return Errors::ProfileRemove.into();
        }
    };

    println!("Before loop");
    for i in 0..p_size {
        // Attempt to get the cert
        let cert = match all_ids.array_get_item(i) {
            Ok(c) => c,
            Err(_) => {
                // Just 'log' error and return error, otherwise iOS crashes
                println!("Error getting cert");
                return Errors::ProfileRemove.into();
            }
        };
        // If we made it here, presume success, now try to get the cert data
        let cert_data = match cert.get_data_val() {
            Ok(d) => d,
            Err(_) => {
                return Errors::ProfileRemove.into();
            }
        };
        // 'log' length of data to prove there is something there
        println!("Cert #{}: {:?}", i, cert_data.len());

        // TODO: Actual parsing of the data
        /* Current explanation of cert data, no clue how to do this in Rust, but here goes..
         * First we have to actually extract the plist xml data from cert_data above
         * As far as I have seen, we can skip the first 62 bytes of data, and then read up until
         * b"</plist>" (after the plist is the cert signature, I *presume*, but we don't need that
         *
         * All we need to do is then go through each cert, and compare with the ids we were passed
         * from Swift. If the cert's bundle id isn't in the passed Swift, we delete it.
         *
         * TODO: Fix duplicate certificates being stored on device
         * Check for the *earliest* cert we can, and delete all the older ones, *if* possible.
         * Haven't checked libimobiledevice, so unsure if we can remove certs based off UUID or
         * something other than bundle id.
         * */
    }

    println!("Got through minimuxer, ggez");

    Errors::Success.into()
}

