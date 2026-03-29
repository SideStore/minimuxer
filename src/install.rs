// Jackson Coxson

use idevice::{
    afc::{opcode::AfcFopenMode, AfcClient},
    installation_proxy::InstallationProxyClient,
};
use log::{error, info};
use plist::{Dictionary, Value};
use plist_plus::Plist;
use rusty_libimobiledevice::services::afc::AfcFileMode;
use tokio::io::AsyncWriteExt;

use crate::{
    device::{fetch_first_device, test_device_connection},
    muxer::IS_RPPAIRING,
    rsd::connect_to_rsd_services,
    Errors, PlistPlusConversion, Res, RUNTIME,
};

#[swift_bridge::bridge]
mod ffi {
    #[swift_bridge(already_declared, swift_name = "MinimuxerError")]
    enum Errors {}

    extern "Rust" {
        fn yeet_app_afc(bundle_id: String, ipa_bytes: &[u8]) -> Result<(), Errors>;
        fn install_ipa(bundle_id: String) -> Result<(), Errors>;
        fn remove_app(bundle_id: String) -> Result<(), Errors>;
    }
}

const PKG_PATH: &str = "PublicStaging";

/// Yeets an ipa to the afc jail
pub fn yeet_app_afc(bundle_id: String, ipa_bytes: &[u8]) -> Res<()> {
    info!("Yeeting IPA for bundle ID: {}", bundle_id);

    if !test_device_connection() {
        error!("No device connection");
        return Err(Errors::NoConnection);
    }

    if *IS_RPPAIRING.get().unwrap_or(&false) {
        return yeet_app_afc_rppairing(bundle_id, ipa_bytes);
    }

    let device = fetch_first_device()?;

    // Start an AFC client
    let afc = match device.new_afc_client("minimuxer") {
        Ok(afc) => afc,
        Err(e) => {
            error!("Error: Could not start AFC service: {:?}", e);
            return Err(Errors::CreateAfc);
        }
    };

    // Check if PublicStaging exists
    match afc.get_file_info(format!("./{PKG_PATH}")) {
        Ok(_) => {}
        Err(_) => match afc.make_directory(format!("./{PKG_PATH}")) {
            Ok(_) => match afc.get_file_info(format!("./{PKG_PATH}")) {
                Ok(_) => {}
                Err(e) => {
                    error!("Unable to read PublicStaging info: {:?}", e);
                    return Err(Errors::RwAfc);
                }
            },
            Err(e) => {
                error!("Unable to make PublicStaging directory: {:?}", e);
                return Err(Errors::RwAfc);
            }
        },
    };
    info!("Created PublicStaging directory");

    // Create bundle ID folder
    match afc.get_file_info(format!("./{PKG_PATH}/{bundle_id}")) {
        Ok(_) => {}
        Err(_) => match afc.make_directory(format!("./{PKG_PATH}/{bundle_id}")) {
            Ok(_) => match afc.get_file_info(format!("./{PKG_PATH}/{bundle_id}")) {
                Ok(_) => {}
                Err(e) => {
                    error!("Unable to read bundle ID info: {:?}", e);
                    return Err(Errors::RwAfc);
                }
            },
            Err(e) => {
                error!("Unable to make bundle ID directory: {:?}", e);
                return Err(Errors::RwAfc);
            }
        },
    };
    info!("Created bundle ID directory");

    // Yeet app pls
    let handle = match afc.file_open(
        format!("./{PKG_PATH}/{bundle_id}/app.ipa"),
        AfcFileMode::WriteOnly,
    ) {
        Ok(h) => h,
        Err(e) => {
            error!("Unable to open file on device: {:?}", e);
            return Err(Errors::RwAfc);
        }
    };

    info!("Sending bytes of ipa");
    match afc.file_write(handle, ipa_bytes.to_vec()) {
        Ok(_) => {
            info!("Success");
            Ok(())
        }
        Err(e) => {
            error!("Unable to write ipa: {:?}", e);
            Err(Errors::RwAfc)
        }
    }
}

/// Installs an ipa with a bundle ID
/// Expects the ipa to be in the afc jail from yeet_app_afc
pub fn install_ipa(bundle_id: String) -> Res<()> {
    info!("Installing app for bundle ID: {}", bundle_id);

    if !test_device_connection() {
        error!("No device connection");
        return Err(Errors::NoConnection);
    }

    if *IS_RPPAIRING.get().unwrap_or(&false) {
        return install_ipa_rppairing(bundle_id);
    }

    let device = fetch_first_device()?;

    // normally, we use client_options_new: https://github.com/jkcoxson/rusty_libimobiledevice/blob/master/src/services/instproxy.rs#L123
    // however, this literally just creates an empty dictionary: https://github.com/libimobiledevice/libimobiledevice/blob/master/src/installation_proxy.c#L919-L922
    // using this caused libplist to crash, no idea why, so I ported it to rusty plist
    let mut client_opts = Dictionary::new();
    client_opts.insert("CFBundleIdentifier".into(), bundle_id.clone().into());

    let inst_client = match device.new_instproxy_client("ideviceinstaller") {
        Ok(i) => i,
        Err(e) => {
            error!("Unable to start instproxy: {:?}", e);
            return Err(Errors::CreateInstproxy);
        }
    };

    info!("Installing");
    match inst_client.install(
        format!("./{PKG_PATH}/{bundle_id}/app.ipa"),
        Some(
            Plist::from_rusty_plist(&Value::Dictionary(client_opts))
                .unwrap()
                .clone(), // clone fixes crash for some reason
        ),
    ) {
        Ok(_) => {
            info!("Done!");
            Ok(())
        }
        Err(e) => {
            // rusty_libimobiledevice will log an error that's better
            // error!("Unable to install app: {:?}: {}", err, description);
            Err(Errors::InstallApp(e.1))
        }
    }
}

/// Removes an app from the device
pub fn remove_app(bundle_id: String) -> Res<()> {
    info!("Removing app for {}", bundle_id);

    if !test_device_connection() {
        error!("No device connection");
        return Err(Errors::NoConnection);
    }

    if *IS_RPPAIRING.get().unwrap_or(&false) {
        return remove_app_rppairing(bundle_id);
    }

    let device = fetch_first_device()?;

    let instproxy_client = match device.new_instproxy_client("minimuxer-remove-app") {
        Ok(i) => i,
        Err(e) => {
            error!("Unable to start instproxy: {:?}", e);
            return Err(Errors::CreateInstproxy);
        }
    };

    info!("Removing");
    match instproxy_client.uninstall(bundle_id, None) {
        Ok(_) => {
            info!("Done!");
            Ok(())
        }
        Err(e) => {
            error!("Unable to uninstall app!! {:?}", e);
            Err(Errors::UninstallApp)
        }
    }
}

fn yeet_app_afc_rppairing(bundle_id: String, ipa_bytes: &[u8]) -> Res<()> {
    RUNTIME.block_on(async move {
        let mut afc = connect_to_rsd_services::<AfcClient>()
            .await
            .map_err(|_| Errors::CreateAfc)?;

        ensure_afc_directory(&mut afc, PKG_PATH).await?;
        ensure_afc_directory(&mut afc, &format!("{PKG_PATH}/{bundle_id}")).await?;

        let path = format!("{PKG_PATH}/{bundle_id}/app.ipa");
        let mut handle = afc.open(&path, AfcFopenMode::WrOnly).await.map_err(|e| {
            error!("Unable to open file on device: {e:?}");
            Errors::RwAfc
        })?;

        handle.write_all(ipa_bytes).await.map_err(|e| {
            error!("Unable to write ipa: {e:?}");
            Errors::RwAfc
        })?;

        handle.shutdown().await.map_err(|e| {
            error!("Unable to flush ipa contents: {e:?}");
            Errors::RwAfc
        })?;

        handle.close().await.map_err(|e| {
            error!("Unable to close file handle: {e:?}");
            Errors::RwAfc
        })?;

        Ok(())
    })
}

fn install_ipa_rppairing(bundle_id: String) -> Res<()> {
    RUNTIME.block_on(async move {
        let mut inst_client = connect_to_rsd_services::<InstallationProxyClient>()
            .await
            .map_err(|_| Errors::CreateInstproxy)?;

        let mut client_opts = Dictionary::new();
        client_opts.insert("CFBundleIdentifier".into(), bundle_id.clone().into());

        inst_client
            .install(
                format!("{PKG_PATH}/{bundle_id}/app.ipa"),
                Some(Value::Dictionary(client_opts)),
            )
            .await
            .map_err(map_install_error)
    })
}

fn remove_app_rppairing(bundle_id: String) -> Res<()> {
    RUNTIME.block_on(async move {
        let mut inst_client = connect_to_rsd_services::<InstallationProxyClient>()
            .await
            .map_err(|_| Errors::CreateInstproxy)?;

        inst_client.uninstall(bundle_id, None).await.map_err(|e| {
            error!("Unable to uninstall app!! {e:?}");
            Errors::UninstallApp
        })
    })
}

async fn ensure_afc_directory(afc: &mut AfcClient, path: &str) -> Res<()> {
    if afc.get_file_info(path).await.is_err() {
        afc.mk_dir(path).await.map_err(|e| {
            error!("Unable to make directory {path}: {e:?}");
            Errors::RwAfc
        })?;

        afc.get_file_info(path).await.map_err(|e| {
            error!("Unable to read directory info for {path}: {e:?}");
            Errors::RwAfc
        })?;
    }

    Ok(())
}

fn map_install_error(error: idevice::IdeviceError) -> Errors {
    error!("Unable to install app: {error:?}");
    Errors::InstallApp(error.to_string())
}
