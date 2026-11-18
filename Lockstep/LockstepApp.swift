import AppKit
import LockstepCore
import LockstepUI
import SwiftUI

@main
struct LockstepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The app's one model. The delegate owns it, because the delegate is who macOS
    /// tells that Lockstep is about to quit.
    private var model: AppModel { appDelegate.model }

    init() {
        if LaunchOptions.current.isScratch {
            ScratchWindowFrames.keepOutOfMaxSettings()
            // macOS keeps one memory of open windows for Lockstep, shared by Max's copy and every
            // scratch run. A scratch run restores nothing, so it left that memory saying "no window",
            // and the next scratch run then came up with no window and did nothing. With this, a
            // scratch run neither reads that memory nor writes to it. Registered, not saved: it
            // holds for this run only.
            UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        }
        // Before the menus exist, so macOS never adds what Lockstep has no use for.
        MenuCleaner.switchOffTextHelpers()
        MenuCleaner.app.start()
    }

    /// What Debug > Add Test Clips does in a debug build. A release build gets nil, and
    /// with it no Debug menu.
    private static func addTestClips(to model: AppModel) -> (@MainActor () -> Void)? {
        #if DEBUG
        return { model.clipEditing.addTestClips() }
        #else
        return nil
        #endif
    }

    var body: some Scene {
        Window("Lockstep", id: "main") {
            MainWindow(model: model)
                .frame(
                    minWidth: DesignTokens.Sizes.minimumWindowWidth,
                    minHeight: DesignTokens.Sizes.minimumWindowHeight
                )
                .remembersWindowFrame(name: "main")
        }
        .defaultSize(width: 1200, height: 720)
        .windowResizability(.contentMinSize)
        .restorationBehavior(LaunchOptions.current.isScratch ? .disabled : .automatic)
        .commands {
            AppCommands(
                built: model.features,
                store: model.store,
                recent: model.recentProjects,
                openRecent: { model.openingModel.open($0) },
                perform: { model.perform($0) },
                isEnabled: { model.canPerform($0) },
                isOn: { model.isOn($0) },
                title: { model.menuTitle(of: $0) },
                canUndo: { !model.transport.isTakeGoing },
                undo: { model.clipEditing.timeEdit("Undo") { model.store.undo() } },
                redo: { model.clipEditing.timeEdit("Redo") { model.store.redo() } },
                mergeTargets: { model.tracks.mergeTargets },
                mergeInto: { model.tracks.mergeSelectedTrack(into: $0) },
                aimTargets: { model.correction.aimTargets },
                aimIsChosen: { model.correction.aimIsChosen($0) },
                aimAt: { model.aimSelectedClips(at: $0) },
                addTestClips: Self.addTestClips(to: model)
            )
        }

        // The system's settings window: Lockstep > Settings, Command-comma.
        Settings {
            SettingsView(settings: model.settings, delays: model.measuredDelaysLink, resolveScript: model.send.resolveScript)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    /// Carries out the shortcuts before a focused control sees the key. See `ShortcutKeys`.
    private lazy var shortcutKeys = ShortcutKeys(
        canPerform: { [model] in model.canPerform($0) },
        perform: { [model] in model.perform($0) }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        shortcutKeys.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// A project was double-clicked in Finder, dropped on Lockstep's icon or chosen from
    /// the Dock's list of recent projects.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        model.openingModel.open(url)
    }

    /// Quit during a take: the take is stopped and made into a clip first, and only then
    /// does Lockstep quit, so what was recorded is kept.
    ///
    /// Quit after the speech model was used: it is stopped and freed first. With the model
    /// still loaded the process would fail on its way out.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.transport.isTakeGoing || model.words.hasSpeechModelToShutDown || model.voice.isMaking
        else { return .terminateNow }
        Task {
            if model.transport.isTakeGoing {
                await model.transport.finishTakeBeforeQuitting()
            }
            // Voices that are being made let go of their files first, so the project's voices folder is tidied
            // when it closes on the way out.
            await model.voice.stopMaking()
            // After the take, whose clip may just have been handed to the speech model.
            await model.words.shutDownWords()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// A change made less than half a second before quitting is still waiting to be
    /// saved. It is written now.
    func applicationWillTerminate(_ notification: Notification) {
        model.openingModel.saveBeforeClosing()
        // Last, so closing the project is counted too. Only a scratch run prints the line.
        RunCounts.shared.tellAgent(voices: model.voice.countsForAgent)
    }
}
