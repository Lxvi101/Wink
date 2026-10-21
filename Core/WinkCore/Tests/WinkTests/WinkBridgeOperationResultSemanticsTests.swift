import Foundation
import WinkFoundation
import Testing
@testable import WinkAutomationKit
@testable import WinkBridge
@testable import WinkCore

@Suite("Bridge operation result semantics")
struct WinkBridgeOperationResultSemanticsTests {
    @Test
    func `held terminal no change replay requires an exact pre dispatch owner disconnect`() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 9001,
            ownerProcessStartIdentity: 7,
            capturedBounds: bounds)
        let owner = ExactWindowHeldPointerOwner()
        let holdRequest = ExactWindowHeldPointerRequest(
            point: CGPoint(x: 20, y: 30),
            windowIdentity: identity,
            windowBounds: bounds,
            button: .left,
            expiresAfterSeconds: 10)
        let receipt = ExactWindowHeldPointerReceipt(
            token: UUID(),
            owner: owner,
            request: holdRequest,
            expiresAt: Date().addingTimeInterval(10))
        let release = WinkBridgeRequest.releaseExactWindowHeldPointer(.init(
            owner: owner,
            receipt: receipt))
        let revoke = WinkBridgeRequest.revokeExactWindowHeldPointer(.init(
            owner: owner,
            receipt: receipt))
        let begin = WinkBridgeRequest.beginExactWindowHeldPointer(.init(
            owner: owner,
            request: holdRequest))
        let noChange = DesktopActionOutcome.confirmedNoChange(route: .bridge)

        func response(
            reason: ExactWindowHeldPointerTerminalReason,
            lifecycleUnits: Int,
            cleanup: DesktopActionOutcome = .confirmedNoChange()) -> WinkBridgeResponse
        {
            .exactWindowHeldPointerTermination(.init(
                receipt: receipt,
                reason: reason,
                cleanupOutcome: cleanup,
                lifecycleDispatchedUnitCount: lifecycleUnits))
        }

        let exactReplay = response(reason: .ownerDisconnected, lifecycleUnits: 0)
        for request in [release, revoke] {
            #expect(WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                noChange,
                response: exactReplay,
                request: request))
            #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                noChange,
                response: response(reason: .released, lifecycleUnits: 0),
                request: request))
            #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                noChange,
                response: response(reason: .ownerDisconnected, lifecycleUnits: 1),
                request: request))
            #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                noChange,
                response: response(
                    reason: .ownerDisconnected,
                    lifecycleUnits: 0,
                    cleanup: .dispatchedUnverified(
                        delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                        evidence: .deliveryAccepted,
                        unitCount: .one)),
                request: request))
        }
        #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            noChange,
            response: exactReplay,
            request: begin))
    }

    @Test
    func `middle and triple click success requires exact routed delivery and event counts`() throws {
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 9001,
            ownerProcessStartIdentity: 7,
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let bounds = try #require(identity.capturedBounds)

        for (clickType, units) in [(ClickType.middle, 3), (.triple, 7)] {
            let request = WinkBridgeRequest.targetedClick(.init(
                target: .elementId("B1"),
                clickType: clickType,
                snapshotId: "snapshot",
                targetProcessIdentifier: identity.ownerProcessIdentifier,
                targetWindowID: identity.windowID,
                expectedWindowIdentity: identity,
                expectedWindowBounds: bounds))
            let accepted = DesktopActionOutcome.dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(units)).routed(to: .bridge)
            let wrongUnits = DesktopActionOutcome.dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(units + 1)).routed(to: .bridge)
            let falseAX = DesktopActionOutcome.confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                unitCount: .one).routed(to: .bridge)

            #expect(WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                accepted,
                response: .ok,
                request: request))
            #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                wrongUnits,
                response: .ok,
                request: request))
            #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                falseAX,
                response: .ok,
                request: request))
        }
    }

    @Test
    func `process-only right and double clicks preserve truthful routed outcomes`() {
        for (clickType, units) in [(ClickType.right, 3), (.double, 5)] {
            let request = WinkBridgeRequest.targetedClick(.init(
                target: .elementId("B1"),
                clickType: clickType,
                snapshotId: "snapshot",
                targetProcessIdentifier: 9001,
                expectedProcessIdentity: .init(
                    processIdentifier: 9001,
                    processStartIdentity: 7)))
            let accepted = DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(units))
            let wrongUnits = DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(units + 1))
            let oneUnitAccessibility = DesktopActionOutcome.confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                unitCount: .one)
            let requestedUnitAccessibility = DesktopActionOutcome.confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                unitCount: .init(units))

            #expect(WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                accepted,
                response: .ok,
                request: request))
            #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                wrongUnits,
                response: .ok,
                request: request))
            #expect(WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                oneUnitAccessibility,
                response: .ok,
                request: request) == (clickType == .right))
            if clickType == .double {
                #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                    requestedUnitAccessibility,
                    response: .ok,
                    request: request))
            }
        }
    }

    @Test
    func `Default generation-pinned menu request admits only background delivery`() {
        let request = WinkBridgeRequest.clickMenuItem(.init(
            appIdentifier: "PID:701",
            itemPath: "File > New",
            expectedIdentity: .init(processIdentifier: 701, processStartIdentity: 9001)))
        let background = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let foreground = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)

        #expect(WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            background,
            response: .ok,
            request: request))
        #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            foreground,
            response: .ok,
            request: request))
    }

    @Test
    func `Explicit foreground menu request admits only foreground delivery`() {
        let request = WinkBridgeRequest.clickMenuItemByName(.init(
            appIdentifier: "PID:701",
            itemName: "New",
            expectedIdentity: .init(processIdentifier: 701, processStartIdentity: 9001),
            deliveryMode: .foreground))
        let background = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let foreground = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)

        #expect(WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            foreground,
            response: .ok,
            request: request))
        #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            background,
            response: .ok,
            request: request))
    }

    @Test
    func `Current menu payloads carry background while receiptless legacy payloads omit mode`() throws {
        let currentPath = WinkBridgeMenuClickRequest(appIdentifier: "Fixture", itemPath: "File > New")
        let currentNamed = WinkBridgeMenuClickByNameRequest(appIdentifier: "Fixture", itemName: "New")
        let legacyPath = WinkBridgeMenuClickRequest.legacyReceiptless(
            appIdentifier: "Fixture",
            itemPath: "File > New")
        let legacyNamed = WinkBridgeMenuClickByNameRequest.legacyReceiptless(
            appIdentifier: "Fixture",
            itemName: "New")

        #expect(currentPath.deliveryMode == .background)
        #expect(currentNamed.deliveryMode == .background)
        #expect(legacyPath.deliveryMode == nil)
        #expect(legacyNamed.deliveryMode == nil)
        #expect(try self.encodedObject(currentPath)["deliveryMode"] != nil)
        #expect(try self.encodedObject(currentNamed)["deliveryMode"] != nil)
        #expect(try self.encodedObject(legacyPath)["deliveryMode"] == nil)
        #expect(try self.encodedObject(legacyNamed)["deliveryMode"] == nil)

        let projected = WinkBridgeRequest.projectedAction(.init(request: .clickMenuItem(.init(
            appIdentifier: "PID:701",
            itemPath: "File > New",
            expectedIdentity: .init(processIdentifier: 701, processStartIdentity: 9001)))))
        let canonical = try WinkBridgeOperationReceiptCoding.canonicalData(projected)
        let decoded = try JSONDecoder.winkBridgeDecoder().decode(WinkBridgeRequest.self, from: canonical)
        #expect(try canonical == WinkBridgeOperationReceiptCoding.canonicalData(decoded))
    }

    private func encodedObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test
    func `Every unconditionally mutating wire operation has one explicit result contract`() {
        let expected: Set<WinkBridgeOperation> = [
            .agentExecutionTrace,
            .requestPostEventPermission,
            .browserConnect,
            .browserExecute,
            .click,
            .type,
            .typeActions,
            .targetedTypeActions,
            .exactWindowTargetedTypeActions,
            .exactWindowPixelFocusType,
            .foregroundModifierClick,
            .setValue,
            .selectText,
            .performAction,
            .scroll,
            .targetedScroll,
            .hotkey,
            .targetedHotkey,
            .exactWindowTargetedHotkey,
            .beginExactWindowHeldPointer,
            .exactWindowDrag,
            .releaseExactWindowHeldPointer,
            .revokeExactWindowHeldPointer,
            .disconnectExactWindowHeldPointerOwner,
            .targetedClick,
            .exactWindowTargetedClick,
            .swipe,
            .drag,
            .moveMouse,
            .focusWindow,
            .moveWindow,
            .resizeWindow,
            .setWindowBounds,
            .closeWindow,
            .backgroundCloseWindow,
            .minimizeWindow,
            .restoreWindow,
            .maximizeWindow,
            .launchApplication,
            .relaunchApplicationWithOptions,
            .activateApplication,
            .quitApplication,
            .hideApplication,
            .unhideApplication,
            .hideOtherApplications,
            .showAllApplications,
            .clickMenuItem,
            .clickMenuItemByName,
            .clickMenuExtra,
            .clickMenuBarItemNamed,
            .clickMenuBarItemIndex,
            .launchDockItem,
            .rightClickDockItem,
            .hideDock,
            .showDock,
            .dialogClickButton,
            .backgroundDialogClickButton,
            .dialogEnterText,
            .dialogHandleFile,
            .dialogDismiss,
            .exactDialogClickButton,
            .exactDialogDismiss,
            .exactDialogEnterText,
            .exactDialogForceDismiss,
        ]
        let classified = Set(WinkBridgeOperation.allCases.filter(\.mutatesDesktop))
        #expect(classified == expected)

        let exactContracts: [
            WinkBridgeOperation: WinkBridgeOperationResultSemantics.Contract
        ] = [
            .exactWindowPixelFocusType: .init(
                completion: .dispatchedUnverified(.init(mechanism: .composite, mode: .background)),
                targetPolicy: .requestPinned),
            .foregroundModifierClick: .init(
                completion: .dispatchedUnverified(.init(mechanism: .composite, mode: .foreground)),
                targetPolicy: .requestPinned),
        ]
        for operation in expected {
            let contract = WinkBridgeOperationResultSemantics.contract(for: operation)
            #expect(contract.completion != .readOnly, "Missing completion contract for \(operation)")
            #expect(contract.targetPolicy != .notApplicable, "Missing target contract for \(operation)")
            if let exactContract = exactContracts[operation] {
                #expect(contract == exactContract, "Incorrect explicit result contract for \(operation)")
            }
        }
    }

    @Test
    func `scroll result contract preserves native prefix unit counts`() throws {
        let request = WinkBridgeRequest.targetedScroll(WinkBridgeScrollRequest(request: ScrollRequest(
            direction: .down,
            amount: 3,
            target: "S1",
            snapshotId: "snapshot")))
        let accessibility = DesktopActionOutcome.Delivery(
            mechanism: .accessibilityAction,
            mode: .background)
        let accessibilityValue = DesktopActionOutcome.Delivery(
            mechanism: .accessibilityValue,
            mode: .background)
        let window = DesktopActionOutcome.Delivery(
            mechanism: .windowTargetedEvents,
            mode: .background)
        let three = try #require(DesktopActionOutcome.DispatchUnitCount(3))
        let two = try #require(DesktopActionOutcome.DispatchUnitCount(2))

        #expect(WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .dispatchedUnverified(
                route: .bridge,
                delivery: accessibility,
                evidence: .deliveryAccepted,
                unitCount: three),
            response: .ok,
            request: request))
        #expect(WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .confirmedChange(route: .bridge, delivery: accessibilityValue, unitCount: .one),
            response: .ok,
            request: request))
        #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .dispatchedUnverified(
                route: .bridge,
                delivery: accessibility,
                evidence: .deliveryAccepted,
                unitCount: two),
            response: .ok,
            request: request))

        #expect(WinkBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            .partial(route: .bridge, delivery: accessibility, unitCount: .one),
            request: request))
        #expect(WinkBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            .indeterminate(
                route: .bridge,
                delivery: accessibility,
                evidence: .completionUnknown,
                unitCount: two),
            request: request))
        #expect(WinkBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            .partial(route: .bridge, delivery: window, unitCount: .one),
            request: request))
        #expect(WinkBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            .refused(route: .bridge, reason: .targetUnavailable),
            request: request))
    }

    @Test
    func `Only request-shaped operations are conditionally mutating`() throws {
        let conditional: Set<WinkBridgeOperation> = [
            .desktopObservation,
            .detectElements,
            .inspectAccessibilityTree,
            .launchApplicationWithOptions,
            .captureScreen,
            .captureWindow,
            .captureFrontmost,
            .captureArea,
        ]
        let classified = Set(WinkBridgeOperation.allCases.filter {
            WinkBridgeOperationResultSemantics.contract(for: $0).completion ==
                .requestDependent(mutatesDesktop: false)
        })
        #expect(classified == conditional)

        let safeLaunch = WinkBridgeRequest.launchApplicationWithOptions(.init(
            applicationIdentifier: "TextEdit"))
        #expect(!safeLaunch.mayMutateDesktop)
        #expect(WinkBridgeOperationResultSemantics.contract(for: safeLaunch).completion == .readOnly)

        let url = try #require(URL(string: "https://example.invalid/"))
        let backgroundLaunch = WinkBridgeRequest.launchApplicationWithOptions(.init(
            applicationBundleIdentifier: "com.apple.TextEdit",
            openURLs: [url]))
        #expect(backgroundLaunch.mayMutateDesktop)
        #expect(WinkBridgeOperationResultSemantics.contract(for: backgroundLaunch) == .init(
            completion: .dispatchedUnverified(.init(
                mechanism: .nativeFramework,
                mode: .background)),
            targetPolicy: .responseResolved))

        let passiveObservation = WinkBridgeRequest.desktopObservation(.init(target: .frontmost))
        #expect(!passiveObservation.mayMutateDesktop)
        let foregroundObservation = WinkBridgeRequest.desktopObservation(.init(
            target: .frontmost,
            capture: .init(focus: .foreground)))
        #expect(foregroundObservation.mayMutateDesktop)
        #expect(WinkBridgeOperationResultSemantics.contract(for: foregroundObservation) == .init(
            completion: .dispatchedUnverified(.init(
                mechanism: .capturePipeline,
                mode: .foreground)),
            targetPolicy: .responseResolved))

        let passiveDetection = WinkBridgeRequest.detectElements(.init(
            imageData: Data(),
            snapshotId: nil,
            windowContext: nil))
        #expect(!passiveDetection.mayMutateDesktop)
        let webFocusDetection = WinkBridgeRequest.detectElements(.init(
            imageData: Data(),
            snapshotId: nil,
            windowContext: .init(shouldFocusWebContent: true)))
        #expect(webFocusDetection.mayMutateDesktop)
        #expect(WinkBridgeOperationResultSemantics.contract(for: webFocusDetection).targetPolicy ==
            .handlerRequired)
    }

    @Test
    func `Direct capture visualizers are one-unit background mutations while silent capture is read-only`() throws {
        let silentRequests: [WinkBridgeRequest] = [
            .captureScreen(.init(displayIndex: 0, visualizerMode: .none, scale: .logical1x)),
            .captureWindow(.init(
                appIdentifier: "Fixture",
                windowIndex: 0,
                visualizerMode: .none,
                scale: .logical1x)),
            .captureFrontmost(.init(visualizerMode: .none, scale: .logical1x)),
            .captureArea(.init(
                rect: CGRect(x: 1, y: 2, width: 30, height: 40),
                visualizerMode: .none,
                scale: .logical1x)),
        ]
        for request in silentRequests {
            #expect(!request.mayMutateDesktop)
            #expect(WinkBridgeOperationResultSemantics.contract(for: request).completion == .readOnly)
        }

        let cases: [(request: WinkBridgeRequest, target: WinkBridgeOperationResultSemantics.TargetPolicy)] = [
            (
                .captureScreen(.init(
                    displayIndex: 0,
                    visualizerMode: .screenshotFlash,
                    scale: .logical1x)),
                .global),
            (
                .captureWindow(.init(
                    appIdentifier: "Fixture",
                    windowIndex: 0,
                    visualizerMode: .watchCapture,
                    scale: .logical1x)),
                .responseResolved),
            (
                .captureFrontmost(.init(
                    visualizerMode: .screenshotFlash,
                    scale: .logical1x)),
                .responseResolved),
            (
                .captureArea(.init(
                    rect: CGRect(x: 1, y: 2, width: 30, height: 40),
                    visualizerMode: .watchCapture,
                    scale: .logical1x)),
                .global),
        ]
        let expectedDelivery = DesktopActionOutcome.Delivery(
            mechanism: .capturePipeline,
            mode: .background)
        let response = WinkBridgeResponse.capture(.init(
            imageData: Data(),
            metadata: .init(size: CGSize(width: 1, height: 1), mode: .screen)))

        for item in cases {
            #expect(item.request.mayMutateDesktop)
            #expect(WinkBridgeOperationResultSemantics.contract(for: item.request) == .init(
                completion: .dispatchedUnverified(expectedDelivery),
                targetPolicy: item.target))
            #expect(WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                .dispatchedUnverified(
                    route: .bridge,
                    delivery: expectedDelivery,
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                response: response,
                request: item.request))
            #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                .dispatchedUnverified(
                    route: .bridge,
                    delivery: expectedDelivery,
                    evidence: .deliveryAccepted,
                    unitCount: DesktopActionOutcome.DispatchUnitCount(2)),
                response: response,
                request: item.request))

            let finalized = try WinkBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                try WinkBridgeOperationResultSemantics.finalizeSuccessful(
                    request: item.request,
                    handled: .init(response: response))
            }
            #expect(finalized.outcome?.delivery == expectedDelivery)
            #expect(finalized.outcome?.dispatchState.unitCount == .one)
            switch (item.target, finalized.mutation?.target) {
            case (.global, .global), (.responseResolved, .responseResolved):
                break
            default:
                Issue.record("Capture mutation lost its canonical target policy")
            }
        }
    }

    @Test
    func `Request-aware input delivery and target policy are exact`() {
        let coordinates = WinkBridgeRequest.click(.init(
            target: .coordinates(.zero),
            clickType: .single))
        #expect(WinkBridgeOperationResultSemantics.contract(for: coordinates) == .init(
            completion: .dispatchedUnverified(.init(
                mechanism: .globalEvents,
                mode: .foreground)),
            targetPolicy: .global))

        let element = WinkBridgeRequest.click(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot"))
        #expect(WinkBridgeOperationResultSemantics.contract(for: element) == .init(
            completion: .dispatchedUnverified(.init(
                mechanism: .accessibilityAction,
                mode: .foreground)),
            targetPolicy: .handlerRequired))

        let globalType = WinkBridgeRequest.type(.init(
            text: "x",
            target: nil,
            clearExisting: false,
            typingDelay: 0,
            snapshotId: nil))
        let targetedType = WinkBridgeRequest.type(.init(
            text: "x",
            target: "field",
            clearExisting: false,
            typingDelay: 0,
            snapshotId: "snapshot"))
        #expect(WinkBridgeOperationResultSemantics.contract(for: globalType).targetPolicy == .global)
        #expect(WinkBridgeOperationResultSemantics.contract(for: targetedType).targetPolicy ==
            .handlerRequired)
    }

    @Test
    func `Multi-process hide is global while relaunch binds old and new generations`() throws {
        let firstHide = WinkBridgeRequest.hideOtherApplications(.init(identifier: "Fixture"))
        let secondHide = WinkBridgeRequest.hideOtherApplications(.init(identifier: "Other"))
        #expect(WinkBridgeOperationResultSemantics.contract(for: firstHide).targetPolicy == .global)
        #expect(
            try WinkBridgeOperationReceiptCoding.canonicalData(firstHide) !=
                WinkBridgeOperationReceiptCoding.canonicalData(secondHide))

        let hideIdentity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 9001)
        let exactHide = WinkBridgeRequest.hideApplication(.init(
            identifier: "PID:42",
            expectedIdentity: hideIdentity))
        #expect(WinkBridgeOperationResultSemantics.contract(for: exactHide).targetPolicy == .requestPinned)
        #expect(try WinkBridgeOperationTargetAttribution.resolveRequest(exactHide)?.processIdentity ==
            hideIdentity)
        #expect(throws: DesktopTargetIdentityError.self) {
            _ = try WinkBridgeOperationTargetAttribution.resolveRequest(
                .hideApplication(.init(identifier: "PID:42")))
        }

        let oldIdentity = ApplicationProcessIdentity(
            processIdentifier: 321,
            processStartIdentity: 654)
        let newIdentity = ApplicationProcessIdentity(
            processIdentifier: 321,
            processStartIdentity: 655)
        let request = WinkBridgeRequest.relaunchApplicationWithOptions(.init(
            targetIdentifier: "PID:321",
            expectedTargetIdentity: oldIdentity,
            launchRequest: .init(applicationBundleIdentifier: "dev.wink.fixture", activates: true)))
        let response = WinkBridgeResponse.application(.init(
            processIdentifier: newIdentity.processIdentifier,
            processStartIdentity: newIdentity.processStartIdentity,
            bundleIdentifier: "dev.wink.fixture",
            name: "Fixture"))

        #expect(WinkBridgeOperationResultSemantics.contract(for: request).targetPolicy == .responseResolved)
        #expect(try WinkBridgeOperationTargetAttribution.resolveReceipt(
            request: request,
            response: response).target == .process(newIdentity))
        let delivery = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .foreground)
        #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .confirmedChange(route: .bridge, delivery: delivery),
            response: response,
            request: request))
        #expect(WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .confirmedChange(
                route: .bridge,
                delivery: delivery,
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)),
            response: response,
            request: request))

        let changedRequest = WinkBridgeRequest.relaunchApplicationWithOptions(.init(
            targetIdentifier: "PID:321",
            expectedTargetIdentity: .init(
                processIdentifier: oldIdentity.processIdentifier,
                processStartIdentity: oldIdentity.processStartIdentity + 1),
            launchRequest: .init(applicationBundleIdentifier: "dev.wink.fixture", activates: true)))
        #expect(
            try WinkBridgeOperationReceiptCoding.canonicalData(request) !=
                WinkBridgeOperationReceiptCoding.canonicalData(changedRequest))

        let changedResponse = WinkBridgeResponse.application(.init(
            processIdentifier: newIdentity.processIdentifier,
            processStartIdentity: newIdentity.processStartIdentity + 1,
            bundleIdentifier: "dev.wink.fixture",
            name: "Fixture"))
        #expect(
            try WinkBridgeOperationReceiptCoding.canonicalData(response) !=
                WinkBridgeOperationReceiptCoding.canonicalData(changedResponse))

        let generationlessResponse = WinkBridgeResponse.application(.init(
            processIdentifier: newIdentity.processIdentifier,
            bundleIdentifier: "dev.wink.fixture",
            name: "Fixture"))
        #expect(throws: DesktopTargetIdentityError.self) {
            _ = try WinkBridgeOperationTargetAttribution.resolveReceipt(
                request: request,
                response: generationlessResponse)
        }
    }
}

extension WinkBridgeOperationResultSemanticsTests {
    @Test
    func `Successful nil outcome becomes dispatched-unverified without inventing confirmation`() throws {
        let request = WinkBridgeRequest.moveMouse(.init(
            to: CGPoint(x: 10, y: 20),
            duration: 0,
            steps: 1,
            profile: .linear))
        let finalized = try WinkBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try WinkBridgeOperationResultSemantics.finalizeSuccessful(
                request: request,
                handled: .init(response: .ok))
        }
        let mutation = try #require(finalized.mutation)
        #expect(mutation.outcome.state == .dispatchedUnverified)
        #expect(mutation.outcome.delivery == .init(
            mechanism: .globalEvents,
            mode: .foreground))
        #expect(mutation.outcome.evidence == .deliveryAccepted)
        #expect(mutation.outcome.route == .bridge)
        #expect(mutation.outcome.dispatchState.unitCount == .one)
        guard case .global = mutation.target else {
            Issue.record("Global pointer movement must retain an explicit global target")
            return
        }
    }

    @Test
    func `Synthesized variable-count success fails conservatively after execution`() throws {
        let request = WinkBridgeRequest.hotkey(.init(keys: "cmd,a", holdDuration: 0))

        do {
            _ = try WinkBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                try WinkBridgeOperationResultSemantics.finalizeSuccessful(
                    request: request,
                    handled: .init(response: .ok))
            }
            Issue.record("Expected receiptless variable-count success to fail closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
            #expect(failure.outcome.dispatchState.unitCount == nil)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
    }

    @Test
    func `Handler target cannot launder an ambiguous one-of dispatch count`() throws {
        let identity = WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: 420,
            ownerProcessStartIdentity: 9001,
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let bounds = try #require(identity.capturedBounds)
        let target = try DesktopTargetIdentity(
            exactWindow: UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds))
        let request = WinkBridgeRequest.setWindowBounds(.init(
            target: .windowId(identity.windowID),
            expectedIdentity: identity,
            bounds: bounds))
        let handled = WinkBridgeHandledResponse(response: .ok, targetIdentity: target)

        do {
            _ = try WinkBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                try WinkBridgeOperationResultSemantics.finalizeSuccessful(
                    request: request,
                    handled: handled)
            }
            Issue.record("Expected ambiguous synthesized count to fail despite exact target evidence")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
            #expect(failure.outcome.dispatchState.unitCount == nil)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
    }

    @Test
    func `Returned action failures outrank missing mutation synthesis`() throws {
        let request = WinkBridgeRequest.moveMouse(.init(
            to: .zero,
            duration: 0,
            steps: 1,
            profile: .linear))
        let failures = [
            DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Target disappeared before dispatch"),
            DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Delivery completion is unknown"),
        ]

        for failure in failures {
            let handled = WinkBridgeHandledResponse(response: .error(.init(
                code: .internalError,
                actionFailure: failure)))
            do {
                _ = try WinkBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                    try WinkBridgeOperationResultSemantics.finalizeSuccessful(
                        request: request,
                        handled: handled)
                }
                Issue.record("Expected the returned action failure to survive finalization")
            } catch let actual as DesktopActionFailure {
                #expect(actual == failure.routed(to: .bridge))
            }
        }
    }

    @Test
    func `Multi-route missing mutation success becomes unattributed indeterminate`() throws {
        let request = WinkBridgeRequest.click(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: nil))

        do {
            _ = try WinkBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                try WinkBridgeOperationResultSemantics.finalizeSuccessful(
                    request: request,
                    handled: .init(response: .ok))
            }
            Issue.record("Expected multi-route success without native evidence to fail closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.delivery == nil)
            #expect(failure.outcome.dispatchState.unitCount == nil)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
    }

    @Test
    func `Native outcome and exact handler target survive finalization unchanged`() throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 321, processStartIdentity: 654)
        let target = try DesktopTargetIdentity(processIdentity: identity)
        let outcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            unitCount: .one)
        let handled = WinkBridgeHandledResponse(
            response: .ok,
            mutation: .init(outcome: outcome, target: .handlerResolved(target)))
        let request = WinkBridgeRequest.targetedHotkey(.init(
            keys: "cmd,a",
            holdDuration: 0,
            targetProcessIdentifier: identity.processIdentifier,
            expectedProcessIdentity: identity))
        let finalized = try WinkBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try WinkBridgeOperationResultSemantics.finalizeSuccessful(
                request: request,
                handled: handled)
        }
        #expect(finalized.outcome == outcome)
        #expect(finalized.targetIdentity == target)
    }

    @Test
    func `Unattested success does not invent receipt-only result semantics`() throws {
        let handled = WinkBridgeHandledResponse(response: .ok)
        let finalized = try WinkBridgeOperationResultSemantics.finalizeSuccessful(
            request: .clickMenuItem(.init(appIdentifier: "Fixture", itemPath: "File > New")),
            handled: handled)

        #expect(finalized.mutation == nil)
        guard case .ok = finalized.response else {
            Issue.record("Expected the legacy success response")
            return
        }
    }

    @Test
    func `Failure stage is explicit and never inferred as successful dispatch`() {
        let request = WinkBridgeRequest.moveMouse(.init(
            to: .zero,
            duration: 0,
            steps: 1,
            profile: .linear))
        let base = WinkBridgeErrorEnvelope(code: .unauthorizedClient, message: "peer rejected")

        let transport = WinkBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            WinkBridgeOperationResultSemantics.canonicalFailure(
                base,
                request: request,
                stage: .preDispatch(.transportSessionUnavailable))
        }
        #expect(transport.actionOutcome?.outcome.state == .refused)
        #expect(transport.actionOutcome?.outcome.refusalReason == .transportSessionUnavailable)
        #expect(transport.actionOutcome?.outcome.escalation == .reconnectSession)
        #expect(transport.actionOutcome?.mutationDispatched == false)

        let cancelled = WinkBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            WinkBridgeOperationResultSemantics.canonicalFailure(
                .init(code: .timeout, message: "cancelled"),
                request: request,
                stage: .preDispatch(.requestCancelled))
        }
        #expect(cancelled.actionOutcome?.outcome.refusalReason == .requestCancelled)
        #expect(cancelled.actionOutcome?.outcome.escalation == DesktopActionOutcome.Escalation.none)

        let unknown = WinkBridgeOperationResultSemantics.canonicalFailure(
            .init(code: .internalError, message: "leaf failed"),
            request: request,
            stage: .executionMayHaveStarted)
        #expect(unknown.actionOutcome?.outcome.state == .indeterminate)
        #expect(unknown.actionOutcome?.mutationDispatched == true)
        #expect(unknown.actionOutcome?.retrySafe == false)
    }

    @Test
    func `Mixed Dock selection failure accepts only its exact two-unit progress`() throws {
        let request = WinkBridgeRequest.rightClickDockItem(.init(
            appName: "Safari",
            menuItem: "Options"))
        let twoUnits = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        let mixedFailure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: twoUnits,
            message: "The Dock right-click and menu selection may both have been dispatched.")

        #expect(mixedFailure.outcome.delivery == .init(mechanism: .composite, mode: .foreground))
        #expect(mixedFailure.outcome.retrySafety == .unsafe)
        #expect(WinkBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            mixedFailure.outcome,
            request: request))

        let success = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: twoUnits)
        #expect(WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            success,
            request: request))
        #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one),
            request: request))

        for invalidCount in [1, 3] {
            let invalidUnits = try #require(DesktopActionOutcome.DispatchUnitCount(invalidCount))
            let invalid = DesktopActionFailure.indeterminate(
                route: .bridge,
                evidence: .completionUnknown,
                unitCount: invalidUnits,
                message: "Invalid mixed Dock progress.")
            #expect(!WinkBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                invalid.outcome,
                request: request))
        }

        let rightClickOnly = WinkBridgeRequest.rightClickDockItem(.init(
            appName: "Safari",
            menuItem: nil))
        #expect(!WinkBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            mixedFailure.outcome,
            request: rightClickOnly))
    }

    @Test
    func `External target marker is not accepted as target proof`() throws {
        let request = WinkBridgeRequest.browserExecute(.init(toolName: "noop", arguments: [:]))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted)
        let unresolved = WinkBridgeHandledResponse(
            response: .ok,
            mutation: .init(outcome: outcome, target: .external))
        #expect(throws: DesktopTargetIdentityError.self) {
            try WinkBridgeOperationResultSemantics.validateSuccessfulTargetDisposition(
                request: request,
                handled: unresolved)
        }

        let target = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 222,
            processStartIdentity: 333))
        let resolved = WinkBridgeHandledResponse(
            response: .ok,
            mutation: .init(outcome: outcome, target: .handlerResolved(target)))
        try WinkBridgeOperationResultSemantics.validateSuccessfulTargetDisposition(
            request: request,
            handled: resolved)
    }

    @Test
    func `Nested projected no-dispatch failure bypasses successful target policy`() throws {
        let request = WinkBridgeRequest.hideApplication(.init(identifier: "TextEdit"))
        let failure = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "Target disappeared before dispatch.",
            hint: "Refresh the application target.")
        let envelope = WinkBridgeErrorEnvelope(code: .notFound, actionFailure: failure)
        let response = WinkBridgeResponse.projectedAction(.init(
            response: .error(envelope),
            outcome: failure.outcome.projection))
        let handled = WinkBridgeHandledResponse(response: response)

        try WinkBridgeOperationResultSemantics.validateSuccessfulTargetDisposition(
            request: request,
            handled: handled)
        #expect(try WinkBridgeOperationTargetAttribution.resolve(
            request: request,
            response: response,
            handledTarget: nil) == nil)
    }

    @Test
    func `Request-pinned dispatched failure retains exact request attribution`() throws {
        let identity = WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: 420,
            ownerProcessStartIdentity: 9001,
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let focus = WinkBridgeRequest.focusWindow(.init(
            target: .windowId(identity.windowID),
            expectedIdentity: identity))
        let request = WinkBridgeRequest.projectedAction(.init(request: focus))
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Focus completion is uncertain")
        let response = WinkBridgeResponse.projectedAction(.init(
            response: .error(.init(code: .internalError, actionFailure: failure)),
            outcome: failure.outcome.projection))
        let handled = WinkBridgeHandledResponse(response: response)

        try WinkBridgeOperationResultSemantics.validateSuccessfulTargetDisposition(
            request: request,
            handled: handled)
        #expect(try WinkBridgeOperationTargetAttribution.resolve(
            request: request,
            response: response,
            handledTarget: nil)?.exactWindow?.identity == identity)
    }

    @Test
    func `Nested projected error without an outcome is not no-dispatch evidence`() {
        let request = WinkBridgeRequest.hideApplication(.init(identifier: "TextEdit"))
        let response = WinkBridgeResponse.projectedAction(.init(
            response: .error(.init(code: .internalError, message: "Outcome missing")),
            outcome: nil))
        let handled = WinkBridgeHandledResponse(response: response)

        #expect(!WinkBridgeOperationResultSemantics.isNoDispatchFailure(response))
        #expect(throws: DesktopTargetIdentityError.self) {
            try WinkBridgeOperationResultSemantics.validateSuccessfulTargetDisposition(
                request: request,
                handled: handled)
        }
        #expect(throws: DesktopTargetIdentityError.self) {
            _ = try WinkBridgeOperationTargetAttribution.resolve(
                request: request,
                response: response,
                handledTarget: nil)
        }
    }
}
