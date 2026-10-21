import CoreGraphics
import Foundation
import WinkCore
import WinkFoundation

@MainActor
extension SeeCommand {
    func menuBarRect() throws -> CGRect {
        let screens = self.services.screens.listScreens()
        guard let mainScreen = screens.first(where: \.isPrimary) ?? screens.first else {
            throw WinkError.captureFailed("No main screen found")
        }

        let menuBarHeight = self.menuBarHeight(for: mainScreen)
        return CGRect(
            x: mainScreen.frame.origin.x,
            y: mainScreen.frame.origin.y + mainScreen.frame.height - menuBarHeight,
            width: mainScreen.frame.width,
            height: menuBarHeight
        )
    }

    private func menuBarHeight(for screen: ScreenInfo) -> CGFloat {
        let height = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        return height > 0 ? height : 24.0
    }
}
