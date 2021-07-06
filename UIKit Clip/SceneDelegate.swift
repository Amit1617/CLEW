//
//  SceneDelegate.swift
//  MyAppClip
//
//  Created by Paul Ruvolo on 6/30/21.
//

import UIKit
import SwiftUI
import Firebase

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    var vc: ViewController?
    var popoverController: UIViewController?
    
    
    func createScene(_ scene: UIScene) {
        // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
        // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
        guard let scene = (scene as? UIWindowScene) else { return }
        window = UIWindow(windowScene: scene)
        vc = ViewController()
        window?.frame = UIScreen.main.bounds
        window?.rootViewController = vc
        window?.backgroundColor = .white
        window?.makeKeyAndVisible()
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    func loadRoute() {
        vc?.imageAnchoring = true
        vc?.recordPathController.remove()
        vc?.handleStateTransitionToNavigatingExternalRoute()
    }
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        
        createScene(scene)
        //vc?.routeID = "table2wall"
        // TODO: get rid of this once available routes is set in a different way
        
        vc?.availableRoutes["Table to Wall"] = "AppClipRoutes/Please work.crd"
        vc?.availableRoutes["Table to Office"] = "AppClipRoutes/Please work.crd"
        vc?.availableRoutes["Table to Bathroom"] = "AppClipRoutes/Please work.crd"


        print("Dictionary: \(vc?.availableRoutes)")
        popoverController = UIHostingController(rootView: StartNavigationPopoverView(vc: vc!))
        popoverController?.modalPresentationStyle = .fullScreen
        vc!.present(popoverController!, animated: true)
        print("popover successful B)")
        // create listeners to ensure that the isReadingAnnouncement flag is reset properly
        NotificationCenter.default.addObserver(forName: NSNotification.Name("shouldDismissRoutePopover"), object: nil, queue: nil) { (notification) -> Void in
            self.popoverController?.dismiss(animated: true)
        }
    }
    
    /// handles invocations in the App Clip <3
    /// return: Boolean value representing whether or not there is a userActivity object
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else {
            return
            }
        createScene(scene)
        handleUserActivity(for: url)
        
        popoverController = UIHostingController(rootView: StartNavigationPopoverView(vc: vc!))
        popoverController?.modalPresentationStyle = .popover
        vc!.present(popoverController!, animated: true)
        print("popover successful B)")
        // create listeners to ensure that the isReadingAnnouncement flag is reset properly
        NotificationCenter.default.addObserver(forName: NSNotification.Name("shouldDismissRoutePopover"), object: nil, queue: nil) { (notification) -> Void in
            self.popoverController?.dismiss(animated: true)
        }
        
    }
    
    /// Configure App Clip with query items
    func handleUserActivity(for url: URL) {
        // TODO: update this to load urls into a list of urls to be passed into the popover list <3
        guard let components = NSURLComponents(url: url, resolvingAgainstBaseURL: true), let queryItems = components.queryItems else {
            return
        }
        
        /// with the invocation URL format https://occamlab.github.io/id?p=appClipCodeID&p1=routeID, and routeID being the name of the file in Firebase
        if let appClipCodeID = queryItems.first(where: { $0.name == "p"}) {
            vc?.appClipCodeID = appClipCodeID.value!
            
            if let routeID = queryItems.first(where: { $0.name == "p1"}) {
                vc?.routeID = routeID.value!
                vc?.availableRoutes[routeID.value!] = "routes/\(appClipCodeID.value!)/\(routeID.value!).crd"

            }
        }
        

                
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }


}
