use idevice::{
    heartbeat::HeartbeatClient,
    remote_pairing::{RemotePairingClient, RpPairingSocket},
    rsd::RsdHandshake,
    IdeviceError, RsdService,
};

use log::{error, info};

use crate::{muxer::RPPAIRING_FILE, Errors, Res};
use std::{
    net::SocketAddrV4,
    str::FromStr,
    sync::{Mutex, OnceLock},
};

type RsdAdapter = idevice::tcp::handle::AdapterHandle;

pub struct CachedRsdConnection {
    pub adapter: RsdAdapter,
    pub handshake: RsdHandshake,
}

static RPPAIRING_RSD_CONNECTION: OnceLock<Mutex<CachedRsdConnection>> = OnceLock::new();

pub async fn connect_to_rsd_services<Service: RsdService>() -> Result<Service, IdeviceError> {
    if let Some(connection) = RPPAIRING_RSD_CONNECTION.get() {
        let mut guard = connection.lock().unwrap();
        let conn = &mut *guard;
        match Service::connect_rsd(&mut conn.adapter, &mut conn.handshake).await {
            Ok(r) => {
                info!("using existing connection");
                return Ok(r);
            }
            Err(e) => {
                match e {
                    IdeviceError::Socket(_) => {
                        // reconnect
                    }
                    _ => {
                        return Err(e);
                    }
                }
            }
        }
    }
    match create_rppairing_rsd_connection().await {
        Ok(conn) => {
            info!("creating new connection");
            let mut guard: std::sync::MutexGuard<'_, CachedRsdConnection>;
            if let Some(old_connection) = RPPAIRING_RSD_CONNECTION.get() {
                guard = old_connection.lock().unwrap();
                guard.adapter = conn.adapter;
                guard.handshake = conn.handshake;
            } else {
                RPPAIRING_RSD_CONNECTION.set(Mutex::new(conn)).ok();
                guard = RPPAIRING_RSD_CONNECTION.get().unwrap().lock().unwrap();
            }
            let conn = &mut *guard;
            match Service::connect_rsd(&mut conn.adapter, &mut conn.handshake).await {
                Ok(r) => return Ok(r),
                Err(e) => {
                    return Err(e);
                }
            }
        }
        Err(e) => return Err(e),
    };
}

pub async fn get_or_create_rppairing_rsd_connection(
) -> Res<std::sync::MutexGuard<'static, CachedRsdConnection>> {
    if let Some(connection) = RPPAIRING_RSD_CONNECTION.get() {
        let mut guard = connection.lock().unwrap();
        let conn = &mut *guard;
        if HeartbeatClient::connect_rsd(&mut conn.adapter, &mut conn.handshake)
            .await
            .is_ok()
        {
            error!("using existing connection");
            return Ok(guard);
        }
    }
    match create_rppairing_rsd_connection().await {
        Ok(conn) => {
            error!("creating new connection");
            if let Some(old_connection) = RPPAIRING_RSD_CONNECTION.get() {
                let mut guard = old_connection.lock().unwrap();
                guard.adapter = conn.adapter;
                guard.handshake = conn.handshake;
                return Ok(guard);
            } else {
                RPPAIRING_RSD_CONNECTION.set(Mutex::new(conn)).ok();
                return Ok(RPPAIRING_RSD_CONNECTION.get().unwrap().lock().unwrap());
            }
        }
        Err(e) => {
            error!("create_rppairing_rsd_connection failed: {}", e);
            return Err(Errors::Connect);
        }
    };
}

async fn create_rppairing_rsd_connection() -> Result<CachedRsdConnection, IdeviceError> {
    let mut pairing_file = match RPPAIRING_FILE.get() {
        Some(p) => p.clone(),
        None => {
            error!("No PairingFile");
            return Err(IdeviceError::PairVerifyFailed);
        }
    };

    let socket_addr = SocketAddrV4::from_str("10.7.0.1:49152").unwrap();
    let stream = match tokio::net::TcpStream::connect(socket_addr).await {
        Ok(s) => s,
        Err(e) => {
            return Err(IdeviceError::Socket(e));
        }
    };

    let conn = RpPairingSocket::new(stream);

    let mut rpc = RemotePairingClient::new(conn, &"minimuxer", &mut pairing_file);
    rpc.connect(async |_| "000000".to_string(), 0u8).await?;

    use idevice::remote_pairing::connect_tls_psk_tunnel_native;

    let tunnel_port = rpc.create_tcp_listener().await?;

    let tunnel_addr =
        std::net::SocketAddr::new(std::net::IpAddr::V4(*socket_addr.ip()), tunnel_port);
    let tunnel_stream = tokio::net::TcpStream::connect(tunnel_addr).await?;
    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key()).await?;
    let client_ip: std::net::IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|e| IdeviceError::AddrParseError(e))?;
    let server_ip: std::net::IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|e| IdeviceError::AddrParseError(e))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;

    let raw = tunnel.into_inner();
    let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(raw), client_ip, server_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();

    let rsd_stream = adapter.connect(rsd_port).await?;
    let handshake = RsdHandshake::new(rsd_stream).await?;

    Ok(CachedRsdConnection { adapter, handshake })
}
