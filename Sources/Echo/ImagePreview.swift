import AppKit
import SwiftUI

private final class ImagePreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A local child window keeps the clipboard panel and its editor intact.
final class ImagePreviewController: NSObject, NSWindowDelegate {
    let window: NSPanel
    private weak var parent: NSWindow?
    private weak var previousResponder: NSResponder?
    private let onClose: () -> Void

    init(parent: NSWindow, ref: ImageRef, onClose: @escaping () -> Void) {
        self.parent = parent
        self.previousResponder = parent.firstResponder
        self.onClose = onClose
        let frame = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        window = ImagePreviewPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = parent.level
        window.delegate = self
        window.contentView = NSHostingView(rootView: ImagePreviewView(ref: ref, onClose: onClose))
    }

    func show() {
        parent?.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    func close(restoreFocus: Bool) {
        window.delegate = nil
        parent?.removeChildWindow(window)
        window.orderOut(nil)
        window.contentView = nil
        if restoreFocus {
            parent?.makeKeyAndOrderFront(nil)
            if let previousResponder { parent?.makeFirstResponder(previousResponder) }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Moving to another app closes both layers through the parent's normal dismissal.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window.isVisible, NSApp.keyWindow !== self.window else { return }
            if NSApp.keyWindow === self.parent { self.onClose() }
            else { QuickPanelController.shared.hide() }
        }
    }
}

private struct ImagePreviewView: View {
    let ref: ImageRef
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var failed = false
    @State private var enlarged = false

    private var palette: EchoTheme.Palette { EchoTheme.panelPalette(for: colorScheme) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.22).contentShape(Rectangle()).onTapGesture(perform: onClose)
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.text("preview.close"))
                        Text(L10n.text("preview.title")).fontWeight(.medium)
                        Spacer()
                        Text(ref.sizeText).font(.system(size: 10)).foregroundStyle(palette.textTertiary)
                        if image != nil {
                            Button(L10n.text(enlarged ? "preview.fit" : "preview.enlarge")) {
                                enlarged.toggle()
                            }.font(.system(size: 11))
                        }
                    }
                    .padding(.horizontal, 16).frame(height: 47)
                    Divider()
                    GeometryReader { area in
                        if let image {
                            if enlarged {
                                ScrollView([.horizontal, .vertical]) {
                                    Image(nsImage: image).resizable()
                                        .frame(width: max(image.size.width, area.size.width - 44),
                                               height: max(image.size.width, area.size.width - 44) * image.size.height / max(1, image.size.width))
                                        .padding(22)
                                }
                            } else {
                                Image(nsImage: image).resizable().scaledToFit()
                                    .padding(22).frame(width: area.size.width, height: area.size.height)
                            }
                        } else if failed {
                            VStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle")
                                Text(L10n.text("preview.failed"))
                            }.frame(width: area.size.width, height: area.size.height)
                        } else {
                            ProgressView().frame(width: area.size.width, height: area.size.height)
                        }
                    }
                    .frame(height: max(120, min(530, geometry.size.height - 160)))
                    .background(palette.thumbnailBackground)
                    Divider()
                    HStack {
                        Text(L10n.text("preview.local"))
                        Spacer()
                        Text(L10n.text("preview.dismiss"))
                    }.font(.system(size: 10)).foregroundStyle(palette.textTertiary)
                        .padding(.horizontal, 16).frame(height: 33)
                }
                .font(.system(size: 12)).foregroundStyle(palette.textPrimary)
                .frame(width: max(240, min(740, geometry.size.width - 48)))
                .background(palette.windowBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.borderStrong))
                .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            }
        }
        .task {
            let path = ref.diskPath
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: path) }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
            failed = image == nil
            if failed { NSLog("[Echo] Image preview could not load %@", path.lastPathComponent) }
        }
    }
}
