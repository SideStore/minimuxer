
use idevice::{remote_pairing::{RemotePairingClient, RpPairingSocket}, rsd::RsdHandshake};
use log::error;
use once_cell::sync::Lazy;

use crate::{Errors, Res, muxer::{IS_RPPAIRING, RPPAIRING_FILE}};
use std::{net::SocketAddrV4, str::FromStr, sync::{Mutex, OnceLock}};

type RsdAdapter = idevice::tcp::handle::AdapterHandle;

pub struct CachedRsdConnection {
    pub adapter: RsdAdapter,
    pub handshake: RsdHandshake,
}

static RPPAIRING_RSD_CONNECTION: OnceLock<Mutex<CachedRsdConnection>> = OnceLock::new();


pub async fn get_or_create_rppairing_rsd_connection() -> Res<&'static Mutex<CachedRsdConnection>> {
    if let Some(connection) = RPPAIRING_RSD_CONNECTION.get() {
        error!("using existing connection");
        return Ok(connection);
    }
    error!("creating connection");
    match create_rppairing_rsd_connection().await {
        Ok(conn) => {
            RPPAIRING_RSD_CONNECTION.set(Mutex::new(conn)).ok();
            return Ok(RPPAIRING_RSD_CONNECTION.get().unwrap());
        }
        Err(e) => return Err(e)
    };
}

async fn create_rppairing_rsd_connection() -> Res<CachedRsdConnection> {
    let mut pairing_file = match RPPAIRING_FILE.get() {
        Some(p) => p.clone(),
        None => {
            error!("No PairingFile");
            return Err(Errors::PairingFile);
        }
    };

    let socket_addr = SocketAddrV4::from_str("10.7.0.1:49152").unwrap();
    let stream = match tokio::net::TcpStream::connect(socket_addr).await {
        Ok(s) => s,
        Err(_) => {
            return Err(Errors::NoConnection);
        }
    };

    let conn = RpPairingSocket::new(stream);

    let mut rpc = RemotePairingClient::new(conn, &"minimuxer", &mut pairing_file);
    match rpc.connect(async |_| "000000".to_string(), 0u8).await {
        Ok(connection) => connection,
        Err(_) => {
            return Err(Errors::Connect);
        }
    };

    use idevice::remote_pairing::connect_tls_psk_tunnel_native;

    let tunnel_port = rpc
        .create_tcp_listener()
        .await
        .map_err(|_| Errors::Connect)?;

    let tunnel_addr = std::net::SocketAddr::new(std::net::IpAddr::V4(*socket_addr.ip()), tunnel_port);
    let tunnel_stream = tokio::net::TcpStream::connect(tunnel_addr)
        .await
        .map_err(|_| Errors::Connect)?;
    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key())
        .await
        .map_err(|_| Errors::Connect)?;

    let client_ip: std::net::IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|_| Errors::Connect)?;
    let server_ip: std::net::IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|_| Errors::Connect)?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;

    let raw = tunnel.into_inner();
    let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(raw), client_ip, server_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();

    let rsd_stream = adapter.connect(rsd_port).await.map_err(|_| Errors::Connect)?;
    let handshake = RsdHandshake::new(rsd_stream)
        .await
        .map_err(|_| Errors::Connect)?;

    Ok(CachedRsdConnection { adapter, handshake })
}