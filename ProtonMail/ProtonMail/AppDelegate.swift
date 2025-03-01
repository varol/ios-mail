//
//  AppDelegate.swift
//  ProtonMail
//
//
//  Copyright (c) 2019 Proton Technologies AG
//
//  This file is part of ProtonMail.
//
//  ProtonMail is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonMail is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonMail.  If not, see <https://www.gnu.org/licenses/>.


import UIKit
import SWRevealViewController
import AFNetworking
import AFNetworkActivityLogger
import Keymaker
import UserNotifications
import Intents

#if Enterprise
import Fabric
import Crashlytics
#endif

let sharedUserDataService = UserDataService()

/// tempeary here.
let sharedServices: ServiceFactory = {
    let helper = ServiceFactory()
    ///
    helper.add(AppCacheService.self, for: AppCacheService())
    helper.add(AddressBookService.self, for: AddressBookService())
    ///
    let addrService: AddressBookService = helper.get()
    helper.add(ContactDataService.self, for: ContactDataService(addressBookService: addrService))
    helper.add(BugDataService.self, for: BugDataService())
    
    ///
    let msgService: MessageDataService = MessageDataService()
    helper.add(MessageDataService.self, for: msgService)
    
    helper.add(PushNotificationService.self, for: PushNotificationService(service: helper.get()))
    helper.add(ViewModelService.self, for: ViewModelServiceImpl())
    
    helper.add(SpringboardShortcutsService.self, for: SpringboardShortcutsService())
    
    return helper
}()

@UIApplicationMain
class AppDelegate: UIResponder {
    var window: UIWindow? { // this property is important for State Restoration of modally presented viewControllers
        return self.coordinator.currentWindow
    }
    lazy var coordinator: WindowsCoordinator = WindowsCoordinator()
}

// MARK: - this is workaround to track when the SWRevealViewController first time load
extension SWRevealViewController {
    open override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if (segue.identifier == "sw_rear") {
            if let menuViewController =  segue.destination as? MenuViewController {
                let viewModel = MenuViewModelImpl()
                let menu = MenuCoordinatorNew(vc: menuViewController, vm: viewModel, services: sharedServices)
                menu.start()
            }
        } else if (segue.identifier == "sw_front") {
            if let navigation = segue.destination as? UINavigationController {
                if let mailboxViewController: MailboxViewController = navigation.firstViewController() as? MailboxViewController {
                    ///TODO::fixme AppDelegate.coordinator.serviceHolder is bad
                    sharedVMService.mailbox(fromMenu: mailboxViewController)
                    let viewModel = MailboxViewModelImpl(label: .inbox, service: sharedServices.get(), pushService: sharedServices.get())
                    let mailbox = MailboxCoordinator(vc: mailboxViewController, vm: viewModel, services: sharedServices)
                    mailbox.start()                    
                }
            }
        }
    }
}

// MARK: - consider move this to coordinator
extension AppDelegate: APIServiceDelegate, UserDataServiceDelegate {
    func onLogout(animated: Bool) {
        if #available(iOS 13.0, *) {
            let sessions = Array(UIApplication.shared.openSessions)
            let oneToStay = sessions.first(where: { $0.scene?.delegate as? WindowSceneDelegate != nil })
            (oneToStay?.scene?.delegate as? WindowSceneDelegate)?.coordinator.go(dest: .signInWindow)
            
            for session in sessions where session != oneToStay {
                UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { error in
                    PMLog.D(error.localizedDescription)
                }
            }
        } else {
            self.coordinator.go(dest: .signInWindow)
        }
    }
    
    func isReachable() -> Bool {
        return sharedInternetReachability.currentReachabilityStatus() != NetworkStatus.NotReachable
    }
    
    func onError(error: NSError) {
        error.alertToast()
    }
}

extension AppDelegate: TrustKitUIDelegate {
    func onTrustKitValidationError(_ alert: UIAlertController) {
        let currentWindow: UIWindow? = {
            if #available(iOS 13.0, *) {
                let session = UIApplication.shared.openSessions.first { $0.scene?.activationState == UIScene.ActivationState.foregroundActive }
                let scene = session?.scene as? UIWindowScene
                let window = scene?.windows.first
                return window
            } else {
                return self.window
            }
        }()
        
        guard let top = currentWindow?.topmostViewController(), !(top is UIAlertController) else { return }
        top.present(alert, animated: true, completion: nil)
    }
}

//move to a manager class later
let sharedInternetReachability : Reachability = Reachability.forInternetConnection()
//let sharedRemoteReachability : Reachability = Reachability(hostName: AppConstants.API_HOST_URL)

// MARK: - UIApplicationDelegate
extension AppDelegate: UIApplicationDelegate {
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        if UIDevice.current.stateRestorationPolicy == .coders {
            // by the end of this method we need UIWindow with root view controller in order to restore modally presented view controller correctly
            self.coordinator.prepare()
        }
        return true
    }
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #if DEBUG
        PMLog.D("App group directory: " + FileManager.default.appGroupsDirectoryURL.absoluteString)
        PMLog.D("App directory: " + FileManager.default.applicationSupportDirectoryURL.absoluteString)
        PMLog.D("Tmp directory: " + FileManager.default.temporaryDirectoryUrl.absoluteString)
        #endif
        
        let cacheService : AppCacheService = sharedServices.get()
        cacheService.restoreCacheWhenAppStart()
        
        #if Enterprise
        Fabric.with([Crashlytics.self])
        #endif
        TrustKitWrapper.start(delegate: self)
        Analytics.shared.setup()
        
        UIApplication.shared.setMinimumBackgroundFetchInterval(300)
        
        ///TODO::fixme refactor
        shareViewModelFactoy = ViewModelFactoryProduction()
        sharedVMService.cleanLegacy()
        sharedAPIService.delegate = self
        
        AFNetworkActivityIndicatorManager.shared().isEnabled = true
        
        //get build mode if debug mode enable network logging
        let mode = UIApplication.shared.releaseMode()
        //network debug options
        if let logger = AFNetworkActivityLogger.shared().loggers.first as? AFNetworkActivityConsoleLogger {
            logger.level = .AFLoggerLevelDebug;
        }
        AFNetworkActivityLogger.shared().startLogging()
        
        //start network notifier
        sharedInternetReachability.startNotifier()
        
        sharedMessageDataService.launchCleanUpIfNeeded()
        sharedUserDataService.delegate = self
        
        if mode != .dev && mode != .sim {
            AFNetworkActivityLogger.shared().stopLogging()
        }
        AFNetworkActivityLogger.shared().stopLogging()
        
        // setup language: iOS 13 allows setting language per-app in Settings.app, so we trust that value
        // we still use LanguageManager because Bundle.main of Share extension will take the value from host application :(
        if #available(iOS 13.0, *),
            let code = Bundle.main.preferredLocalizations.first
        {
            LanguageManager.saveLanguage(byCode: code)
        }
        LanguageManager.setupCurrentLanguage()

        let pushService : PushNotificationService = sharedServices.get()
        UNUserNotificationCenter.current().delegate = pushService
        pushService.registerForRemoteNotifications()
        pushService.setLaunchOptions(launchOptions)
        
        StoreKitManager.default.subscribeToPaymentQueue()
        StoreKitManager.default.updateAvailableProductsList()
        
        if #available(iOS 12.0, *) {
            let intent = WipeMainKeyIntent()
            let suggestions = [INShortcut(intent: intent)!]
            INVoiceShortcutCenter.shared.setShortcutSuggestions(suggestions)
        }
        
        if #available(iOS 11.0, *) {
            //self.generateToken()
        }
        
        if #available(iOS 13.0, *) {
            // multiwindow support managed by UISessionDelegate, not UIApplicationDelegate
        } else {
            self.coordinator.start()
        }
        return true
    }

    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return self.checkOrientation(window?.rootViewController)
    }
    
    func checkOrientation (_ viewController: UIViewController?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad || viewController == nil {
            return UIInterfaceOrientationMask.all
        } else if let nav = viewController as? UINavigationController {
            if (nav.topViewController!.isKind(of: PinCodeViewController.self)) {
                return UIInterfaceOrientationMask.portrait
            }
            return UIInterfaceOrientationMask.all
        } else {
            if let sw = viewController as? SWRevealViewController {
                if let nav = sw.frontViewController as? UINavigationController {
                    if (nav.topViewController!.isKind(of: PinCodeViewController.self)) {
                        return UIInterfaceOrientationMask.portrait
                    }
                }
            }
            return .all
        }
    }
    
    @available(iOS, deprecated: 13, message: "This method will not get called on multiwindow env, move the code to WindowSceneDelegate.scene(_:openURLContexts:)" )
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        return self.application(app, handleOpen: url)
    }
    
    @available(iOS, deprecated: 13, message: "This method will not get called on multiwindow env, move the code to WindowSceneDelegate.scene(_:openURLContexts:)" )
    func application(_ application: UIApplication, handleOpen url: URL) -> Bool {
        guard let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: true), urlComponents.host == "signup" else {
            return false
        }
        
        guard let queryItems = urlComponents.queryItems, let verifyObject = queryItems.filter({$0.name == "verifyCode"}).first else {
            return false
        }
        
        guard let code = verifyObject.value else {
            return false
        }
        ///TODO::fixme change to deeplink
        let info : [String:String] = ["verifyCode" : code]
        let notification = Notification(name: .customUrlSchema,
                                        object: nil,
                                        userInfo: info)
        NotificationCenter.default.post(notification)
        return true
    }
    
    @available(iOS, deprecated: 13, message: "This method will not get called on multiwindow env, move the code to WindowSceneDelegate.sceneDidEnterBackground()" )
    func applicationDidEnterBackground(_ application: UIApplication) {
        keymaker.updateAutolockCountdownStart()
        sharedMessageDataService.purgeOldMessages()
        
        var taskID = UIBackgroundTaskIdentifier(rawValue: 0)
        taskID = application.beginBackgroundTask { PMLog.D("Background Task Timed Out") }
        let delayedCompletion: ()->Void = {
            delay(3) {
                PMLog.D("End Background Task")
                application.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: taskID.rawValue))
            }
        }
        
        if SignInManager.shared.isSignedIn() {
            sharedMessageDataService.updateMessageCount()
            sharedMessageDataService.backgroundFetch { delayedCompletion() }
        } else {
            delayedCompletion()
        }
        PMLog.D("Enter Background")
    }
    
    @available(iOS, deprecated: 13, message: "This method will not get called on multiwindow env, deprecated in favor of similar method in WindowSceneDelegate" )
    func application(_ application: UIApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool
    {
        if let data = userActivity.userInfo?["deeplink"] as? Data,
            let deeplink = try? JSONDecoder().decode(DeepLink.self, from: data)
        {
            self.coordinator.followDeeplink(deeplink)
        }
        return true
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        //TODO::here need change to notify composer to save editing draft
        let mainContext = sharedCoreDataService.mainManagedObjectContext
        mainContext.performAndWait {
            let _ = mainContext.saveUpstreamIfNeeded()
        }
        
        let backgroundContext = sharedCoreDataService.mainManagedObjectContext
        backgroundContext.performAndWait {
            let _ = backgroundContext.saveUpstreamIfNeeded()
        }
    }
    
    // MARK: Background methods
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // this feature can only work if user did not lock the app
        guard SignInManager.shared.isSignedIn(), UnlockManager.shared.isUnlocked() else {
            completionHandler(.noData)
            return
        }
        sharedMessageDataService.backgroundFetch {
            completionHandler(.newData)
        }
    }
    
    // MARK: Notification methods
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Analytics.shared.logCustomEvent(customAttributes:[ "LogTitle": "NotificationError", "error" : "\(error)"])
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PMLog.D(deviceToken.stringFromToken())
        let pushService: PushNotificationService = sharedServices.get()
        pushService.didRegisterForRemoteNotifications(withDeviceToken: deviceToken.stringFromToken())
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first {
            let point = touch.location(in: UIApplication.shared.keyWindow)
            let statusBarFrame = UIApplication.shared.statusBarFrame
            if (statusBarFrame.contains(point)) {
                self.touchStatusBar()
            }
        }
    }
    
    func touchStatusBar() {
        let notification = Notification(name: .touchStatusBar, object: nil, userInfo: nil)
        NotificationCenter.default.post(notification)
    }

    // MARK: - State restoration via NSCoders, for iOS 9 - 12 and iOS 13 single window env (iPhone)
    
    func application(_ application: UIApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        if #available(iOS 13.0, *) {
            return UIDevice.current.stateRestorationPolicy == .coders
        } else {
            // iOS 9-12 with protection still needs coder to support deeplink restoration
            self.coordinator.saveForRestoration(coder)
            return true
        }
    }
    func application(_ application: UIApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        if #available(iOS 13.0, *) {
            // everything is handled by a window scene delegate
        } else if UIDevice.current.stateRestorationPolicy == .deeplink {
            self.coordinator.restoreState(coder)
        }
        
        return UIDevice.current.stateRestorationPolicy == .coders
    }
    func application(_ application: UIApplication, willEncodeRestorableStateWith coder: NSCoder) {
        if UIDevice.current.stateRestorationPolicy == .coders {
            self.coordinator.saveForRestoration(coder)
        }
    }
    func application(_ application: UIApplication, didDecodeRestorableStateWith coder: NSCoder) {
        if UIDevice.current.stateRestorationPolicy == .coders {
            self.coordinator.restoreState(coder)
        }
    }
    
    // MARK: - Multiwindow iOS 13
    
    @available(iOS 13.0, *)
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration
    {
        let scene = Scenes.fullApp // TODO: add more scenes
        let config = UISceneConfiguration(name: scene.rawValue, sessionRole: connectingSceneSession.role)
        config.delegateClass = scene.delegateClass
        return config
    }
    
    @available(iOS 13.0, *)
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        sceneSessions.forEach { session in
            // TODO: check that this discards state restoration for scenes explicitely closed by user
            session.stateRestorationActivity = nil
            session.scene?.userActivity = nil
        }
    }
    
    // MARK: Shortcuts
    @available(iOS, deprecated: 13, message: "This method will not get called on multiwindow env, deprecated in favor of similar method in WindowSceneDelegate" )
    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void)
    {
        if let data = shortcutItem.userInfo?["deeplink"] as? Data,
            let deeplink = try? JSONDecoder().decode(DeepLink.self, from: data)
        {
            self.coordinator.followDeeplink(deeplink)
        }
        completionHandler(true)
    }
}

