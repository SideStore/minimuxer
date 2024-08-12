use std::{cmp::Ordering, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=./build.rs");

    const OUT_DIR: &str = "./generated/";
    println!("cargo:rerun-if-changed={OUT_DIR}minimuxer-helpers.swift");
    const ROOT: &str = "./src/";

    let mut bridges: Vec<PathBuf> = std::fs::read_dir(ROOT)
        .unwrap()
        .map(|res| res.unwrap().path())
        .collect();
    for path in &bridges {
        let path = path.file_name().unwrap().to_str().unwrap().to_string();
        println!("cargo:rerun-if-changed={ROOT}{path}");
    }
    // Ensure we generate for lib.rs first
    bridges.sort_by(|a, b| {
        if a.file_name().unwrap().to_str().unwrap().ends_with("lib.rs") {
            Ordering::Less
        } else if b.file_name().unwrap().to_str().unwrap() == "lib.rs" {
            Ordering::Greater
        } else {
            a.cmp(b)
        }
    });

    swift_bridge_build::parse_bridges(bridges)
        .write_all_concatenated(OUT_DIR, env!("CARGO_PKG_NAME"));
}
