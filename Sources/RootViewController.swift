import AppKit

/// Window content: sidebar | editor split. There is no status bar — the panel
/// buttons live in the sidebar's bottom action bar (Zed layout).
///
/// The sidebar can be put away with the toggle beside the traffic lights (or
/// ⌘B). Away, the pointer resting on the toggle brings it out over the editor
/// — floating, so the editor does not move — until the pointer leaves it.
final class RootViewController: NSViewController {
    let split = PuzzleSplitViewController()
    let sidebar: SidebarViewController
    let editor: EditorViewController

    /// Panel width is preserved across panel switches. The floor is what the
    /// Git panel's rows need before names start truncating.
    static let minimumSidebarWidth: CGFloat = 300
    /// What a window opens at: half its own width. The panel now holds the
    /// file tree and the project's Git lists side by side, and a fixed width
    /// that suited one of them left both cramped on a wide window.
    static let defaultSidebarFraction: CGFloat = 0.5
    /// The width the panel is given before the window has one of its own to
    /// take half of — replaced on the first layout.
    private static let provisionalSidebarWidth: CGFloat = 500
    private var minimumSidebarWidth: CGFloat { Self.minimumSidebarWidth }
    private var lastSidebarWidth: CGFloat = RootViewController.provisionalSidebarWidth
    /// Whether the opening width has been settled. It is settled once: after
    /// that the width is the one the reader dragged to, and a window that is
    /// resized keeps its panel while the editor takes up the difference.
    private var hasSettledOpeningWidth = false
    /// Owns the panel width so switching panels can never change it. Dragging the
    /// divider updates its constant, so the divider still works.
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarItem: NSSplitViewItem!
    /// What the panel has been asked to be, which the animator reaches a
    /// moment later: away for the start page, or because the reader put it
    /// away.
    private var sidebarHidden = false
    /// The start page's reason: a window with no project has nothing to show
    /// in the panel.
    private var pageHidesSidebar = false
    /// The reader's reason: the toggle, or ⌘B.
    private(set) var sidebarCollapsed = false
    /// How long the panel takes to slide away or back.
    private static let slideDuration: TimeInterval = 0.18
    private let dividerHandle = SplitDividerHandleView()
    private var dividerDragStartWidth: CGFloat = 400

    /// What the split holds in the sidebar's place. The sidebar's own view
    /// sits inside it — or, while it floats, in `floatView` — so it can slide
    /// at its full width instead of being squeezed as the split narrows.
    private let sidebarHost = SidebarHostViewController()
    /// The sidebar filling the host: how it sits while it is out.
    private var contentLeading: NSLayoutConstraint?
    /// The sidebar at a width of its own, against the host's right edge:
    /// how it sits while it slides, and while it is away.
    private var contentWidth: NSLayoutConstraint?

    let sidebarToggle = SidebarToggleButton()
    private var toggleLeading: NSLayoutConstraint!
    private var toggleCenterY: NSLayoutConstraint!

    private let floatView = SidebarFloatView()
    private var floatLeading: NSLayoutConstraint!
    private var floatWidth: NSLayoutConstraint!
    /// Out over the editor, or on its way out.
    private(set) var isFloating = false
    /// How long the pointer rests on the toggle before the sidebar floats
    /// out: long enough that crossing the band on the way to a tab does not.
    static let floatDelay: TimeInterval = 0.12
    /// How long a floating sidebar waits once the pointer has left it, so a
    /// path that clips its edge does not send it away.
    static let floatLeaveDelay: TimeInterval = 0.3
    private static let floatInDuration: TimeInterval = 0.18
    private static let floatOutDuration: TimeInterval = 0.15
    private var pointerOnToggle = false
    private var pointerOnFloat = false
    /// Put away under the pointer: it does not float straight back out. The
    /// pointer has to leave the toggle and come back.
    private var floatWaitsForPointerToLeave = false
    /// A menu opened from inside the float takes the pointer out of it; the
    /// float stays until the menu has closed.
    private var menuIsOpen = false
    private var floatShowWork: DispatchWorkItem?
    private var floatHideWork: DispatchWorkItem?
    private var escapeMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    init(sidebar: SidebarViewController, editor: EditorViewController) {
        self.sidebar = sidebar
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    override func loadView() {
        let root = FlatView()
        root.fillColor = Theme.editorBackground

        sidebarHost.addChild(sidebar)
        sidebarItem = NSSplitViewItem(viewController: sidebarHost)
        sidebarItem.minimumThickness = minimumSidebarWidth
        // Upper bound is 80% of the window (applied live in onDividerDrag);
        // this static cap is just a sane ceiling before the window exists.
        sidebarItem.maximumThickness = 2000
        // Collapsible so the start page and the toggle can put it away — see
        // `slideSidebar`. Dragging still cannot collapse it: the divider stops
        // at `minimumThickness`.
        sidebarItem.canCollapse = true
        // The panel holds its width; the editor absorbs window resizing. With
        // `.defaultLow` the panel is the pane that yields, so it snapped back to
        // its content minimum and could not be widened. Held below the window's
        // own size, though, like the width below: see there.
        sidebarItem.holdingPriority = Self.belowWindowSize(by: 2)
        let editorItem = NSSplitViewItem(viewController: editor)
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(editorItem)
        addChild(split)
        mountSidebarInHost(width: nil)

        // The panel's width is owned by this constraint, so switching panels can
        // never change it. Dragging the divider updates the constant (below), so
        // the divider still works normally.
        //
        // It gives way to the window's size, though. Held above it (it was at
        // 999) the panel held the window instead: a window could not be made
        // narrower than its panel and the editor's narrowest together, so one
        // opened at 1706pt stopped at 1141pt — tiled to half a laptop's
        // screen, dragged, or moved to a smaller display. Now the panel narrows
        // once the editor is at its narrowest, to the floor, and has its width
        // back as the window widens. No panel's content asks for more than the
        // floor, so switching panels still cannot move it.
        sidebarWidthConstraint = sidebarHost.view.widthAnchor.constraint(
            equalToConstant: lastSidebarWidth)
        sidebarWidthConstraint.priority = Self.belowWindowSize(by: 1)
        sidebarWidthConstraint.isActive = true

        split.onDividerDrag = { [weak self] proposed in
            self?.resizeSidebar(to: proposed)
        }

        let splitView = split.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)
        dividerHandle.translatesAutoresizingMaskIntoConstraints = false
        dividerHandle.onDragBegan = { [weak self] in
            guard let self else { return }
            self.dividerDragStartWidth = self.lastSidebarWidth
        }
        dividerHandle.onDrag = { [weak self] deltaX in
            guard let self else { return }
            self.resizeSidebar(to: self.dividerDragStartWidth + deltaX)
        }
        dividerHandle.onReset = { [weak self] in
            guard let self else { return }
            self.resizeSidebar(to: Self.openingSidebarWidth(forWindowWidth: self.view.bounds.width))
        }
        dividerHandle.dividerThickness = split.splitView.dividerThickness
        root.addSubview(dividerHandle, positioned: .above, relativeTo: splitView)

        // Over the editor, and under the toggle and the traffic lights, which
        // stay where they are while it floats.
        floatView.translatesAutoresizingMaskIntoConstraints = false
        floatView.isHidden = true
        floatView.onHoverChange = { [weak self] inside in self?.floatPointerChanged(inside) }
        root.addSubview(floatView, positioned: .above, relativeTo: dividerHandle)
        floatLeading = floatView.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        floatWidth = floatView.widthAnchor.constraint(equalToConstant: lastSidebarWidth)

        sidebarToggle.target = self
        sidebarToggle.action = #selector(toggleClicked)
        sidebarToggle.onHoverChange = { [weak self] inside in self?.togglePointerChanged(inside) }
        sidebarToggle.describe(sidebarAway: false)
        root.addSubview(sidebarToggle, positioned: .above, relativeTo: floatView)
        // The window controller moves both once AppKit has placed the lights.
        toggleLeading = sidebarToggle.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                                              constant: 78)
        toggleCenterY = sidebarToggle.centerYAnchor.constraint(
            equalTo: root.topAnchor, constant: EditorTabBar.defaultRowHeight / 2)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dividerHandle.centerXAnchor.constraint(equalTo: sidebarHost.view.trailingAnchor),
            dividerHandle.topAnchor.constraint(equalTo: root.topAnchor),
            dividerHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dividerHandle.widthAnchor.constraint(equalToConstant: SplitDividerHandleView.hitWidth),
            floatView.topAnchor.constraint(equalTo: root.topAnchor),
            floatView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            floatLeading,
            floatWidth,
            toggleLeading,
            toggleCenterY,
            sidebarToggle.widthAnchor.constraint(equalToConstant: SidebarToggleButton.size.width),
            sidebarToggle.heightAnchor.constraint(equalToConstant: SidebarToggleButton.size.height),
        ])
        self.view = root

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.menuIsOpen = true
            self?.updateFloat()
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.menuIsOpen = false
            // The menu had the pointer: where it is now is the only news.
            self.pointerOnToggle = self.pointerIsOver(self.sidebarToggle)
            self.pointerOnFloat = self.isFloating && self.pointerIsOver(self.floatView)
            self.updateFloat()
        })
        // Another window or app taking the keys takes the pointer's events
        // with it, so the float would wait for an exit that never comes.
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  window === self.view.window, !self.menuIsOpen else { return }
            self.hideFloat()
        })
    }


    /// Repaint the themed divider after a theme change.
    func refreshAppearance() {
        dividerHandle.dividerThickness = split.splitView.dividerThickness
        dividerHandle.needsDisplay = true
        sidebarToggle.refreshAppearance()
        floatView.refreshAppearance()
    }

    /// Until the window is on screen its width is still being decided — the
    /// default frame, then a restored or requested one — so the panel follows
    /// it. Settling on the very first layout took half of a width the window
    /// was about to leave, and a panel too wide for the window it ended up in
    /// pushed the window wider as soon as the editor needed its room.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !hasSettledOpeningWidth, view.bounds.width > 0 else { return }
        let opening = Self.openingSidebarWidth(forWindowWidth: view.bounds.width)
        guard opening != lastSidebarWidth else { return }
        applyWidth(opening)
    }

    /// On screen: the width it opened at is the width it keeps.
    override func viewDidAppear() {
        super.viewDidAppear()
        if !hasSettledOpeningWidth, view.bounds.width > 0 {
            applyWidth(Self.openingSidebarWidth(forWindowWidth: view.bounds.width))
        }
        hasSettledOpeningWidth = true
    }

    /// Half the window, inside the limits a drag is held to.
    static func openingSidebarWidth(forWindowWidth width: CGFloat) -> CGFloat {
        let half = (width * defaultSidebarFraction).rounded()
        let limit = max(minimumSidebarWidth, (width * 0.8).rounded())
        return min(max(half, minimumSidebarWidth), limit)
    }

    /// Just under the priority a window holds its size at: what the window is
    /// asked to be wins over it.
    static func belowWindowSize(by steps: Float) -> NSLayoutConstraint.Priority {
        NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - steps)
    }

    func resizeSidebarForTesting(to width: CGFloat) { resizeSidebar(to: width) }
    var sidebarWidthForTesting: CGFloat { sidebarWidthConstraint.constant }
    /// The width the panel is laid out at, which a narrow window can hold
    /// under the one it was given.
    var sidebarLaidOutWidthForTesting: CGFloat { sidebarHost.view.frame.width }

    /// Re-assert the remembered width after switching panels.
    func preserveSidebarWidth() { applyWidth(lastSidebarWidth) }

    /// The width to keep. While the panel is away only the number is kept:
    /// the split's width is the slide's, and it comes back at this one.
    private func applyWidth(_ target: CGFloat) {
        lastSidebarWidth = target
        guard !sidebarHidden else { return }
        sidebarWidthConstraint.constant = target
    }

    private func resizeSidebar(to proposedWidth: CGFloat) {
        // A width chosen by hand is not replaced by the opening default.
        hasSettledOpeningWidth = true
        // Never let the panel take more than 80% of the window.
        let limit = max(minimumSidebarWidth, (view.bounds.width * 0.8).rounded())
        let width = min(max(proposedWidth, minimumSidebarWidth), limit)
        sidebarWidthConstraint.constant = width
        lastSidebarWidth = width
    }

    /// A panel was asked for — ⌘1, ⌘2, ⌘3, or the bar at the panel's foot.
    /// Put away, the sidebar comes back; floating, it stays floating, since
    /// the panel asked for is already on show.
    func showSidebar() {
        applyWidth(max(lastSidebarWidth, minimumSidebarWidth))
        if sidebarCollapsed, !isFloating { setSidebarCollapsed(false) }
    }

    // MARK: - Out and away

    /// Put the panel away for the start page, or bring it back.
    ///
    /// With no project open the panel has nothing to show — its three tabs
    /// list a project's files, search it and show its Git — and at half the
    /// window's width that was a large empty rectangle beside a short column
    /// of text. Hidden, the page has the whole window and sits in the middle
    /// of it. The toggle goes with it: there is nothing to bring out.
    func setSidebarHidden(_ hidden: Bool) {
        guard pageHidesSidebar != hidden else { return }
        pageHidesSidebar = hidden
        // A window back to holding nothing starts over: the next project it
        // opens is shown with its sidebar out.
        if hidden {
            sidebarCollapsed = false
            hideFloat(animated: false)
        }
        applyVisibility()
    }

    /// The toggle, and ⌘B.
    func toggleSidebar() { setSidebarCollapsed(!sidebarCollapsed) }

    /// Whether there is a sidebar to put away or bring back: not on the start
    /// page.
    var canToggleSidebar: Bool { !pageHidesSidebar }

    func setSidebarCollapsed(_ collapsed: Bool) {
        guard canToggleSidebar, collapsed != sidebarCollapsed else { return }
        sidebarCollapsed = collapsed
        cancelFloatTimers()
        if !collapsed, isFloating {
            pinFloat()
        } else {
            applyVisibility()
        }
    }

    @objc private func toggleClicked() {
        if !sidebarCollapsed, pointerOnToggle { floatWaitsForPointerToLeave = true }
        toggleSidebar()
    }

    private func applyVisibility() {
        let hidden = pageHidesSidebar || sidebarCollapsed
        sidebarToggle.isHidden = pageHidesSidebar
        sidebarToggle.showsHint = !hidden
        sidebarToggle.describe(sidebarAway: hidden)
        slideSidebar(hidden: hidden)
    }

    /// Slid, by animating the width this controller already owns, rather
    /// than through `sidebarItem.animator().isCollapsed`. That one grows and
    /// shrinks the *window* to keep the editor's width — measured — and a
    /// window that resizes itself when a file is opened is the behaviour a
    /// test here exists to prevent.
    ///
    /// The sidebar keeps its width through the slide and goes out of sight
    /// edge first, instead of being squeezed by the narrowing split — names
    /// truncating letter by letter on the way.
    private func slideSidebar(hidden: Bool) {
        guard sidebarHidden != hidden else {
            // Away for one reason and now the other: only the tabs' start
            // can have moved, with the toggle shown or gone.
            if hidden { editor.setTabLeadingInset(tabInsetWithSidebarAway) }
            return
        }
        sidebarHidden = hidden
        // The handle is drawn over the split view rather than by it, so it has
        // to go as well — otherwise a draggable divider is left at the window's
        // left edge with nothing behind it.
        dividerHandle.isHidden = hidden

        let outWidth = max(lastSidebarWidth, minimumSidebarWidth)
        let laidOut = sidebarHost.view.frame.width
        mountSidebarInHost(width: hidden && laidOut > 0 ? laidOut : outWidth)
        let target = hidden ? 0 : outWidth
        if !hidden {
            // Room to slide back into: the item has to be out of its collapsed
            // state, and at zero width, before the animation starts.
            sidebarItem.isCollapsed = false
            sidebarWidthConstraint.constant = 0
            view.layoutSubtreeIfNeeded()
        }
        // The floor would otherwise refuse every width on the way to zero.
        sidebarItem.minimumThickness = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.sidebarWidthConstraint.constant = target
            self.editor.setTabLeadingInset(hidden ? self.tabInsetWithSidebarAway : 0)
            self.view.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            guard let self, self.sidebarHidden == hidden else { return }
            self.sidebarItem.minimumThickness = self.minimumSidebarWidth
            self.sidebarItem.isCollapsed = hidden
            if !hidden { self.mountSidebarInHost(width: nil) }
        }
    }

    // MARK: - Floating

    private func togglePointerChanged(_ inside: Bool) {
        pointerOnToggle = inside
        if !inside { floatWaitsForPointerToLeave = false }
        updateFloat()
    }

    private func floatPointerChanged(_ inside: Bool) {
        pointerOnFloat = inside
        updateFloat()
    }

    /// The pointer's whereabouts, turned into the float's next move.
    private func updateFloat() {
        if pointerOnToggle, sidebarCollapsed, !isFloating, !floatWaitsForPointerToLeave {
            if floatShowWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.floatShowWork = nil
                    self?.showFloat()
                }
                floatShowWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.floatDelay, execute: work)
            }
        } else if !pointerOnToggle {
            floatShowWork?.cancel()
            floatShowWork = nil
        }

        if isFloating, !pointerOnToggle, !pointerOnFloat, !menuIsOpen {
            scheduleFloatHide()
        } else {
            floatHideWork?.cancel()
            floatHideWork = nil
        }
    }

    private func scheduleFloatHide() {
        guard floatHideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.floatHideWork = nil
            // An exit can be missed — the window was busy, the pointer went
            // fast — so where the pointer is now has the last word. A drag
            // that started inside keeps it out until the button is let go.
            if self.pointerIsOver(self.floatView) || self.pointerIsOver(self.sidebarToggle) {
                return
            }
            if Pointer.pressedButtons != 0 {
                self.scheduleFloatHide()
                return
            }
            self.hideFloat()
        }
        floatHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.floatLeaveDelay, execute: work)
    }

    private func cancelFloatTimers() {
        floatShowWork?.cancel()
        floatShowWork = nil
        floatHideWork?.cancel()
        floatHideWork = nil
    }

    private func pointerIsOver(_ target: NSView) -> Bool {
        guard let window = isViewLoaded ? view.window : nil, !target.isHidden else { return false }
        return target.convert(target.bounds, to: nil).contains(window.pointerLocation)
    }

    /// As wide as the sidebar is when it is out, so nothing in it reflows;
    /// held inside the window as a drag would be.
    private var floatPanelWidth: CGFloat {
        let limit = max(minimumSidebarWidth, (view.bounds.width * 0.8).rounded())
        return min(max(lastSidebarWidth, minimumSidebarWidth), limit)
    }

    private var floatHiddenOffset: CGFloat { -(floatWidth.constant + SidebarFloatView.shadowReach) }

    private func showFloat() {
        guard sidebarCollapsed, sidebarHidden, !pageHidesSidebar, !isFloating,
              view.window != nil else { return }
        isFloating = true
        // Called back on its way out, it turns round where it is.
        if floatView.isHidden {
            floatWidth.constant = floatPanelWidth
            floatLeading.constant = floatHiddenOffset
        }
        moveSidebar { self.floatView.hold(self.sidebar.view) }
        floatView.restoreShadow()
        floatView.isHidden = false
        view.layoutSubtreeIfNeeded()
        installEscapeMonitor()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.floatInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.floatLeading.constant = 0
            self.view.layoutSubtreeIfNeeded()
        }
        updateFloat()
    }

    private func hideFloat(animated: Bool = true) {
        guard isFloating else { return }
        isFloating = false
        pointerOnFloat = false
        cancelFloatTimers()
        removeEscapeMonitor()
        let finish = { [weak self] in
            guard let self, !self.isFloating else { return }
            self.floatView.isHidden = true
            if self.sidebarHidden { self.mountSidebarInHost(width: self.floatWidth.constant) }
        }
        guard animated else {
            floatLeading.constant = floatHiddenOffset
            view.layoutSubtreeIfNeeded()
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.floatOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            self.floatLeading.constant = self.floatHiddenOffset
            self.view.layoutSubtreeIfNeeded()
        }, completionHandler: finish)
    }

    /// The toggle clicked while the sidebar floats: it stays where it is and
    /// becomes the sidebar, and the editor moves out from under it.
    private func pinFloat() {
        isFloating = false
        pointerOnFloat = false
        removeEscapeMonitor()
        sidebarHidden = false
        dividerHandle.isHidden = false
        sidebarToggle.showsHint = true
        sidebarToggle.describe(sidebarAway: false)
        let width = floatWidth.constant
        lastSidebarWidth = width
        sidebarItem.isCollapsed = false
        sidebarWidthConstraint.constant = 0
        view.layoutSubtreeIfNeeded()
        sidebarItem.minimumThickness = 0
        floatView.fadeShadow(over: Self.slideDuration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.sidebarWidthConstraint.constant = width
            self.editor.setTabLeadingInset(0)
            self.view.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            guard let self, !self.sidebarHidden, !self.isFloating else { return }
            self.sidebarItem.minimumThickness = self.minimumSidebarWidth
            self.mountSidebarInHost(width: nil)
            self.floatView.isHidden = true
        }
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.view.window, event.keyCode == 53,
                  self.dismissFloat() else { return event }
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    /// Esc while the sidebar floats sends it away; false when there was
    /// nothing to send.
    private func dismissFloat() -> Bool {
        guard isFloating else { return false }
        hideFloat()
        return true
    }

    // MARK: - Where the sidebar's view sits

    /// Into the host: filling it (`width` nil), or at `width` against its
    /// right edge, to slide or to wait out of sight.
    private func mountSidebarInHost(width: CGFloat?) {
        let content = sidebar.view
        let host = sidebarHost.view
        if content.superview !== host {
            moveSidebar {
                content.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(content)
                NSLayoutConstraint.activate([
                    content.topAnchor.constraint(equalTo: host.topAnchor),
                    content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                ])
                self.contentLeading = content.leadingAnchor.constraint(equalTo: host.leadingAnchor)
                self.contentWidth = content.widthAnchor.constraint(equalToConstant: 0)
            }
        }
        if let width {
            contentLeading?.isActive = false
            contentWidth?.constant = width
            contentWidth?.isActive = true
        } else {
            contentWidth?.isActive = false
            contentLeading?.isActive = true
        }
    }

    /// Moving a view between superviews takes the keys from whatever in it
    /// had them, so they are handed back afterwards.
    private func moveSidebar(_ move: () -> Void) {
        let window = isViewLoaded ? view.window : nil
        let focused = (window?.firstResponder as? NSView).flatMap {
            $0.isDescendant(of: sidebar.view) ? $0 : nil
        }
        move()
        if let focused, focused.window === window { window?.makeFirstResponder(focused) }
    }

    // MARK: - Geometry from the window

    /// The toggle stands here, just past the traffic lights (or in their
    /// place in full screen), and the project's name after it.
    func setTitlebarLeadingInset(_ inset: CGFloat) {
        toggleLeading.constant = inset
        sidebar.setTitlebarLeadingInset(inset + SidebarToggleButton.size.width
                                        + SidebarToggleButton.trailingGap)
        if sidebarHidden { editor.setTabLeadingInset(tabInsetWithSidebarAway) }
    }

    func setTabRowHeight(_ height: CGFloat) {
        toggleCenterY.constant = height / 2
    }

    /// With the sidebar away, the first tab starts after the toggle — or
    /// after the traffic lights, on the start page where there is no toggle.
    private var tabInsetWithSidebarAway: CGFloat {
        guard !sidebarToggle.isHidden else { return toggleLeading.constant }
        return toggleLeading.constant + SidebarToggleButton.size.width
            + SidebarToggleButton.trailingGap
    }

    // MARK: - Regression-test surface

    var sidebarIsHiddenForTesting: Bool { sidebarHidden }
    var floatViewForTesting: NSView { floatView }
    var sidebarHostForTesting: NSView { sidebarHost.view }
    /// The pointer arriving at or leaving the toggle or the float, as their
    /// tracking areas report it.
    func setPointerOnToggleForTesting(_ inside: Bool) { sidebarToggle.setHoveredForTesting(inside) }
    func setPointerOnFloatForTesting(_ inside: Bool) { floatPointerChanged(inside) }
    func pressEscapeForTesting() -> Bool { dismissFloat() }
    func toggleClickForTesting() { toggleClicked() }
}

/// The split's sidebar item: a clipping box the sidebar's own view slides in
/// and out of.
private final class SidebarHostViewController: NSViewController {
    override func loadView() {
        let host = FlatView()
        host.fillColor = Theme.panelBackground
        if #available(macOS 14, *) { host.clipsToBounds = true }
        view = host
    }
}
