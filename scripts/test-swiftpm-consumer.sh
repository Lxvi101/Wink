#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_PATH="${ROOT_DIR}/Package.swift"

if [[ ! -f "${MANIFEST_PATH}" ]]; then
  printf 'Missing public SwiftPM manifest: %s\n' "${MANIFEST_PATH}" >&2
  exit 1
fi

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/wink-swiftpm-consumer.XXXXXX")"
trap 'rm -rf "${fixture_dir}"' EXIT

manifest_json="${fixture_dir}/wink-package.json"
swift package --package-path "${ROOT_DIR}" dump-package >"${manifest_json}"

node - "${manifest_json}" <<'NODE'
const fs = require("node:fs");

const manifest = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const expected = [
  "WinkFoundation",
  "WinkProtocols",
  "WinkAutomationKit",
  "WinkBridge",
];
const actual = manifest.products.map(product => product.name).sort();

if (JSON.stringify(actual) !== JSON.stringify([...expected].sort())) {
  console.error(`Public SwiftPM products drifted: expected ${expected.join(", ")}; received ${actual.join(", ")}`);
  process.exit(1);
}

const expectedAXVersion = "0.2.2";
const sourceDependencies = manifest.dependencies.flatMap(dependency => dependency.sourceControl ?? []);
const axorcist = sourceDependencies.find(dependency => dependency.identity === "axorcist");
const actualAXVersion = axorcist?.requirement?.exact?.[0];
if (actualAXVersion !== expectedAXVersion) {
  console.error(`AXorcist version drifted: expected ${expectedAXVersion}; received ${actualAXVersion ?? "none"}`);
  process.exit(1);
}
NODE

package_repo="${fixture_dir}/Wink"
mkdir -p \
  "${package_repo}/Core/WinkFoundation/Sources" \
  "${package_repo}/Core/WinkProtocols/Sources" \
  "${package_repo}/Core/WinkAutomationKit/Sources" \
  "${package_repo}/Core/WinkCore/Sources"

cp "${MANIFEST_PATH}" "${package_repo}/Package.swift"
/usr/bin/ditto \
  "${ROOT_DIR}/Core/WinkFoundation/Sources/WinkFoundation" \
  "${package_repo}/Core/WinkFoundation/Sources/WinkFoundation"
/usr/bin/ditto \
  "${ROOT_DIR}/Core/WinkProtocols/Sources/WinkProtocols" \
  "${package_repo}/Core/WinkProtocols/Sources/WinkProtocols"
/usr/bin/ditto \
  "${ROOT_DIR}/Core/WinkAutomationKit/Sources/WinkAutomationKit" \
  "${package_repo}/Core/WinkAutomationKit/Sources/WinkAutomationKit"
/usr/bin/ditto \
  "${ROOT_DIR}/Core/WinkCore/Sources/WinkBridge" \
  "${package_repo}/Core/WinkCore/Sources/WinkBridge"

git -C "${package_repo}" init -q
git -C "${package_repo}" add Package.swift Core
git -C "${package_repo}" \
  -c user.name='Wink Consumer Contract' \
  -c user.email='consumer-contract@invalid.example' \
  commit -qm 'fixture: exact public package revision'
git -C "${package_repo}" \
  -c user.name='Wink Consumer Contract' \
  -c user.email='consumer-contract@invalid.example' \
  -c tag.gpgSign=false \
  tag -am 'fixture: semantic package version' 4.1.1

export WINK_CONSUMER_PACKAGE_URL="file://${package_repo}"
export WINK_CONSUMER_PACKAGE_VERSION="4.1.1"

consumer_dir="${fixture_dir}/Consumer"
mkdir -p "${consumer_dir}/Sources/Consumer"

cat >"${consumer_dir}/Package.swift" <<'EOF'
// swift-tools-version: 6.2

import Foundation
import PackageDescription

let packageURL = ProcessInfo.processInfo.environment["WINK_CONSUMER_PACKAGE_URL"]!
let packageVersion = ProcessInfo.processInfo.environment["WINK_CONSUMER_PACKAGE_VERSION"]!

let package = Package(
    name: "WinkConsumer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: packageURL, exact: Version(packageVersion)!),
    ],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: [
                .product(name: "WinkFoundation", package: "Wink"),
                .product(name: "WinkProtocols", package: "Wink"),
                .product(name: "WinkAutomationKit", package: "Wink"),
                .product(name: "WinkBridge", package: "Wink"),
            ]),
    ],
    swiftLanguageModes: [.v6])
EOF

cat >"${consumer_dir}/Sources/Consumer/main.swift" <<'EOF'
import WinkAutomationKit
import WinkBridge
import WinkFoundation
import WinkProtocols

func pendingReservationDisposition(
    for failure: some PendingSnapshotFailureDispositionProviding) -> Bool
{
    failure.mayCompleteSnapshotWorkAfterFailure
}

let failure = DesktopActionFailure.refused(
    reason: .targetUnavailable,
    message: "Consumer contract probe")
precondition(!pendingReservationDisposition(for: failure))

// Compile the six-label factory shipped in v4.2.2 without constructing services.
func releasedRawEvidenceFactory() -> DesktopTargetIdentity.Evidence {
    DesktopTargetEvidenceAdapter.evidence(
        processIdentifier: 4242,
        processStartIdentity: nil,
        windowID: 7,
        windowIdentity: nil,
        windowBounds: nil,
        focusedElement: nil)
}

_ = releasedRawEvidenceFactory

@MainActor
func makeEmbeddedRuntime() -> WinkEmbeddedBridgeRuntime {
    WinkEmbeddedBridgeRuntime.make(configuration: .init(
        socketPath: "/tmp/wink-consumer-contract.sock",
        allowlistedTeams: ["TEAMID"],
        allowlistedBundles: ["com.example.WinkConsumer"]))
}

_ = makeEmbeddedRuntime
EOF

swift package --package-path "${consumer_dir}" resolve
swift build ${WINK_BUILD_JOBS:+--jobs "$WINK_BUILD_JOBS"} --package-path "${consumer_dir}" --configuration release

printf 'SwiftPM consumer contract passed for: %s\n' "${ROOT_DIR}"
