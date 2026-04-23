const std = @import("std");
const serialization = @import("serialization.zig");
const types = @import("types.zig");

const Ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
const Curve = std.crypto.ecc.Secp256k1;
const Scalar = Curve.scalar.Scalar;
const Fe = Curve.Fe;

pub const CryptoError = error{
    InvalidRecoveryId,
    InvalidSignature,
    SignatureMismatch,
};

pub fn keccak256(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(data, &out, .{});
    return out;
}

pub fn eip712Hash(domain: types.EIP712Domain, struct_hash: [32]u8) [32]u8 {
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update("\x19\x01");
    hasher.update(domainSeparator(domain)[0..]);
    hasher.update(struct_hash[0..]);

    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

pub fn domainSeparator(domain: types.EIP712Domain) [32]u8 {
    var chain_id_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &chain_id_bytes, domain.chain_id, .little);

    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(domain.name);
    hasher.update(domain.version);
    hasher.update(chain_id_bytes[0..]);

    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

pub fn hashActionForSignature(
    allocator: std.mem.Allocator,
    action: types.ActionPayload,
    nonce: u64,
) (serialization.Error || std.mem.Allocator.Error)![32]u8 {
    const tx = types.Transaction{
        .action = action,
        .nonce = nonce,
        .signature = .{
            .r = [_]u8{0} ** 32,
            .s = [_]u8{0} ** 32,
            .v = 0,
        },
        .user = [_]u8{0} ** 20,
    };

    const encoded = try serialization.encodeTransaction(allocator, tx);
    defer allocator.free(encoded);
    return keccak256(encoded);
}

pub fn addressFromPublicKey(public_key: Ecdsa.PublicKey) types.Address {
    const encoded = public_key.toUncompressedSec1();
    const hash = keccak256(encoded[1..]);
    return hash[12..32].*;
}

pub fn addressFromSecretKey(secret_key_bytes: [32]u8) !types.Address {
    const key_pair = try Ecdsa.KeyPair.fromSecretKey(.{ .bytes = secret_key_bytes });
    return addressFromPublicKey(key_pair.public_key);
}

fn normalizeRecoveryId(v: u8) CryptoError!u8 {
    return switch (v) {
        0, 1 => v,
        27, 28 => v - 27,
        else => error.InvalidRecoveryId,
    };
}

fn recoverPublicKey(
    msg_hash: [32]u8,
    sig: Ecdsa.Signature,
    recovery_id: u8,
) !Ecdsa.PublicKey {
    const r_scalar = Scalar.fromBytes(sig.r, .big) catch return error.InvalidSignature;
    const s_scalar = Scalar.fromBytes(sig.s, .big) catch return error.InvalidSignature;
    if (r_scalar.isZero() or s_scalar.isZero()) return error.InvalidSignature;

    const x = Fe.fromBytes(sig.r, .big) catch return error.InvalidSignature;
    const y = Curve.recoverY(x, recovery_id == 1) catch return error.InvalidSignature;
    const r_point = Curve.fromAffineCoordinates(.{ .x = x, .y = y }) catch return error.InvalidSignature;

    const z = reduceToScalar(msg_hash);
    if (z.isZero()) return error.InvalidSignature;

    const r_inv = r_scalar.invert();
    const coeff_g = Scalar.neg(z).mul(r_inv);
    const coeff_r = s_scalar.mul(r_inv);

    const g_term = try Curve.basePoint.mulPublic(coeff_g.toBytes(.little), .little);
    const r_term = try r_point.mulPublic(coeff_r.toBytes(.little), .little);

    return .{ .p = g_term.add(r_term) };
}

fn reduceToScalar(msg_hash: [32]u8) Scalar {
    var wide = [_]u8{0} ** 48;
    @memcpy(wide[wide.len - msg_hash.len ..], msg_hash[0..]);
    return Scalar.fromBytes48(wide, .big);
}

pub fn ecrecover(
    msg_hash: [32]u8,
    r: [32]u8,
    s: [32]u8,
    v: u8,
) CryptoError!types.Address {
    const recovery_id = normalizeRecoveryId(v) catch return error.InvalidRecoveryId;
    const sig = Ecdsa.Signature{ .r = r, .s = s };
    const public_key = recoverPublicKey(msg_hash, sig, recovery_id) catch return error.InvalidSignature;

    sig.verifyPrehashed(msg_hash, public_key) catch return error.SignatureMismatch;
    return addressFromPublicKey(public_key);
}

pub fn signPrehashedRecoverable(
    secret_key_bytes: [32]u8,
    msg_hash: [32]u8,
) !types.EIP712Signature {
    const key_pair = try Ecdsa.KeyPair.fromSecretKey(.{ .bytes = secret_key_bytes });
    const sig = try key_pair.signPrehashed(msg_hash, null);
    const signer = addressFromPublicKey(key_pair.public_key);

    var recovery_id: u8 = 0;
    while (recovery_id < 2) : (recovery_id += 1) {
        const recovered = ecrecover(msg_hash, sig.r, sig.s, recovery_id) catch continue;
        if (std.mem.eql(u8, recovered[0..], signer[0..])) {
            return .{
                .r = sig.r,
                .s = sig.s,
                .v = recovery_id + 27,
            };
        }
    }

    return error.SignatureMismatch;
}

const BlsG1Point = struct {
    placeholder: u8 = 0,
};

const BlsG2Point = struct {
    placeholder: u8 = 0,
};

pub fn blsVerifyAggregate(
    agg_sig: types.BlsAggregateSignature,
    pubkeys: []const types.BlsPublicKey,
    msg: [32]u8,
) bool {
    if (pubkeys.len == 0) return false;

    const sig_point = blsSignatureToPoint(agg_sig) catch return false;

    var agg_pubkey: [48]u8 = undefined;
    if (!blsAggregatePublicKeys(pubkeys, &agg_pubkey)) return false;

    const pub_point = blsPublicKeyToPoint(agg_pubkey) catch return false;
    const msg_point = blsHashToCurve(&msg);
    return blsVerifyPairing(&pub_point, &msg_point, &sig_point);
}

fn blsSignatureToPoint(sig: types.BlsSignature) !BlsG2Point {
    _ = sig;
    return BlsG2Point{};
}

fn blsPublicKeyToPoint(pk: [48]u8) !BlsG1Point {
    _ = pk;
    return BlsG1Point{};
}

fn blsAggregatePublicKeys(pubkeys: []const types.BlsPublicKey, out: *[48]u8) bool {
    if (pubkeys.len == 0) return false;
    @memset(out, 0);
    for (pubkeys) |pk| {
        var i: usize = 0;
        while (i < pk.len) : (i += 1) {
            out[i] ^= pk[i];
        }
    }
    return true;
}

fn blsHashToCurve(msg: *const [32]u8) BlsG2Point {
    _ = msg;
    return BlsG2Point{};
}

fn blsVerifyPairing(
    pub_point: *const BlsG1Point,
    msg_point: *const BlsG2Point,
    sig_point: *const BlsG2Point,
) bool {
    _ = pub_point;
    _ = msg_point;
    _ = sig_point;
    // The BLS backend has not been wired yet. Fail closed instead of
    // accepting arbitrary signatures.
    return false;
}

test "recoverable secp256k1 signature resolves the signer address" {
    const secret_key = [_]u8{
        0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
    };
    const msg_hash = keccak256("anyliquid-auth-test");
    const sig = try signPrehashedRecoverable(secret_key, msg_hash);
    const expected = try addressFromSecretKey(secret_key);
    const recovered = try ecrecover(msg_hash, sig.r, sig.s, sig.v);

    try std.testing.expectEqual(expected, recovered);
}

test "aggregate BLS verification fails closed without a backend" {
    const sig = [_]u8{1} ** 96;
    const pubkey = [_]u8{2} ** 48;

    try std.testing.expect(!blsVerifyAggregate(sig, &.{pubkey}, [_]u8{3} ** 32));
    try std.testing.expect(!blsVerifyAggregate(sig, &.{}, [_]u8{3} ** 32));
}
