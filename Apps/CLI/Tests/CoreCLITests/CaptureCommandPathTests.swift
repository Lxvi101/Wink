import Foundation
import Testing
@testable import WinkCLI

struct CaptureCommandPathTests {
    @Test
    func `live output directory expands tilde`() throws {
        var cmd = CaptureLiveCommand()
        cmd.path = "~/Desktop/wink-live"

        let url = try cmd.resolveOutputDirectory()

        #expect(url.path == NSString(string: "~/Desktop/wink-live").expandingTildeInPath)
    }

    @Test
    func `video paths expand tilde`() throws {
        var cmd = CaptureVideoCommand()
        cmd.input = "~/Movies/input.mov"
        cmd.path = "~/Desktop/wink-video"
        cmd.videoOut = "~/Desktop/wink-video.mp4"

        let inputURL = cmd.inputVideoURL()
        let outputURL = try cmd.resolveOutputDirectory()
        let videoOut = CaptureCommandPathResolver.filePath(from: cmd.videoOut)

        #expect(inputURL.path == NSString(string: "~/Movies/input.mov").expandingTildeInPath)
        #expect(outputURL.path == NSString(string: "~/Desktop/wink-video").expandingTildeInPath)
        #expect(videoOut == NSString(string: "~/Desktop/wink-video.mp4").expandingTildeInPath)
    }
}
