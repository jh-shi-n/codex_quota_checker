#!/usr/bin/env swift
// 목적: Keychain 비공개 키로 릴리스 ZIP SHA-256의 Ed25519 서명 생성
// 이용처: GitHub 릴리스 ZIP과 함께 게시하는 .zip.sig 파일
// 사용방법: swift scripts/sign_release.swift /path/to/release.zip
import CryptoKit
import Foundation
import Security

/// 개인키를 파일·출력·환경에 노출하지 않는 릴리스 서명
func signRelease(_ archive: URL) throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.shinjh.CodexQuotaChecker.release-signing",
        kSecAttrAccount as String: "ed25519-v1",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let privateData = result as? Data else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
    guard key.publicKey.rawRepresentation.base64EncodedString() == "eVqIIERnbh3hDEscyndQjUFkjhQqgtoHa6d/r6iF/1s=" else {
        throw CocoaError(.coderInvalidValue)
    }
    let input = try FileHandle(forReadingFrom: archive)
    defer { try? input.close() }
    var hash = SHA256()
    while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
    let signature = try key.signature(for: Data(hash.finalize()))
    try signature.write(to: URL(fileURLWithPath: archive.path + ".sig"), options: .atomic)
    print("Signed release: \(archive.lastPathComponent).sig")
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/sign_release.swift ARCHIVE.zip\n", stderr)
    exit(2)
}
do { try signRelease(URL(fileURLWithPath: CommandLine.arguments[1])) }
catch {
    fputs("Release signing failed. Check the configured Keychain signing identity.\n", stderr)
    exit(1)
}
