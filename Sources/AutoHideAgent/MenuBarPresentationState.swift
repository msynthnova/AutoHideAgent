/// Coordinates the shared status-item selection and asynchronous panel transitions.
struct MenuBarPresentationState {
    enum PanelPhase { case closed, open, closing }

    private(set) var panelPhase: PanelPhase = .closed
    private(set) var transitionID = 0

    mutating func openPanel() {
        transitionID += 1
        panelPhase = .open
    }

    @discardableResult
    mutating func beginClosingPanel() -> Int {
        transitionID += 1
        panelPhase = .closing
        return transitionID
    }

    @discardableResult
    mutating func finishClosingPanel(transitionID: Int) -> Bool {
        guard self.transitionID == transitionID, panelPhase == .closing else { return false }
        panelPhase = .closed
        return true
    }

    func shouldHighlight(panelIsVisible: Bool, dashboardIsFocused: Bool) -> Bool {
        (panelPhase == .open && panelIsVisible) || dashboardIsFocused
    }
}
