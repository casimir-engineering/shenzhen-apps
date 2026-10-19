fn main() {
    // Shenzhen Friends' capability (capabilities/friends/: its commands for the main window only) belongs to builds
    // with the `friends` feature, which carry the plugin whose permission it names. It is declared here rather than
    // added at launch, so the app links no runtime capability parser (ADR 0015 § 12, the phones' size budget).
    let friends = std::env::var_os("CARGO_FEATURE_FRIENDS").is_some();
    let pattern = if friends {
        "./capabilities/**/*"
    } else {
        "./capabilities/*"
    };
    // A pattern of our own makes tauri-build leave the watching to us.
    println!("cargo:rerun-if-changed=capabilities");
    tauri_build::try_build(tauri_build::Attributes::new().capabilities_path_pattern(pattern))
        .expect("the Tauri build step failed");
}
