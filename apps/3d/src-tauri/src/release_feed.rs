//! What the Windows, Linux and iOS apps read from GitHub Releases to find their update (docs/UPDATES.md § Windows
//! and Linux, § iOS): pure functions, no network, unit-tested below.
//!
//! The releases are those of casimir-engineering/shenzhen-3D, read through the public API with no account. Every
//! release so far is a pre-release, so the app reads the list (`/releases`), not `/releases/latest`. A release counts
//! only when it carries what this install needs: Mac-only releases, drafts and releases built before a platform
//! could update are passed over, and an older release that has it is offered instead.

// The Mac builds compile this file for its tests only.
#![cfg_attr(
    not(any(windows, target_os = "linux", target_os = "ios")),
    allow(dead_code)
)]

use serde::Deserialize;

/// A version as the releases name them: `preview-0.2.9`, `v0.2.9` or `0.2.9`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version(pub u64, pub u64, pub u64);

impl Version {
    pub fn parse(text: &str) -> Option<Version> {
        let text = text.trim();
        let text = text
            .strip_prefix("preview-")
            .or_else(|| text.strip_prefix('v'))
            .unwrap_or(text);
        let mut parts = text.split('.');
        let mut next = || -> Option<u64> {
            let part = parts.next()?;
            if part.is_empty() || part.len() > 9 || !part.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            part.parse().ok()
        };
        let version = Version(next()?, next()?, next()?);
        parts.next().is_none().then_some(version)
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.0, self.1, self.2)
    }
}

#[derive(Clone, Debug, Deserialize)]
pub struct Asset {
    pub name: String,
    pub browser_download_url: String,
    #[serde(default)]
    pub size: u64,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Release {
    pub tag_name: String,
    #[serde(default)]
    pub draft: bool,
    #[serde(default)]
    pub html_url: String,
    #[serde(default)]
    pub assets: Vec<Asset>,
}

impl Release {
    pub fn version(&self) -> Option<Version> {
        Version::parse(&self.tag_name)
    }

    pub fn asset(&self, name: &str) -> Option<&Asset> {
        self.assets.iter().find(|asset| asset.name == name)
    }
}

/// The `/releases` answer. Anything that is not a list of releases is an error, not "no update".
pub fn parse_releases(json: &[u8]) -> Result<Vec<Release>, String> {
    serde_json::from_slice(json).map_err(|error| format!("unexpected releases answer: {error}"))
}

/// The releases newer than `current`, newest first, drafts and unversioned tags left out.
pub fn newer(releases: &[Release], current: Version) -> Vec<(Version, &Release)> {
    let mut newer: Vec<_> = releases
        .iter()
        .filter(|release| !release.draft)
        .filter_map(|release| Some((release.version()?, release)))
        .filter(|(version, _)| *version > current)
        .collect();
    newer.sort_by(|a, b| b.0.cmp(&a.0));
    newer
}

/// The newest release newer than `current` for which `fits` answers; `fits` sees each candidate in turn, newest
/// first, so a release without this install's asset is passed over for the next one down.
pub fn pick<'a, T>(
    releases: &'a [Release],
    current: Version,
    mut fits: impl FnMut(&'a Release) -> Option<T>,
) -> Option<(Version, &'a Release, T)> {
    newer(releases, current)
        .into_iter()
        .find_map(|(version, release)| fits(release).map(|found| (version, release, found)))
}

#[cfg(any(windows, target_os = "linux", test))]
/// The update manifest (`latest.json`) each release carries: Tauri's static format.
#[derive(Clone, Debug, Deserialize)]
pub struct Manifest {
    pub version: String,
    #[serde(default)]
    pub platforms: std::collections::HashMap<String, ManifestPlatform>,
}

#[cfg(any(windows, target_os = "linux", test))]
#[derive(Clone, Debug, Deserialize)]
pub struct ManifestPlatform {
    pub url: String,
    pub signature: String,
}

#[cfg(any(windows, target_os = "linux", test))]
pub fn parse_manifest(json: &[u8]) -> Result<Manifest, String> {
    serde_json::from_slice(json).map_err(|error| format!("unexpected update manifest: {error}"))
}

#[cfg(any(windows, target_os = "linux", test))]
impl Manifest {
    /// The entry for `target` (`windows-x86_64-nsis`, `linux-aarch64-appimage`…), when the manifest is for
    /// `version` and names a file by HTTPS (or, for the test API, plain HTTP on loopback).
    pub fn entry(&self, target: &str, version: Version) -> Option<&ManifestPlatform> {
        if Version::parse(&self.version) != Some(version) {
            return None;
        }
        let entry = self.platforms.get(target)?;
        let allowed = entry.url.starts_with("https://")
            || (cfg!(feature = "updates-test-api") && entry.url.starts_with("http://127.0.0.1:"));
        (allowed && !entry.signature.trim().is_empty()).then_some(entry)
    }
}

#[cfg(any(windows, target_os = "linux", test))]
/// The file name a download URL ends with, as `SHA256SUMS.txt` lists it.
pub fn file_name(url: &str) -> Option<String> {
    let path = url.split(['?', '#']).next()?;
    let last = path.rsplit('/').next()?;
    let decoded = percent_decode(last)?;
    (!decoded.is_empty() && !decoded.contains('/')).then_some(decoded)
}

#[cfg(any(windows, target_os = "linux", test))]
fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(any(windows, target_os = "linux", test))]
/// The SHA-256 `SHA256SUMS.txt` gives for `name` (`<64 hex>  <name>`, or `<64 hex> *<name>`), lower case.
pub fn checksum_for(sums: &str, name: &str) -> Option<String> {
    sums.lines().find_map(|line| {
        let (hash, rest) = line.trim_end().split_once(char::is_whitespace)?;
        let listed = rest.trim_start().trim_start_matches('*');
        (listed == name && hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit()))
            .then(|| hash.to_ascii_lowercase())
    })
}

#[cfg(any(windows, target_os = "linux", test))]
/// Lower-case hex SHA-256 of `bytes`.
pub fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

#[cfg(any(windows, target_os = "linux", test))]
/// The check the installer's bytes pass before anything runs them: the signature in the manifest (Tauri's form, a
/// base64-encoded minisign signature) made by the key whose public half the app carries, over exactly these bytes,
/// for exactly this version. Tauri's updater checks the same while downloading; this is the app's own copy of that
/// gate, so a test can show a changed file is refused.
pub fn verify_bundle(
    bytes: &[u8],
    signature_base64: &str,
    public_key_base64: &str,
    version: Version,
) -> Result<(), String> {
    use base64::Engine;
    let text = |b64: &str, what: &str| -> Result<String, String> {
        let raw = base64::engine::general_purpose::STANDARD
            .decode(b64.trim())
            .map_err(|_| format!("the {what} is not base64"))?;
        String::from_utf8(raw).map_err(|_| format!("the {what} is not text"))
    };
    let key = minisign_verify::PublicKey::decode(&text(public_key_base64, "public key")?)
        .map_err(|error| format!("unusable public key: {error}"))?;
    let signature = minisign_verify::Signature::decode(&text(signature_base64, "signature")?)
        .map_err(|error| format!("unusable signature: {error}"))?;
    key.verify(bytes, &signature, true)
        .map_err(|_| "the file does not match its signature".to_string())?;
    let signed = signature
        .trusted_comment()
        .split('\t')
        .find_map(|field| field.strip_prefix("version:"))
        .and_then(Version::parse);
    if signed != Some(version) {
        return Err(format!(
            "the file was signed for another version ({signed:?})"
        ));
    }
    Ok(())
}

/// The architecture as the published file names spell it (`Shenzhen-3D-0.2.0-Linux-arm64.deb`).
pub fn arch_label(arch: &str) -> &str {
    match arch {
        "aarch64" => "arm64",
        "x86_64" => "x64",
        other => other,
    }
}

/// For a deb or rpm install: the package of the same kind and architecture in `release`.
pub fn linux_package<'a>(release: &'a Release, extension: &str, arch: &str) -> Option<&'a Asset> {
    let suffix = format!("-Linux-{}.{extension}", arch_label(arch));
    release
        .assets
        .iter()
        .find(|asset| asset.name.ends_with(&suffix))
}

/// For the iPhone and iPad app: the release's install manifest and the registered-devices app it names.
pub fn ios_install(release: &Release) -> Option<(&Asset, &Asset)> {
    let ipa = release
        .assets
        .iter()
        .find(|asset| asset.name.ends_with("-ios-registered-devices.ipa"))?;
    let manifest = release.asset("manifest.plist")?;
    Some((manifest, ipa))
}

/// The link that asks iOS to install the app the manifest at `manifest_url` describes.
pub fn itms_services_link(manifest_url: &str) -> String {
    let mut encoded = String::new();
    for byte in manifest_url.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            encoded.push(byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    format!("itms-services://?action=download-manifest&url={encoded}")
}

#[cfg(test)]
mod tests {
    use super::*;

    // A key made for these tests only (`tauri signer generate`, no password), and its signature of BUNDLE for
    // version 0.2.9 (`tauri signer sign --app-version 0.2.9`). The private half was thrown away.
    const TEST_KEY: &str = include_str!("../tests/updates/test-key.pub");
    const BUNDLE: &[u8] = include_bytes!("../tests/updates/bundle.bin");
    const SIGNATURE: &str = include_str!("../tests/updates/bundle.bin.sig");
    const OTHER_KEY: &str = include_str!("../tests/updates/other-key.pub");

    fn release(tag: &str, draft: bool, assets: &[&str]) -> Release {
        Release {
            tag_name: tag.into(),
            draft,
            html_url: format!("https://github.com/o/r/releases/tag/{tag}"),
            assets: assets
                .iter()
                .map(|name| Asset {
                    name: (*name).into(),
                    browser_download_url: format!(
                        "https://github.com/o/r/releases/download/{tag}/{name}"
                    ),
                    size: 1,
                })
                .collect(),
        }
    }

    #[test]
    fn versions_read_like_the_tags() {
        assert_eq!(Version::parse("preview-0.2.9"), Some(Version(0, 2, 9)));
        assert_eq!(Version::parse("v1.10.0"), Some(Version(1, 10, 0)));
        assert_eq!(Version::parse("0.2.10"), Some(Version(0, 2, 10)));
        assert!(Version(0, 2, 10) > Version(0, 2, 9));
        for bad in [
            "",
            "preview-0.2",
            "0.2.9.1",
            "0.2.x",
            "untagged-3edd434",
            "0.2.-1",
            "0.2.9-beta",
        ] {
            assert_eq!(Version::parse(bad), None, "{bad}");
        }
    }

    #[test]
    fn releases_without_this_installs_asset_are_passed_over() {
        // As published: 0.2.1 is Mac only, a newer draft must never count, 0.2.9 carries the manifest.
        let releases = vec![
            release("preview-0.3.0", true, &["latest.json", "SHA256SUMS.txt"]),
            release(
                "preview-0.2.10",
                false,
                &["Shenzhen-3D-0.2.10-Apple-Silicon.zip"],
            ),
            release("preview-0.2.9", false, &["latest.json", "SHA256SUMS.txt"]),
            release(
                "preview-0.2.1",
                false,
                &["Shenzhen-3D-0.2.1-Apple-Silicon.zip"],
            ),
            release(
                "preview-0.2.0",
                false,
                &["Shenzhen-3D-0.2.0-Linux-arm64.deb"],
            ),
            release("untagged-3edd434ab6c5c7f9ce80", false, &["latest.json"]),
        ];
        let mut seen = Vec::new();
        let picked = pick(&releases, Version(0, 2, 2), |r| {
            seen.push(r.tag_name.clone());
            r.asset("latest.json").map(|a| a.name.clone())
        });
        let (version, picked, _) = picked.expect("0.2.9 is offered");
        assert_eq!(version, Version(0, 2, 9));
        assert_eq!(picked.tag_name, "preview-0.2.9");
        assert_eq!(
            seen,
            ["preview-0.2.10", "preview-0.2.9"],
            "newest first, the draft never looked at"
        );
        // Already on 0.2.9: nothing older is offered.
        assert!(pick(&releases, Version(0, 2, 9), |r| r.asset("latest.json")).is_none());
        // A deb install looks for its own package and finds none newer than 0.2.0.
        assert!(
            pick(&releases, Version(0, 2, 0), |r| linux_package(
                r, "deb", "aarch64"
            ))
            .is_none()
        );
    }

    #[test]
    fn a_deb_or_rpm_install_finds_its_package() {
        let r = release(
            "preview-0.2.9",
            false,
            &[
                "Shenzhen-3D-0.2.9-Linux-arm64.deb",
                "Shenzhen-3D-0.2.9-Linux-arm64.rpm",
                "Shenzhen-3D-0.2.9-Linux-x64.deb",
            ],
        );
        assert_eq!(
            linux_package(&r, "deb", "aarch64").unwrap().name,
            "Shenzhen-3D-0.2.9-Linux-arm64.deb"
        );
        assert_eq!(
            linux_package(&r, "rpm", "aarch64").unwrap().name,
            "Shenzhen-3D-0.2.9-Linux-arm64.rpm"
        );
        assert_eq!(
            linux_package(&r, "deb", "x86_64").unwrap().name,
            "Shenzhen-3D-0.2.9-Linux-x64.deb"
        );
        assert!(linux_package(&r, "rpm", "x86_64").is_none());
    }

    #[test]
    fn the_manifest_reads_as_release_tooling_writes_it() {
        let json = include_bytes!("../tests/updates/latest.json");
        let manifest = parse_manifest(json).unwrap();
        let nsis = manifest
            .entry("windows-x86_64-nsis", Version(0, 2, 9))
            .unwrap();
        assert!(
            nsis.url
                .ends_with("/preview-0.2.9/Shenzhen-3D-0.2.9-Windows-x64-Setup.exe")
        );
        assert!(
            manifest
                .entry("windows-x86_64-msi", Version(0, 2, 9))
                .is_some()
        );
        assert!(
            manifest
                .entry("linux-aarch64-appimage", Version(0, 2, 9))
                .is_some()
        );
        // No entry for a platform the release was not built for, nor for another version than announced.
        assert!(
            manifest
                .entry("linux-x86_64-appimage", Version(0, 2, 9))
                .is_none()
        );
        assert!(
            manifest
                .entry("windows-x86_64-nsis", Version(0, 2, 8))
                .is_none()
        );
        // Not a manifest at all.
        assert!(parse_manifest(b"{\"platforms\": {}}").is_err());
        assert!(parse_manifest(b"<html>").is_err());
    }

    #[test]
    fn plain_http_downloads_are_refused() {
        let manifest = parse_manifest(
            br#"{"version":"0.2.9","platforms":{"windows-x86_64-nsis":{"url":"http://example.com/a.exe","signature":"x"}}}"#,
        )
        .unwrap();
        assert!(
            manifest
                .entry("windows-x86_64-nsis", Version(0, 2, 9))
                .is_none()
        );
    }

    #[test]
    fn checksums_are_found_by_file_name() {
        let sums = "aaaa  short\n\
            e82215b9dbfed06f5b0545566d6f381bd9e3b120fcf3973424597fbca8375a33  Shenzhen-3D-0.2.0-Windows-x64-Setup.exe\n\
            A2F0987B72645B28D04CD4E7AF029005AFF54D786AC8DFD92728814D1C6559AD *Shenzhen-3D-0.2.0-Windows-x64.msi\n";
        assert_eq!(
            checksum_for(sums, "Shenzhen-3D-0.2.0-Windows-x64-Setup.exe").unwrap(),
            "e82215b9dbfed06f5b0545566d6f381bd9e3b120fcf3973424597fbca8375a33"
        );
        assert_eq!(
            checksum_for(sums, "Shenzhen-3D-0.2.0-Windows-x64.msi").unwrap(),
            "a2f0987b72645b28d04cd4e7af029005aff54d786ac8dfd92728814d1c6559ad"
        );
        assert_eq!(checksum_for(sums, "short"), None);
        assert_eq!(checksum_for(sums, "Shenzhen-3D-0.2.0-Windows-x64"), None);
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn file_names_come_from_the_download_url() {
        assert_eq!(
            file_name("https://github.com/o/r/releases/download/preview-0.2.9/Shenzhen-3D-0.2.9-Windows-x64-Setup.exe")
                .unwrap(),
            "Shenzhen-3D-0.2.9-Windows-x64-Setup.exe"
        );
        assert_eq!(
            file_name("https://h/x/Shenzhen%203D_0.2.9.AppImage?x=1").unwrap(),
            "Shenzhen 3D_0.2.9.AppImage"
        );
        assert_eq!(file_name("https://h/x/a%2Fb"), None);
        assert_eq!(file_name("https://h/x/"), None);
    }

    #[test]
    fn a_signed_bundle_passes_and_a_changed_one_is_refused() {
        verify_bundle(BUNDLE, SIGNATURE, TEST_KEY, Version(0, 2, 9))
            .expect("the signed bundle passes");
        // One byte changed.
        let mut tampered = BUNDLE.to_vec();
        tampered[0] ^= 1;
        assert!(verify_bundle(&tampered, SIGNATURE, TEST_KEY, Version(0, 2, 9)).is_err());
        // A byte added.
        let mut longer = BUNDLE.to_vec();
        longer.push(0);
        assert!(verify_bundle(&longer, SIGNATURE, TEST_KEY, Version(0, 2, 9)).is_err());
        // Signed by another key.
        assert!(verify_bundle(BUNDLE, SIGNATURE, OTHER_KEY, Version(0, 2, 9)).is_err());
        // Announced as another version than the one signed.
        assert!(verify_bundle(BUNDLE, SIGNATURE, TEST_KEY, Version(0, 3, 0)).is_err());
        // No signature at all.
        assert!(verify_bundle(BUNDLE, "", TEST_KEY, Version(0, 2, 9)).is_err());
    }

    #[test]
    fn the_app_carries_the_release_key() {
        let config: serde_json::Value =
            serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        let key = config["plugins"]["updater"]["pubkey"].as_str().unwrap();
        use base64::Engine;
        let text = String::from_utf8(
            base64::engine::general_purpose::STANDARD
                .decode(key)
                .unwrap(),
        )
        .unwrap();
        assert!(minisign_verify::PublicKey::decode(&text).is_ok());
        assert_eq!(config["plugins"]["updater"]["requireSignedVersion"], true);
        assert_ne!(key, TEST_KEY.trim(), "the test key is never the app's");
    }

    #[test]
    fn ios_installs_through_the_manifest() {
        let r = release(
            "preview-0.2.9",
            false,
            &[
                "manifest.plist",
                "shenzhen-3d-0.2.9-ios-registered-devices.ipa",
                "shenzhen-3d-0.2.9-ios-arm64-simulator.tar.gz",
            ],
        );
        let (manifest, ipa) = ios_install(&r).unwrap();
        assert_eq!(manifest.name, "manifest.plist");
        assert_eq!(ipa.name, "shenzhen-3d-0.2.9-ios-registered-devices.ipa");
        assert!(
            ios_install(&release(
                "preview-0.2.1",
                false,
                &["Shenzhen-3D-0.2.1-Apple-Silicon.zip"]
            ))
            .is_none()
        );
        assert!(
            ios_install(&release(
                "preview-0.2.0",
                false,
                &["shenzhen-3d-0.2.0-ios-registered-devices.ipa"]
            ))
            .is_none()
        );
        assert_eq!(
            itms_services_link(
                "https://github.com/o/r/releases/download/preview-0.2.9/manifest.plist"
            ),
            "itms-services://?action=download-manifest&url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Freleases%2Fdownload%2Fpreview-0.2.9%2Fmanifest.plist"
        );
    }

    #[test]
    fn github_answers_parse() {
        let json = br#"[{"tag_name":"preview-0.2.1","draft":false,"prerelease":true,"html_url":"https://x",
            "assets":[{"name":"a.zip","browser_download_url":"https://x/a.zip","size":5,"digest":"sha256:00"}]},
            {"tag_name":"untagged-1","draft":true,"assets":[]}]"#;
        let releases = parse_releases(json).unwrap();
        assert_eq!(releases.len(), 2);
        assert_eq!(releases[0].assets[0].size, 5);
        assert!(parse_releases(br#"{"message":"API rate limit exceeded"}"#).is_err());
    }
}
