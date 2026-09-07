# Clipboard backup format and security review

## Pre-implementation review

Issue #394 requires portable archives without exporting the device key. The design uses
CryptoKit AES-256-GCM and Apple's CommonCrypto PBKDF2-HMAC-SHA256, avoiding a new
cryptography dependency. PBKDF2 uses 600,000 iterations, a fresh 32-byte salt, and a
32-byte output. Readers accept only 600,000–2,000,000 iterations and bounded password
lengths. Argon2id offers stronger memory hardness but is not supplied by these native
APIs; adding and maintaining an implementation is outside this format's first version.
The PBKDF2 cost follows [OWASP's guidance](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html).

Each archive has a fresh random 256-bit content key, wrapped by the password key with
AES-GCM. The wrapping authenticates the complete fixed header. Record authentication
binds the header digest and monotonically increasing record number. A deterministic
96-bit counter nonce is unique under each fresh archive key; the wrapping key uses a
fresh random nonce. An encrypted terminal manifest authenticates scope, date, counts,
payload size, and a digest of the ordered records. Readers require the terminal record
and EOF. This detects truncation, substitution, duplication, removal, and reordering.
The nonce requirement follows the [AEAD documentation](https://cryptography.io/en/stable/hazmat/primitives/aead/).

Only the format, KDF parameters, salt, and wrapped key are cleartext. File length and
bounded frame lengths necessarily leak approximate archive size. Categories, counts,
identifiers, paths, search text, and payloads remain encrypted. No plaintext archive
option or password persistence is provided. Password recovery is impossible.

Records carry the existing persistent metadata and original representations, with
scope-excluded membership stripped. Readers authenticate before decoding, validate
the typed metadata and payload digest, and enforce frame, item, count, and archive
limits. Processing is sequential off the main actor. No full-library payload array
is created. External references remain references; referenced files are never read.

Restore stages only persistent clipboard tables, encrypted with the destination key.
It never stages queue or preference tables for import. A fingerprint binds the preview
to the current local rows; concurrent changes invalidate the preview. Replacement
creates a local encrypted rollback database before one SQLite transaction copies the
staged tables into the live database. Cancellation is checked through staging and
before the final transaction, and is disabled during that transaction. Errors shown
to users are fixed messages, never decoded metadata or underlying parser errors.

This is a focused design review, not an independent cryptographic audit. Adversarial
format, cancellation, transaction, and synthetic-volume tests are required before
the draft can be considered for release.
