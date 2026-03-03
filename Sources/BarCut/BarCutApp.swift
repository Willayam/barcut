import SwiftUI

@main
struct BarCutApp: App {
    @StateObject private var monitor = ClipboardMonitor()
    @State private var interceptor: ScreenshotInterceptor?

    var body: some Scene {
        MenuBarExtra {
            ImageHistoryView(monitor: monitor)
                .onAppear {
                    if interceptor == nil {
                        interceptor = ScreenshotInterceptor(monitor: monitor)
                    }
                }
        } label: {
            Image(systemName: "photo.on.rectangle.angled")
        }
        .menuBarExtraStyle(.window)
    }
}
