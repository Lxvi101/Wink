//
//  ScreenCaptureService+Support.swift
//  WinkCore
//

import Foundation
@preconcurrency import ScreenCaptureKit

extension SCShareableContent: @retroactive @unchecked Sendable {}
extension SCDisplay: @retroactive @unchecked Sendable {}
extension SCWindow: @retroactive @unchecked Sendable {}
