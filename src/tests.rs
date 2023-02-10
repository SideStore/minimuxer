use libc::c_char;
use log::info;
use simplelog::{ColorChoice, ConfigBuilder, LevelFilter, TermLogger, TerminalMode};
use std::ffi::{CStr, CString};
use std::io::{self, Write};
use std::process::Command;
use std::sync::Once;

use crate::errors::Errors;
use crate::provision::minimuxer_remove_provisioning_profiles;

/* Utils */

/// MUST BE CALLED BEFORE EACH TEST
fn init() {
    static INIT: Once = Once::new();

    INIT.call_once(|| {
        TermLogger::init(
            // Allow debug logging
            LevelFilter::max(),
            // Allow logging from everywhere, to include rusty_libimobiledevice and any other useful debugging info
            ConfigBuilder::new()
                .add_filter_ignore_str("plist_plus") // plist_plus spams logs
                .build(),
            TerminalMode::Mixed,
            ColorChoice::Auto,
        )
        .expect("logger failed to initialize");

        info!("Successfully intialized tests");
        println!();
    });
}

fn to_c_char(input: &str) -> *mut c_char {
    let c_str = CString::new(input).unwrap();
    c_str.into_raw() // FIXME: this should cause a memory leak but I had issues with as_ptr() not giving the correct args
}

fn list_profiles() -> String {
    let output = Command::new("ideviceprovision")
        .arg("list")
        .output()
        .expect("failed to execute process");
    info!("{}", output.status);
    io::stdout().write_all(&output.stdout).unwrap();
    io::stderr().write_all(&output.stderr).unwrap();
    String::from_utf8(output.stdout).unwrap()
}

/* Tests */

#[test]
fn remove_profiles() {
    init(); // this must be called before each test to ensure logging works

    info!("Listing profiles before remove");
    let before = list_profiles();
    println!();

    let input = "com.SideStore.SideStore";
    info!("Starting to remove profiles (input: \"{}\")", input);
    println!();
    let output = unsafe { minimuxer_remove_provisioning_profiles(to_c_char(input)) };
    println!();
    info!(
        "Got output: Errors::{:?}",
        Errors::try_from(output).unwrap()
    );

    info!("Listing profiles after remove");
    let after = list_profiles();
    println!();

    assert_ne!(before, after);
}
