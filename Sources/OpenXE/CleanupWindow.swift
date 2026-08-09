import AppKit
import OpenXECore

/// The removal window. Spec 2026-08-09 §6.
///
/// Two states in one window: a plan the user confirms, then a result. It is a
/// separate window rather than an alert because the user has to be able to read
/// a list and make a second, independent choice about their own data before
/// anything happens — and because that choice must default to the safe answer,
/// which an alert's button layout does not express well.
@MainActor
final class CleanupWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let paths: OpenXEPaths
    private let onClose: () -> Void

    private let scroll = NSScrollView()
    private let itemsView = NSTextView()
    private let spaceLabel = NSTextField(labelWithString: "")
    private let deleteDataCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let dataNoteLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    private let cancelButton = NSButton()
    private let showSavedButton = NSButton()
    private let quitButton = NSButton()

    private var plan: CleanupPlan?
    private var savedDataURL: URL?

    init(paths: OpenXEPaths, onClose: @escaping () -> Void) {
        self.paths = paths
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()

        window.title = SetupCopy.cleanupWindowTitle
        window.isReleasedWhenClosed = false
        window.delegate = self

        let headline = NSTextField(labelWithString: SetupCopy.cleanupHeadline)
        headline.font = .boldSystemFont(ofSize: 15)

        let explanation = wrapping(SetupCopy.cleanupExplanation)
        let notAReset = wrapping(SetupCopy.cleanupNotAReset)
        notAReset.textColor = .secondaryLabelColor
        notAReset.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let itemsHeading = NSTextField(labelWithString: SetupCopy.cleanupItemsHeading)
        itemsHeading.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)

        itemsView.isEditable = false
        itemsView.drawsBackground = false
        itemsView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        itemsView.textColor = .secondaryLabelColor
        scroll.documentView = itemsView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true

        spaceLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        // Off by default. The default answer is the one that loses nothing.
        deleteDataCheckbox.title = SetupCopy.cleanupKeepDataCheckbox
        deleteDataCheckbox.state = .off
        deleteDataCheckbox.target = self
        deleteDataCheckbox.action = #selector(dataChoiceChanged)

        dataNoteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        dataNoteLabel.textColor = .secondaryLabelColor
        dataNoteLabel.lineBreakMode = .byWordWrapping
        dataNoteLabel.preferredMaxLayoutWidth = 420

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = 420

        configure(removeButton, SetupCopy.cleanupConfirmButton, #selector(confirmRemoval))
        configure(cancelButton, SetupCopy.cleanupCancelButton, #selector(cancel))
        configure(showSavedButton, SetupCopy.cleanupShowSavedButton, #selector(showSaved))
        configure(quitButton, SetupCopy.cleanupQuitButton, #selector(quit))
        showSavedButton.isHidden = true
        quitButton.isHidden = true

        let buttons = NSStackView(views: [removeButton, cancelButton, showSavedButton, quitButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [headline, explanation, notAReset, itemsHeading, scroll,
                                        spaceLabel, deleteDataCheckbox, dataNoteLabel,
                                        statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        window.contentView = stack
    }

    private func configure(_ button: NSButton, _ title: String, _ action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
    }

    private func wrapping(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.preferredMaxLayoutWidth = 420
        field.isSelectable = false
        return field
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        buildPlan()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    // MARK: plan

    private func buildPlan() {
        statusLabel.stringValue = ""
        let paths = self.paths
        Task {
            let built = await Task.detached { CleanupPlanner.live(paths: paths).plan() }.value
            self.plan = built
            self.present(built)
        }
    }

    private func present(_ plan: CleanupPlan) {
        if plan.isEmpty {
            itemsView.string = "Nothing to remove — OpenXE has not set anything up on this Mac."
            spaceLabel.stringValue = ""
            deleteDataCheckbox.isHidden = true
            dataNoteLabel.stringValue = ""
            removeButton.isEnabled = false
            return
        }
        itemsView.string = plan.targets.map { "•  \($0.label)" }.joined(separator: "\n")
        spaceLabel.stringValue = SetupCopy.cleanupSpaceSummary(bytes: plan.totalBytes)

        let hasData = plan.nwsDataDirectory != nil
        deleteDataCheckbox.isHidden = !hasData
        if hasData {
            spaceLabel.stringValue += " " + SetupCopy.cleanupDataSummary(bytes: plan.nwsDataBytes)
        }
        dataChoiceChanged()
    }

    @objc private func dataChoiceChanged() {
        guard plan?.nwsDataDirectory != nil else {
            dataNoteLabel.stringValue = ""
            return
        }
        let deleting = deleteDataCheckbox.state == .on
        dataNoteLabel.stringValue = deleting
            ? SetupCopy.cleanupDeleteDataWarning
            : SetupCopy.cleanupKeepDataDefaultNote
        dataNoteLabel.textColor = deleting ? .systemRed : .secondaryLabelColor
    }

    // MARK: run

    @objc private func cancel() {
        window.close()
    }

    @objc private func confirmRemoval() {
        guard let plan else { return }
        let keepData = deleteDataCheckbox.state == .off

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = SetupCopy.cleanupHeadline + "?"
        alert.informativeText = keepData
            ? SetupCopy.cleanupExplanation + "\n\n" + SetupCopy.cleanupKeepDataDefaultNote
            : SetupCopy.cleanupExplanation + "\n\n" + SetupCopy.cleanupDeleteDataWarning
        alert.addButton(withTitle: SetupCopy.cleanupConfirmButton)
        alert.addButton(withTitle: SetupCopy.cleanupCancelButton)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        removeButton.isEnabled = false
        cancelButton.isEnabled = false
        deleteDataCheckbox.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = SetupCopy.cleanupWorking

        let paths = self.paths
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Handed over as-is: under App Translocation this is a randomized
        // read-only mount, and `CleanupRunner.live` resolves it to the installed
        // bundle before anything is told about it. The Shell holds no path logic.
        let bundleURL = Bundle.main.bundleURL
        Task {
            let result = await Task.detached { () -> Result<CleanupOutcome, Error> in
                do {
                    let runner = CleanupRunner.live(paths: paths, bundleURL: bundleURL)
                    return .success(try runner.run(plan: plan, keepNWSData: keepData,
                                                   documentsDirectory: documents, now: Date()))
                } catch {
                    return .failure(error)
                }
            }.value
            self.finish(result)
        }
    }

    private func finish(_ result: Result<CleanupOutcome, Error>) {
        switch result {
        case .failure(let error):
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = error.localizedDescription
            removeButton.isEnabled = true
            cancelButton.isEnabled = true
            deleteDataCheckbox.isEnabled = true

        case .success(let outcome):
            var lines = [SetupCopy.cleanupDone(reclaimed: outcome.reclaimedBytes)]
            if let saved = outcome.preserved {
                savedDataURL = saved.destination
                lines.append(SetupCopy.cleanupSavedTo(saved.destination.lastPathComponent))
                showSavedButton.isHidden = false
            }
            if !outcome.skipped.isEmpty {
                lines.append(SetupCopy.cleanupPartial(outcome.skipped))
            }
            // The honest last word: a running app cannot delete its own bundle.
            lines.append(SetupCopy.cleanupDragToTrash)

            statusLabel.textColor = .labelColor
            statusLabel.stringValue = lines.joined(separator: "\n\n")
            itemsView.string = outcome.removed.map { "•  \($0.label)" }.joined(separator: "\n")
            spaceLabel.stringValue = ""
            deleteDataCheckbox.isHidden = true
            dataNoteLabel.stringValue = ""
            removeButton.isHidden = true
            cancelButton.isHidden = true
            quitButton.isHidden = false
            window.setContentSize(NSSize(width: 460, height: 520))
        }
    }

    @objc private func showSaved() {
        guard let savedDataURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedDataURL])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
