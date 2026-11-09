import Foundation
import Sparkle
import Combine

@MainActor
public final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    public static let shared = UpdateController()

    public private(set) var updaterController: SPUStandardUpdaterController!
    @Published public var canCheckForUpdates: Bool = false
    @Published public var automaticallyChecksForUpdates: Bool = true {
        didSet {
            guard updaterController != nil else { return }
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    @Published public var lastUpdateCheckDate: Date? = nil

    private var cancellables = Set<AnyCancellable>()

    override private init() {
        super.init()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.updaterController = controller
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        self.lastUpdateCheckDate = controller.updater.lastUpdateCheckDate
        self.canCheckForUpdates = controller.updater.canCheckForUpdates

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
            .store(in: &cancellables)

        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .sink { [weak self] date in
                self?.lastUpdateCheckDate = date
            }
            .store(in: &cancellables)
    }

    public func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    public var friendlyLastCheckDate: String {
        guard let date = lastUpdateCheckDate else {
            return "Never"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date.now)
    }
}
