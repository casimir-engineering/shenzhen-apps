/// package.json's version, the one every build of the app shows (tauri.conf.json's `version` names the same file).
fn app_version() -> String {
    let text = std::fs::read_to_string("../package.json").expect("apps/3d/package.json");
    // The first "version" key is package.json's own: name, version, then the rest.
    let after = &text[text.find("\"version\"").expect("package.json has a version") + 9..];
    let start = after.find('"').expect("package.json's version is a string") + 1;
    let end = start + after[start..].find('"').expect("package.json's version ends");
    after[start..end].to_owned()
}

fn main() {
    println!("cargo:rerun-if-changed=../package.json");
    println!("cargo:rustc-env=SHENZHEN_3D_VERSION={}", app_version());
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
