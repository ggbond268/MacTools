#!/usr/bin/env swift
// Dynamic-plugin trust chain probe (read-only):
// - SecStaticCode validation behavior on a platform app and, when available,
//   a locally built (ad-hoc) plugin bundle — mirrors PluginTrustValidator's
//   surface.
// - Production catalog Ed25519 verification against the live catalog with the
//   committed public key, replaying PluginCatalogSigning.signedPayload's
//   JSONSerialization canonicalization (the cross-version drift watch point).

import CryptoKit
import Foundation
import Security

enum ProbeStatus: String { case ok, degraded, broken, inconclusive, skip }

func report(_ status: ProbeStatus, _ name: String, _ detail: String) {
    print("[\(status.rawValue)] \(name): \(detail)")
}

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // beta-probes
    .deletingLastPathComponent() // scripts
    .deletingLastPathComponent()

// 1. SecStaticCode chain.
func staticCodeSummary(at url: URL) -> (summary: String, healthy: Bool) {
    var staticCode: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
    guard createStatus == errSecSuccess, let staticCode else {
        return ("create=\(createStatus)", false)
    }

    let validityStatus = SecStaticCodeCheckValidity(staticCode, [], nil)

    var team = "nil"
    var infoCF: CFDictionary?
    if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
       let info = infoCF as? [String: Any],
       let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String {
        team = teamIdentifier
    }

    return ("validity=\(validityStatus) team=\(team)", validityStatus == errSecSuccess)
}

func probeSecStaticCode() {
    let name = "secstaticcode-plugin-trust-chain"
    let systemAppURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
    let (systemSummary, systemHealthy) = staticCodeSummary(at: systemAppURL)

    // Locally built Debug plugin bundle, when one exists (ad-hoc signed; the
    // DEBUG-lenient trust path expects errSecSuccess with a nil team).
    var bundleDetail = "no local Debug plugin bundle found (run a Debug build to extend coverage)"
    var bundleHealthy = true
    let productsURL = repositoryRoot
        .appendingPathComponent("build/DerivedData/Build/Products/Debug", isDirectory: true)
    if let entries = try? FileManager.default.contentsOfDirectory(
        at: productsURL,
        includingPropertiesForKeys: nil
    ), let bundleURL = entries.first(where: { $0.pathExtension == "bundle" }) {
        let (summary, healthy) = staticCodeSummary(at: bundleURL)
        bundleDetail = "\(bundleURL.lastPathComponent): \(summary)"
        bundleHealthy = healthy
    }

    let detail = "Calculator.app: \(systemSummary); \(bundleDetail)"
    if systemHealthy && bundleHealthy {
        report(.ok, name, detail)
    } else {
        report(.broken, name, detail + " — SecStaticCode validation behavior changed")
    }
}

probeSecStaticCode()

// 2. Catalog Ed25519 signature + JSONSerialization canonicalization drift.
func loadCatalogPublicKey() -> Curve25519.Signing.PublicKey? {
    // The production key is injected via Configs/*.xcconfig
    // (PLUGIN_CATALOG_PUBLIC_KEY) into Info.plist; read it from the repo so the
    // probe never drifts from what ships.
    let xcconfigURL = repositoryRoot.appendingPathComponent("Configs/Release.xcconfig")
    guard let contents = try? String(contentsOf: xcconfigURL, encoding: .utf8) else {
        return nil
    }

    for line in contents.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard
            parts.count == 2,
            parts[0].trimmingCharacters(in: .whitespaces) == "PLUGIN_CATALOG_PUBLIC_KEY"
        else {
            continue
        }
        let base64 = parts[1].trimmingCharacters(in: .whitespaces)
        guard let raw = Data(base64Encoded: base64), raw.count == 32 else {
            return nil
        }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }
    return nil
}

enum CatalogFetchOutcome {
    case success(Data)
    case failure(String)
}

func fetchCatalog(url: URL) -> CatalogFetchOutcome {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30

    let semaphore = DispatchSemaphore(value: 0)
    var outcome: CatalogFetchOutcome = .failure("no response")
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let error {
            outcome = .failure("network error: \(error.localizedDescription)")
            return
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            outcome = .failure("non-HTTP response")
            return
        }
        guard httpResponse.statusCode == 200, let data else {
            outcome = .failure("HTTP \(httpResponse.statusCode)")
            return
        }
        outcome = .success(data)
    }
    task.resume()
    if semaphore.wait(timeout: .now() + 45) == .timedOut {
        task.cancel()
        return .failure("timed out after 45s")
    }
    return outcome
}

func probeCatalogSignature() {
    let name = "catalog-ed25519-canonicalization"
    // PluginCatalogProvider.productionCatalogURL
    guard let catalogURL = URL(string: "https://mactools.ggbond.app/plugins/catalog.json") else {
        report(.broken, name, "catalog URL failed to parse")
        return
    }

    guard let publicKey = loadCatalogPublicKey() else {
        report(.broken, name, "PLUGIN_CATALOG_PUBLIC_KEY missing/invalid in Configs/Release.xcconfig")
        return
    }

    let data: Data
    switch fetchCatalog(url: catalogURL) {
    case let .failure(message):
        report(.inconclusive, name, "catalog fetch failed (\(message)) — rerun with network access")
        return
    case let .success(fetched):
        data = fetched
    }

    guard
        let object = try? JSONSerialization.jsonObject(with: data),
        var dictionary = object as? [String: Any]
    else {
        report(.broken, name, "catalog is not a JSON object (\(data.count) bytes)")
        return
    }

    guard
        let signature = dictionary["signature"] as? [String: Any],
        let algorithm = signature["algorithm"] as? String,
        let signatureValue = signature["value"] as? String,
        let signatureData = Data(base64Encoded: signatureValue)
    else {
        report(.broken, name, "catalog signature block missing or malformed")
        return
    }

    guard algorithm.lowercased() == "ed25519" else {
        report(.broken, name, "unexpected signature algorithm: \(algorithm)")
        return
    }

    // Exact replay of PluginCatalogSigning.signedPayload(fromCatalogData:).
    dictionary.removeValue(forKey: "signature")
    guard
        JSONSerialization.isValidJSONObject(dictionary),
        let canonicalPayload = try? JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    else {
        report(.broken, name, "canonical payload re-serialization failed")
        return
    }

    if publicKey.isValidSignature(signatureData, for: canonicalPayload) {
        report(
            .ok,
            name,
            "catalog \(data.count) bytes, canonical payload \(canonicalPayload.count) bytes, Ed25519 signature VALID — JSONSerialization canonicalization has not drifted"
        )
    } else {
        report(
            .broken,
            name,
            "Ed25519 signature INVALID over \(canonicalPayload.count)-byte canonical payload — canonicalization drifted or catalog/key mismatch; production catalog installs would fail"
        )
    }
}

probeCatalogSignature()
