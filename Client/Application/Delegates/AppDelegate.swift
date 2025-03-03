/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared
import Storage
import AVFoundation
import XCGLogger
import MessageUI
import SDWebImage
import SwiftKeychainWrapper
import LocalAuthentication
import CoreSpotlight
import UserNotifications
import BraveShared
import Data
import StoreKit
import BraveCore
import Combine

private let log = Logger.browserLogger

let LatestAppVersionProfileKey = "latestAppVersion"
private let InitialPingSentKey = "initialPingSent"

class AppDelegate: UIResponder, UIApplicationDelegate, UIViewControllerRestoration {
    public static func viewController(withRestorationIdentifierPath identifierComponents: [String], coder: NSCoder) -> UIViewController? {
        return nil
    }

    var window: UIWindow?
    var browserViewController: BrowserViewController!
    var rootViewController: UIViewController!
    weak var profile: Profile?
    var tabManager: TabManager!
    var braveCore: BraveCoreMain?

    weak var application: UIApplication?
    var launchOptions: [AnyHashable: Any]?

    let appVersion = Bundle.main.infoDictionaryString(forKey: "CFBundleShortVersionString")

    var receivedURLs: [URL]?
    
    var windowProtection: WindowProtection?
    var shutdownWebServer: DispatchSourceTimer?
    
    /// Object used to handle server pings
    let dau = DAU()
    
    /// Must be added at launch according to Apple's documentation.
    let iapObserver = IAPObserver()
    
    /// A car-play manager instance that will handle when car-play status changes
    var carPlayManager: PlaylistCarplayManager?

    @discardableResult func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Hold references to willFinishLaunching parameters for delayed app launch
        self.application = application
        self.launchOptions = launchOptions
        self.window = UIWindow(frame: UIScreen.main.bounds)
        self.window!.backgroundColor = .black
        
        // Brave Core Initialization
        BraveCoreMain.setLogHandler { severity, file, line, messageStartIndex, message in
            if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let level: XCGLogger.Level = {
                    switch -severity {
                    case 0: return .error
                    case 1: return .info
                    case 2..<7: return .debug
                    default: return .verbose
                    }
                }()
                Logger.braveCoreLogger.logln(
                    level,
                    fileName: file,
                    lineNumber: Int(line),
                    // Only print the actual message content, and drop the final character which is
                    // a new line as it will be handled by logln
                    closure: { message.dropFirst(messageStartIndex).dropLast() }
                )
            }
            return true
        }
        
        self.braveCore = BraveCoreMain()
        self.braveCore?.setUserAgent(UserAgent.mobile)
        
        SceneObserver.setupApplication(window: self.window!)

        AdBlockStats.shared.startLoading()
        HttpsEverywhereStats.shared.startLoading()
        
        updateShortcutItems(application)
        
        // Must happen before passcode check, otherwise may unnecessarily reset keychain
        Migration.moveDatabaseToApplicationDirectory()
        
        // Passcode checking, must happen on immediate launch
        if !DataController.shared.storeExists() {
            // Since passcode is stored in keychain it persists between installations.
            //  If there is no database (either fresh install, or deleted in file system), there is no real reason
            //  to passcode the browser (no data to protect).
            // Main concern is user installs Brave after a long period of time, cannot recall passcode, and can
            //  literally never use Brave. This bypasses this situation, while not using a modifiable pref.
            KeychainWrapper.sharedAppContainerKeychain.setAuthenticationInfo(nil)
        }
        
        // We have to wait until pre1.12 migration is done until we proceed with database
        // initialization. This is because Database container may change. See bugs #3416, #3377.
        DataController.shared.initialize()
        
        return startApplication(application, withLaunchOptions: launchOptions)
    }

    @discardableResult fileprivate func startApplication(_ application: UIApplication, withLaunchOptions launchOptions: [AnyHashable: Any]?) -> Bool {
        log.info("startApplication begin")
        
        // Set the Safari UA for browsing.
        setUserAgent()

        // Start the keyboard helper to monitor and cache keyboard state.
        KeyboardHelper.defaultHelper.startObserving()
        DynamicFontHelper.defaultHelper.startObserving()

        MenuHelper.defaultHelper.setItems()
        
        SDImageCodersManager.shared.addCoder(PrivateCDNImageCoder())

        let logDate = Date()
        // Create a new sync log file on cold app launch. Note that this doesn't roll old logs.
        Logger.syncLogger.newLogWithDate(logDate)
        Logger.browserLogger.newLogWithDate(logDate)

        let profile = getProfile(application)
        let profilePrefix = profile.prefs.getBranchPrefix()
        Migration.launchMigrations(keyPrefix: profilePrefix)
        
        setUpWebServer(profile)
        
        var imageStore: DiskImageStore?
        do {
            imageStore = try DiskImageStore(files: profile.files, namespace: "TabManagerScreenshots", quality: UIConstants.screenshotQuality)
        } catch {
            log.error("Failed to create an image store for files: \(profile.files) and namespace: \"TabManagerScreenshots\": \(error.localizedDescription)")
            assertionFailure()
        }
        
        // Temporary fix for Bug 1390871 - NSInvalidArgumentException: -[WKContentView menuHelperFindInPage]: unrecognized selector
        if let clazz = NSClassFromString("WKCont" + "ent" + "View"), let swizzledMethod = class_getInstanceMethod(TabWebViewMenuHelper.self, #selector(TabWebViewMenuHelper.swizzledMenuHelperFindInPage)) {
            class_addMethod(clazz, MenuHelper.selectorFindInPage, method_getImplementation(swizzledMethod), method_getTypeEncoding(swizzledMethod))
        }
        
        #if !NO_BRAVE_NEWS
        if Preferences.BraveNews.isEnabled.value && !Preferences.BraveNews.userOptedIn.value {
            // Opt-out any user that has not explicitly opted-in
            Preferences.BraveNews.isEnabled.value = false
            // User now has to explicitly opt-in
            Preferences.BraveNews.isShowingOptIn.value = true
        }
        
        if !Preferences.BraveNews.languageChecked.value,
           let languageCode = Locale.preferredLanguages.first?.prefix(2) {
            Preferences.BraveNews.languageChecked.value = true
            // Base opt-in visibility on whether or not the user's language is supported in BT
            Preferences.BraveNews.isShowingOptIn.value = FeedDataSource.supportedLanguages.contains(String(languageCode))
        }
        #endif

        self.tabManager = TabManager(prefs: profile.prefs, imageStore: imageStore)

        // Make sure current private browsing flag respects the private browsing only user preference
        PrivateBrowsingManager.shared.isPrivateBrowsing = Preferences.Privacy.privateBrowsingOnly.value
        
        // Don't track crashes if we're building the development environment due to the fact that terminating/stopping
        // the simulator via Xcode will count as a "crash" and lead to restore popups in the subsequent launch
        let crashedLastSession = !Preferences.AppState.backgroundedCleanly.value && AppConstants.buildChannel != .debug
        Preferences.AppState.backgroundedCleanly.value = false
        browserViewController = BrowserViewController(profile: self.profile!, tabManager: self.tabManager, crashedLastSession: crashedLastSession)
        browserViewController.edgesForExtendedLayout = []

        // Add restoration class, the factory that will return the ViewController we will restore with.
        browserViewController.restorationIdentifier = NSStringFromClass(BrowserViewController.self)
        browserViewController.restorationClass = AppDelegate.self

        let navigationController = UINavigationController(rootViewController: browserViewController)
        navigationController.delegate = self
        navigationController.isNavigationBarHidden = true
        navigationController.edgesForExtendedLayout = UIRectEdge(rawValue: 0)
        rootViewController = navigationController

        self.window!.rootViewController = rootViewController

        windowProtection = WindowProtection(window: window!)
        SystemUtils.onFirstRun()
        
        // Schedule Brave Core Priority Tasks
        self.braveCore?.scheduleLowPriorityStartupTasks()
        browserViewController.removeScheduledAdGrantReminders()

        log.info("startApplication end")
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // We have only five seconds here, so let's hope this doesn't take too long.
        self.profile?.shutdown()

        // Allow deinitializers to close our database connections.
        self.profile = nil
        self.tabManager = nil
        self.browserViewController = nil
        self.rootViewController = nil
        SKPaymentQueue.default().remove(iapObserver)
        
        // Clean up BraveCore
        BraveSyncAPI.removeAllObservers()
        self.braveCore = nil
    }

    /**
     * We maintain a weak reference to the profile so that we can pause timed
     * syncs when we're backgrounded.
     *
     * The long-lasting ref to the profile lives in BrowserViewController,
     * which we set in application:willFinishLaunchingWithOptions:.
     *
     * If that ever disappears, we won't be able to grab the profile to stop
     * syncing... but in that case the profile's deinit will take care of things.
     */
    func getProfile(_ application: UIApplication) -> Profile {
        if let profile = self.profile {
            return profile
        }
        let p = BrowserProfile(localName: "profile")
        self.profile = p
        return p
    }
    
    func updateShortcutItems(_ application: UIApplication) {
        let newTabItem = UIMutableApplicationShortcutItem(type: "\(Bundle.main.bundleIdentifier ?? "").NewTab",
            localizedTitle: Strings.quickActionNewTab,
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(templateImageName: "quick_action_new_tab"),
            userInfo: [:])
        
        let privateTabItem = UIMutableApplicationShortcutItem(type: "\(Bundle.main.bundleIdentifier ?? "").NewPrivateTab",
            localizedTitle: Strings.quickActionNewPrivateTab,
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(templateImageName: "quick_action_new_private_tab"),
            userInfo: [:])
        
        let scanQRCodeItem = UIMutableApplicationShortcutItem(type: "\(Bundle.main.bundleIdentifier ?? "").ScanQRCode",
            localizedTitle: Strings.scanQRCodeViewTitle,
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(templateImageName: "recent-search-qrcode"),
            userInfo: [:])

        application.shortcutItems = Preferences.Privacy.privateBrowsingOnly.value ? [privateTabItem, scanQRCodeItem] : [newTabItem, privateTabItem, scanQRCodeItem]
    }
    
    private var cancellables: Set<AnyCancellable> = []
    
    private var expectedThemeOverride: UIUserInterfaceStyle {
        let themeOverride = DefaultTheme(
            rawValue: Preferences.General.themeNormalMode.value
        )?.userInterfaceStyleOverride ?? .unspecified
        let isPrivateBrowsing = PrivateBrowsingManager.shared.isPrivateBrowsing
        return isPrivateBrowsing ? .dark : themeOverride
    }
    
    private func updateTheme() {
        guard let window = window else { return }
        UIView.transition(with: window, duration: 0.15, options: [.transitionCrossDissolve], animations: {
            window.overrideUserInterfaceStyle = self.expectedThemeOverride
        }, completion: nil)
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // IAPs can trigger on the app as soon as it launches,
        // for example when a previous transaction was not finished and is in pending state.
        SKPaymentQueue.default().add(iapObserver)
        
        // Override point for customization after application launch.
        var shouldPerformAdditionalDelegateHandling = true
        
        AdblockRustEngine.setDomainResolver { urlCString, start, end in
            guard let urlCString = urlCString else { return }
            let urlString = String(cString: urlCString)
            let parsableURLString: String = {
                // Apple's URL implementation requires a URL be prefixed with a scheme to be
                // parsed properly (otherwise URL(string: X) will resolve to placing the entire
                // contents of X into the `path` property
                if urlString.asURL?.scheme == nil {
                    return "http://\(urlString)"
                }
                return urlString
            }()
            guard let url = URL(string: parsableURLString),
                  let baseDomain = url.baseDomain,
                  let range = urlString.range(of: baseDomain) else {
                log.error("Failed to resolve domain ")
                return
            }
            let startIndex: Int = urlString.distance(from: urlString.startIndex, to: range.lowerBound)
            let endIndex: Int = urlString.distance(from: urlString.startIndex, to: range.upperBound)
            start?.pointee = UInt32(startIndex)
            end?.pointee = UInt32(endIndex)
        }
        
        UIScrollView.doBadSwizzleStuff()
        applyAppearanceDefaults()
        
        Preferences.General.themeNormalMode.objectWillChange
            .merge(with: PrivateBrowsingManager.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateTheme()
            }
            .store(in: &cancellables)
        
        window?.overrideUserInterfaceStyle = expectedThemeOverride
        window?.tintColor = UIColor {
            if $0.userInterfaceStyle == .dark {
                return .braveLighterBlurple
            }
            return .braveBlurple
        }
        window?.makeKeyAndVisible()

        if Preferences.Rewards.isUsingBAP.value == nil {
            Preferences.Rewards.isUsingBAP.value = Locale.current.regionCode == "JP"
        }
        
        // Now roll logs.
        DispatchQueue.global(qos: DispatchQoS.background.qosClass).async {
            Logger.syncLogger.deleteOldLogsDownToSizeLimit()
            Logger.browserLogger.deleteOldLogsDownToSizeLimit()
        }

        // If a shortcut was launched, display its information and take the appropriate action
        if let shortcutItem = launchOptions?[UIApplication.LaunchOptionsKey.shortcutItem] as? UIApplicationShortcutItem {

            QuickActions.sharedInstance.launchedShortcutItem = shortcutItem
            // This will block "performActionForShortcutItem:completionHandler" from being called.
            shouldPerformAdditionalDelegateHandling = false
        }

        // Force the ToolbarTextField in LTR mode - without this change the UITextField's clear
        // button will be in the incorrect position and overlap with the input text. Not clear if
        // that is an iOS bug or not.
        AutocompleteTextField.appearance().semanticContentAttribute = .forceLeftToRight
        
        let isFirstLaunch = Preferences.General.isFirstLaunch.value
        if Preferences.General.basicOnboardingCompleted.value == OnboardingState.undetermined.rawValue {
            Preferences.General.basicOnboardingCompleted.value =
                isFirstLaunch ? OnboardingState.unseen.rawValue : OnboardingState.completed.rawValue
        }
        Preferences.General.isFirstLaunch.value = false
        Preferences.Review.launchCount.value += 1
        
        if !Preferences.VPN.popupShowed.value {
            Preferences.VPN.appLaunchCountForVPNPopup.value += 1
        }
        
        browserViewController.shouldShowIntroScreen =
            DefaultBrowserIntroManager.prepareAndShowIfNeeded(isNewUser: isFirstLaunch)
        
        // Search engine setup must be checked outside of 'firstLaunch' loop because of #2770.
        // There was a bug that when you skipped onboarding, default search engine preference
        // was not set.
        if Preferences.Search.defaultEngineName.value == nil {
            profile?.searchEngines.searchEngineSetup()
        }
        
        // Migration of Yahoo Search Engines
        if !Preferences.Search.yahooEngineMigrationCompleted.value {
            profile?.searchEngines.migrateDefaultYahooSearchEngines()
        }
        
        if isFirstLaunch {
            Preferences.DAU.installationDate.value = Date()
            
            // VPN credentials are kept in keychain and persist between app reinstalls.
            // To avoid unexpected problems we clear all vpn keychain items.
            // New set of keychain items will be created on purchase or iap restoration.
            BraveVPN.clearCredentials()
        }
        
        if let urp = UserReferralProgram.shared {
            if Preferences.URP.referralLookupOutstanding.value == nil {
                // This preference has never been set, and this means it is a new or upgraded user.
                // That distinction must be made to know if a network request for ref-code look up should be made.
                
                // Setting this to an explicit value so it will never get overwritten on subsequent launches.
                // Upgrade users should not have ref code ping happening.
                Preferences.URP.referralLookupOutstanding.value = isFirstLaunch
            }
            
            handleReferralLookup(urp, checkClipboard: false)
        } else {
            log.error("Failed to initialize user referral program")
            UrpLog.log("Failed to initialize user referral program")
        }
        
        AdblockResourceDownloader.shared.startLoading()
        PlaylistManager.shared.restoreSession()
        carPlayManager = PlaylistCarplayManager.shared.then {
            $0.browserController = browserViewController
        }
      
        return shouldPerformAdditionalDelegateHandling
    }
    
    func handleReferralLookup(_ urp: UserReferralProgram, checkClipboard: Bool) {
        let initialOnboarding =
            Preferences.General.basicOnboardingProgress.value == OnboardingProgress.none.rawValue
        
        // FIXME: Update to iOS14 clipboard api once ready (#2838)
        if initialOnboarding && UIPasteboard.general.hasStrings {
            log.debug("Skipping URP call at app launch, this is handled in privacy consent onboarding screen")
            return
        }
        
        if Preferences.URP.referralLookupOutstanding.value == true {
            var refCode: String?
            
            if Preferences.URP.referralCode.value == nil {
                UrpLog.log("No ref code exists on launch, attempting clipboard retrieval")
                let savedRefCode = checkClipboard ? UIPasteboard.general.string : nil
                refCode = UserReferralProgram.sanitize(input: savedRefCode)
                
                if refCode != nil {
                    UrpLog.log("Clipboard ref code found: " + (savedRefCode ?? "!Clipboard Empty!"))
                    UrpLog.log("Clearing clipboard.")
                    UIPasteboard.general.clearPasteboard()
                }
            }
            
            urp.referralLookup(refCode: refCode) { referralCode, offerUrl in
                // Attempting to send ping after first urp lookup.
                // This way we can grab the referral code if it exists, see issue #2586.
                self.dau.sendPingToServer()
                if let code = referralCode {
                    let retryTime = AppConstants.buildChannel.isPublic ? 1.days : 10.minutes
                    let retryDeadline = Date() + retryTime
                    
                    Preferences.NewTabPage.superReferrerThemeRetryDeadline.value = retryDeadline
                    
                    self.browserViewController.backgroundDataSource
                        .fetchSpecificResource(.superReferral(code: code))
                } else {
                    self.browserViewController.backgroundDataSource.startFetching()
                }
                
                guard let url = offerUrl?.asURL else { return }
                self.browserViewController.openReferralLink(url: url)
            }
        } else {
            urp.pingIfEnoughTimePassed()
            browserViewController.backgroundDataSource.startFetching()
        }
    }

    func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard let routerpath = NavigationPath(url: url) else {
            return false
        }
        self.browserViewController.handleNavigationPath(path: routerpath)
        return true
    }
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if let presentedViewController = rootViewController.presentedViewController {
            return presentedViewController.supportedInterfaceOrientations
        } else {
            return rootViewController.supportedInterfaceOrientations
        }
    }

    // We sync in the foreground only, to avoid the possibility of runaway resource usage.
    // Eventually we'll sync in response to notifications.
    func applicationDidBecomeActive(_ application: UIApplication) {
        shutdownWebServer?.cancel()
        shutdownWebServer = nil
        
        Preferences.AppState.backgroundedCleanly.value = false

        if let profile = self.profile {
            profile.reopen()
            setUpWebServer(profile)
        }
        
        self.receivedURLs = nil
        application.applicationIconBadgeNumber = 0

        // handle quick actions is available
        let quickActions = QuickActions.sharedInstance
        if let shortcut = quickActions.launchedShortcutItem {
            // dispatch asynchronously so that BVC is all set up for handling new tabs
            // when we try and open them
            quickActions.handleShortCutItem(shortcut, withBrowserViewController: browserViewController)
            quickActions.launchedShortcutItem = nil
        }
        
        // We try to send DAU ping each time the app goes to foreground to work around network edge cases
        // (offline, bad connection etc.).
        // Also send the ping only after the URP lookup has processed.
        if Preferences.URP.referralLookupOutstanding.value == false {
            dau.sendPingToServer()
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        syncOnDidEnterBackground(application: application)
        BraveVPN.sendVPNWorksInBackgroundNotification()
    }

    fileprivate func syncOnDidEnterBackground(application: UIApplication) {
        guard let profile = self.profile else {
            return
        }
      
        // BRAVE TODO: Decide whether or not we want to use this for our own sync down the road

        var taskId: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 0)
        taskId = application.beginBackgroundTask {
            print("Running out of background time, but we have a profile shutdown pending.")
            self.shutdownProfileWhenNotActive(application)
            application.endBackgroundTask(taskId)
        }

        profile.shutdown()
        application.endBackgroundTask(taskId)
        
        let singleShotTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        // 2 seconds is ample for a localhost request to be completed by GCDWebServer. <500ms is expected on newer devices.
        singleShotTimer.schedule(deadline: .now() + 2.0, repeating: .never)
        singleShotTimer.setEventHandler {
            WebServer.sharedInstance.server.stop()
            self.shutdownWebServer = nil
        }
        singleShotTimer.resume()
        shutdownWebServer = singleShotTimer
    }

    fileprivate func shutdownProfileWhenNotActive(_ application: UIApplication) {
        // Only shutdown the profile if we are not in the foreground
        guard application.applicationState != .active else {
            return
        }

        profile?.shutdown()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // The reason we need to call this method here instead of `applicationDidBecomeActive`
        // is that this method is only invoked whenever the application is entering the foreground where as
        // `applicationDidBecomeActive` will get called whenever the Touch ID authentication overlay disappears.
        AdblockResourceDownloader.shared.startLoading()
        
        browserViewController.showWalletTransferExpiryPanelIfNeeded()
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        Preferences.AppState.backgroundedCleanly.value = true
    }

    fileprivate func setUpWebServer(_ profile: Profile) {
        let server = WebServer.sharedInstance
        if server.server.isRunning { return }
        
        ReaderModeHandlers.register(server, profile: profile)
        ErrorPageHelper.register(server, certStore: profile.certStore)
        SafeBrowsingHandler.register(server)
        AboutHomeHandler.register(server)
        AboutLicenseHandler.register(server)
        SessionRestoreHandler.register(server)
        BookmarksInterstitialPageHandler.register(server)

        // Bug 1223009 was an issue whereby CGDWebserver crashed when moving to a background task
        // catching and handling the error seemed to fix things, but we're not sure why.
        // Either way, not implicitly unwrapping a try is not a great way of doing things
        // so this is better anyway.
        do {
            try server.start()
        } catch let err as NSError {
            print("Error: Unable to start WebServer \(err)")
        }
    }

    fileprivate func setUserAgent() {
        let userAgent = UserAgent.userAgentForDesktopMode

        // Set the favicon fetcher, and the image loader.
        // This only needs to be done once per runtime. Note that we use defaults here that are
        // readable from extensions, so they can just use the cached identifier.

        SDWebImageDownloader.shared.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        WebcompatReporter.userAgent = userAgent
        
        // Record the user agent for use by search suggestion clients.
        SearchViewController.userAgent = userAgent

        // Some sites will only serve HTML that points to .ico files.
        // The FaviconFetcher is explicitly for getting high-res icons, so use the desktop user agent.
        FaviconFetcher.htmlParsingUserAgent = UserAgent.desktop
    }

    fileprivate func presentEmailComposerWithLogs() {
        if let buildNumber = Bundle.main.object(forInfoDictionaryKey: String(kCFBundleVersionKey)) as? NSString {
            let mailComposeViewController = MFMailComposeViewController()
            mailComposeViewController.mailComposeDelegate = self
            mailComposeViewController.setSubject("Debug Info for iOS client version v\(appVersion) (\(buildNumber))")

            self.window?.rootViewController?.present(mailComposeViewController, animated: true, completion: nil)
        }
    }
}

// MARK: - NSUserActivity

extension AppDelegate {
    
    func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        if let url = userActivity.webpageURL {
            switch UniversalLinkManager.universalLinkType(for: url, checkPath: false) {
            case .buyVPN:
                browserViewController.presentCorrespondingVPNViewController()
                return true
            case .none:
                break
            }

            browserViewController.switchToTabForURLOrOpen(url, isPrivileged: true)
            return true
        }

        switch userActivity.activityType {
            case CSSearchableItemActionType:
                // Otherwise, check if the `NSUserActivity` is a CoreSpotlight item and switch to its tab or
                // open a new one.
                if let userInfo = userActivity.userInfo,
                    let urlString = userInfo[CSSearchableItemActivityIdentifier] as? String,
                    let url = URL(string: urlString) {
                    browserViewController.switchToTabForURLOrOpen(url, isPrivileged: false)
                    return true
                }
            case ActivityType.newTab.identifier:
                ActivityShortcutManager.shared.performShortcutActivity(
                    type: .newTab, using: browserViewController)
                
                return true
            case ActivityType.newPrivateTab.identifier:
                ActivityShortcutManager.shared.performShortcutActivity(
                    type: .newPrivateTab, using: browserViewController)
                
                return true
            case ActivityType.clearBrowsingHistory.identifier:
                ActivityShortcutManager.shared.performShortcutActivity(
                    type: .clearBrowsingHistory, using: browserViewController)
                
                return true
            case ActivityType.enableBraveVPN.identifier:
                ActivityShortcutManager.shared.performShortcutActivity(
                    type: .enableBraveVPN, using: browserViewController)
                
                return true
            case ActivityType.openBraveNews.identifier:
                ActivityShortcutManager.shared.performShortcutActivity(
                    type: .openBraveNews, using: browserViewController)
                
                return true
            case ActivityType.openPlayList.identifier:
                ActivityShortcutManager.shared.performShortcutActivity(
                    type: .openPlayList, using: browserViewController)
                
                return true
            default:
                break
        }
        
        func switchToTabForIntentURL(intentURL: String?) -> Bool {
            guard let siteURL = intentURL, let url = URL(string: siteURL) else {
                return false
            }

            browserViewController.switchToTabForURLOrOpen(
                url,
                isPrivate: Preferences.Privacy.privateBrowsingOnly.value,
                isPrivileged: false)
            return true
        }
        
        if let intent = userActivity.interaction?.intent as? OpenWebsiteIntent {
            return switchToTabForIntentURL(intentURL: intent.websiteURL)
        }
        
        if let intent = userActivity.interaction?.intent as? OpenHistoryWebsiteIntent {
            return switchToTabForIntentURL(intentURL: intent.websiteURL)
        }
        
        if let intent = userActivity.interaction?.intent as? OpenBookmarkWebsiteIntent {
            return switchToTabForIntentURL(intentURL: intent.websiteURL)
        }
        
        return false
    }
    
    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        let handledShortCutItem = QuickActions.sharedInstance.handleShortCutItem(shortcutItem, withBrowserViewController: browserViewController)

        completionHandler(handledShortCutItem)
    }
}

// MARK: - Root View Controller Animations
extension AppDelegate: UINavigationControllerDelegate {
    func navigationController(_ navigationController: UINavigationController, animationControllerFor operation: UINavigationController.Operation, from fromVC: UIViewController, to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        switch operation {
        case .push:
            return BrowserToTrayAnimator()
        case .pop:
            return TrayToBrowserAnimator()
        default:
            return nil
        }
    }
}

extension AppDelegate: MFMailComposeViewControllerDelegate {
    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        // Dismiss the view controller and start the app up
        controller.dismiss(animated: true, completion: nil)
        startApplication(application!, withLaunchOptions: self.launchOptions)
    }
}
