const textEncoder = new TextEncoder();
let cachedAesKey;
let cachedAesKeyValue;

function toBytes(value) {
  return value instanceof Uint8Array ? value : new Uint8Array(value);
}

export function base64UrlEncode(input) {
  const bytes = toBytes(input);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export function base64UrlDecode(value) {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export function randomToken(byteLength = 32) {
  const bytes = new Uint8Array(byteLength);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}

export async function sha256(value) {
  const digest = await crypto.subtle.digest("SHA-256", textEncoder.encode(value));
  return base64UrlEncode(digest);
}

async function hmacKey(secret) {
  return crypto.subtle.importKey(
    "raw",
    textEncoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

export async function hmacSha256(secret, value) {
  const key = await hmacKey(secret);
  const signature = await crypto.subtle.sign("HMAC", key, textEncoder.encode(value));
  return base64UrlEncode(signature);
}

export function timingSafeEqual(left, right) {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

async function aesKey(encodedKey) {
  if (cachedAesKey && cachedAesKeyValue === encodedKey) return cachedAesKey;
  const key = await crypto.subtle.importKey(
    "raw",
    base64UrlDecode(encodedKey),
    { name: "AES-GCM" },
    false,
    ["encrypt", "decrypt"],
  );
  cachedAesKey = key;
  cachedAesKeyValue = encodedKey;
  return key;
}

export async function encryptString(value, encodedKey) {
  const iv = new Uint8Array(12);
  crypto.getRandomValues(iv);
  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    await aesKey(encodedKey),
    textEncoder.encode(value),
  );
  return `${base64UrlEncode(iv)}.${base64UrlEncode(encrypted)}`;
}

export async function decryptString(value, encodedKey) {
  const [encodedIv, encodedCiphertext] = value.split(".");
  if (!encodedIv || !encodedCiphertext) throw new Error("invalid_ciphertext");
  const decrypted = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: base64UrlDecode(encodedIv) },
    await aesKey(encodedKey),
    base64UrlDecode(encodedCiphertext),
  );
  return new TextDecoder().decode(decrypted);
}
