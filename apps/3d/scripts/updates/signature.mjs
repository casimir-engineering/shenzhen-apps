// Tauri's updater signatures (minisign), checked as the app checks them: Ed25519 over the BLAKE2b-512 of the file,
// then over the signature and its trusted comment, which names the version the file was signed for.
import { createHash, createPublicKey, verify } from "node:crypto";

/** Undefined when `bytes` carry a good signature by `publicKeyBase64` for `expectedVersion`; else what is wrong. */
export function verifyTauriSignature(
  bytes,
  signatureBase64,
  publicKeyBase64,
  expectedVersion,
) {
  try {
    return check(bytes, signatureBase64, publicKeyBase64, expectedVersion);
  } catch {
    return "malformed key or signature";
  }
}

function check(bytes, signatureBase64, publicKeyBase64, expectedVersion) {
  const lines = (b64) =>
    Buffer.from(b64.trim(), "base64").toString("utf8").split("\n");
  const keyBytes = Buffer.from(lines(publicKeyBase64)[1], "base64");
  const signatureLines = lines(signatureBase64);
  const raw = Buffer.from(signatureLines[1], "base64");
  const trusted = signatureLines[2]?.replace(/^trusted comment: /, "") ?? "";
  const global = Buffer.from(signatureLines[3] ?? "", "base64");
  if (keyBytes.length !== 42 || raw.length !== 74)
    return "malformed key or signature";
  if (!keyBytes.subarray(2, 10).equals(raw.subarray(2, 10)))
    return "signed with another key";
  const key = createPublicKey({
    key: {
      kty: "OKP",
      crv: "Ed25519",
      x: keyBytes.subarray(10).toString("base64url"),
    },
    format: "jwk",
  });
  const algorithm = raw.subarray(0, 2).toString("latin1");
  const message =
    algorithm === "ED"
      ? createHash("blake2b512").update(bytes).digest()
      : bytes;
  const signature = raw.subarray(10);
  if (!verify(null, message, key, signature))
    return "the file does not match its signature";
  if (
    !verify(null, Buffer.concat([signature, Buffer.from(trusted)]), key, global)
  )
    return "the trusted comment does not match";
  const signed = trusted
    .split("\t")
    .find((f) => f.startsWith("version:"))
    ?.slice(8);
  if (signed !== expectedVersion)
    return `signed for version ${signed ?? "none"}, not ${expectedVersion}`;
  return undefined;
}
