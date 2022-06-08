//
//  ViewController.swift
//  ARKitTest
//
//  Created by Chris Seonghwan Yoon & Jeremy Ryan on 7/10/17.
//
// Confirmed issues
// - We are not doing a proper job dealing with resumed routes with respect to logging (we always send recorded stuff in the log file, which we don't always have access to)
//
// Unconfirmed issues issues
// - Maybe intercept session was interrupted so that we don't mistakenly try to navigate saved route before relocalization
//
// Major features to implement
//
// Potential enhancements
//  - Add a tip to the help file regarding holding phone against your chest (see Per Rosqvist's suggestion)
//  - Warn user via an alert if they have an iPhone 5S or 6
//  - Possibly create a warning if the phone doesn't appear to be in the correct orientation
//  - revisit turn warning feature.  It doesn't seem to actually help all that much at the moment.

// Path alignment
// TODO: implement local suppression so we don't get to many alignment points in one place.
// TODO: implement something to keep the points moving in the proper direction (avoid reversing the route on mistake)
// TODO: automatically add the first keypoint of the route (probably this would also involve an alignment at that point as well)
// TODO: recency of path alignment

import UIKit
import ARKit
import SceneKit
import SceneKit.ModelIO
import AVFoundation
import AudioToolbox
import MediaPlayer
import VectorMath
import Firebase
import FirebaseDatabase
import SRCountdownTimer

/// A custom enumeration type that describes the exact state of the app.  The state is not exhaustive (e.g., there are Boolean flags that also track app state).
enum AppState {
    /// This is the screen the comes up immediately after the splash screen
    case mainScreen(announceArrival: Bool)
    /// User is recording the route
    case recordingRoute
    /// User can either navigate back or pause
    case readyToNavigateOrPause(allowPause: Bool)
    /// User is navigating along a route
    case navigatingRoute
    /// User is rating the route
    case ratingRoute(announceArrival: Bool)
    /// The app is starting up
    case initializing
    /// The user has requested a pause, but has not yet put the phone in the save location
    case startingPauseProcedure
    /// The user has hit the volume button.  The app now enters a waiting period for the tracking to stabilize
    case pauseWaitingPeriod
    /// user is attempting to complete the pausing procedure
    case completingPauseProcedure
    /// user has successfully paused the ARSession
    case pauseProcedureCompleted
    /// user has hit the resume button and is waiting for the volume to hit
    case startingResumeProcedure(route: SavedRoute, mapAsAny: Any?, navigateStartToEnd: Bool)
    /// the AR session has entered the relocalizing state, which means that we can now realign the session
    case readyForFinalResumeAlignment
    
    /// rawValue is useful for serializing state values, which we are currently using for our logging feature
    var rawValue: String {
        switch self {
        case .mainScreen(let announceArrival):
            return "mainScreen(announceArrival=\(announceArrival))"
        case .recordingRoute:
            return "recordingRoute"
        case .readyToNavigateOrPause:
            return "readyToNavigateOrPause"
        case .navigatingRoute:
            return "navigatingRoute"
        case .ratingRoute(let announceArrival):
            return "ratingRoute(announceArrival=\(announceArrival))"
        case .initializing:
            return "initializing"
        case .startingPauseProcedure:
            return "startingPauseProcedure"
        case .pauseWaitingPeriod:
            return "pauseWaitingPeriod"
        case .completingPauseProcedure:
            return "completingPauseProcedure"
        case .pauseProcedureCompleted:
            return "pauseProcedureCompleted"
        case .startingResumeProcedure(_, _, let navigateStartToEnd):
            return "startingResumeProcedure(route=notloggedhere, map=notlogged, navigateStartToEnd=\(navigateStartToEnd))"
        case .readyForFinalResumeAlignment:
            return "readyForFinalResumeAlignment"
        }
    }
}

/// The view controller that handles the main Clew window.  This view controller is always active and handles the various views that are used for different app functionalities.
class ViewController: UIViewController, ARSCNViewDelegate, SRCountdownTimerDelegate, AVSpeechSynthesizerDelegate {
    
    // MARK: - Refactoring UI definition
    
    // MARK: Properties and subview declarations
    
    /// How long to wait (in seconds) between the alignment request and grabbing the transform
    static var alignmentWaitingPeriod = 5
    
    /// The state of the ARKit tracking session as last communicated to us through the delgate protocol.  This is useful if you want to do something different in the delegate method depending on the previous state
    var trackingSessionState : ARCamera.TrackingState?
    
    /// The state of the app.  This should be constantly referenced and updated as the app transitions
    var state = AppState.initializing {
        didSet {
            logger.logStateTransition(newState: state)
            switch state {
            case .recordingRoute:
                handleStateTransitionToRecordingRoute()
            case .readyToNavigateOrPause:
                handleStateTransitionToReadyToNavigateOrPause(allowPause: !isResumedRoute)
            case .navigatingRoute:
                handleStateTransitionToNavigatingRoute()
            case .ratingRoute(let announceArrival):
                handleStateTransitionToRatingRoute(announceArrival: announceArrival)
            case .mainScreen(let announceArrival):
                handleStateTransitionToMainScreen(announceArrival: announceArrival)
            case .startingPauseProcedure:
                handleStateTransitionToStartingPauseProcedure()
            case .pauseWaitingPeriod:
                handleStateTransitionToPauseWaitingPeriod()
            case .completingPauseProcedure:
                handleStateTransitionToCompletingPauseProcedure()
            case .pauseProcedureCompleted:
                // nothing happens currently
                break
            case .startingResumeProcedure(let route, let mapAsAny, let navigateStartToEnd):
                handleStateTransitionToStartingResumeProcedure(route: route, mapAsAny: mapAsAny, navigateStartToEnd: navigateStartToEnd)
            case .readyForFinalResumeAlignment:
                // nothing happens currently
                break
            case .initializing:
                break
            }
        }
    }

    /// When VoiceOver is not active, we use AVSpeechSynthesizer for speech feedback
    let synth = AVSpeechSynthesizer()
    
    /// The announcement that is currently being read.  If this is nil, that implies nothing is being read
    var currentAnnouncement: String?
    
    /// The announcement that should be read immediately after this one finishes
    var nextAnnouncement: String?
    
    /// A boolean that tracks whether or not to suppress tracking warnings.  By default we don't suppress, but when the help popover is presented we do.
    var suppressTrackingWarnings = false
    
    /// This Boolean marks whether or not the pause procedure is being used to create a landmark at the start of a route (true) or if it is being used to pause an already recorded route
    var creatingRouteLandmark: Bool = false
    
    /// This Boolean marks whether or not the user is resuming a route
    var isResumedRoute: Bool = false
    
    /// Set to true when the user is attempting to load a saved route that has a map associated with it. Once relocalization succeeds, this flag should be set back to false
    var attemptingRelocalization: Bool = false
    
    /// This is an audio player that queues up the voice note associated with a particular route landmark. The player is created whenever a saved route is loaded. Loading it before the user clicks the "Play Voice Note" button allows us to call the prepareToPlay function which reduces the latency when the user clicks the "Play Voice Note" button.
    var voiceNoteToPlay: AVAudioPlayer?
    
    // MARK: - Speech Synthesizer Delegate
    
    /// Called when an utterance is finished.  We implement this function so that we can keep track of
    /// whether or not an announcement is currently being read to the user.
    ///
    /// - Parameters:
    ///   - synthesizer: the synthesizer that finished the utterance
    ///   - utterance: the utterance itself
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        currentAnnouncement = nil
        if let nextAnnouncement = self.nextAnnouncement {
            self.nextAnnouncement = nil
            announce(announcement: nextAnnouncement)
        }
    }
    
    /// Called when an utterance is canceled.  We implement this function so that we can keep track of
    /// whether or not an announcement is currently being read to the user.
    ///
    /// - Parameters:
    ///   - synthesizer: the synthesizer that finished the utterance
    ///   - utterance: the utterance itself
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        currentAnnouncement = nil
        if let nextAnnouncement = self.nextAnnouncement {
            self.nextAnnouncement = nil
            announce(announcement: nextAnnouncement)
        }
    }
    
    /// Handler for the mainScreen app state
    ///
    /// - Parameter announceArrival: a Boolean that indicates whether the user's arrival should be announced (true means the user has arrived)
    func handleStateTransitionToMainScreen(announceArrival: Bool) {
        showRecordPathButton(announceArrival: announceArrival)
    }
    
    /// Handler for the recordingRoute app state
    func handleStateTransitionToRecordingRoute() {
        // records a new path
        attemptingRelocalization = false
        
        crumbs = []
        logger.resetPathLog()
        
        showStopRecordingButton()
        droppingCrumbs = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(dropCrumb), userInfo: nil, repeats: true)
        // make sure there are no old values hanging around
        nav.headingOffset = 0.0
        headingRingBuffer.clear()
        locationRingBuffer.clear()
        updateHeadingOffsetTimer = Timer.scheduledTimer(timeInterval: 0.01, target: self, selector: (#selector(updateHeadingOffset)), userInfo: nil, repeats: true)
    }
    
    /// Handler for the readyToNavigateOrPause app state
    ///
    /// - Parameter allowPause: a Boolean that determines whether the app should allow the user to pause the route (this is only allowed if it is the initial route recording)
    func handleStateTransitionToReadyToNavigateOrPause(allowPause: Bool) {
        droppingCrumbs?.invalidate()
        updateHeadingOffsetTimer?.invalidate()
        showStartNavigationButton(allowPause: allowPause)
    }
    
    /// Removes all of the follow crumbs that have been built-up in the system
    func clearAllFollowCrumbs() {
        guard let anchors = sceneView.session.currentFrame?.anchors else {
            return
        }
        for anchor in anchors {
            if let name = anchor.name, name == "followCrumb" {
                sceneView.session.remove(anchor: anchor)
            }
        }
    }
    
    /// Handler for the navigatingRoute app state
    func handleStateTransitionToNavigatingRoute() {
        // navigate the recorded path

        // If the route has not yet been saved, we can no longer save this route
        routeName = nil
        beginRouteLandmark = RouteLandmark()
        endRouteLandmark = RouteLandmark()
        clearAllFollowCrumbs()
        logger.resetNavigationLog()

        // generate path from PathFinder class
        // enabled hapticFeedback generates more keypoints
        let path = PathFinder(crumbs: crumbs.reversed(), hapticFeedback: hapticFeedback, voiceFeedback: voiceFeedback)
        keypoints = path.keypoints
        checkedOffKeypoints = []
        
        // save keypoints data for debug log
        logger.logKeypoints(keypoints: keypoints)
        
        // render 3D keypoints
        renderKeypoint(keypoints[0].location)
        
        // TODO: gracefully handle error
        prevKeypointPosition = getRealCoordinates(record: true)!.location
        
        feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
        waypointFeedbackGenerator = UINotificationFeedbackGenerator()
        
        showStopNavigationButton()

        // wait a little bit before starting navigation to allow screen to transition and make room for the first direction announcement to be communicated
        
        if UIAccessibility.isVoiceOverRunning {
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { timer in
                self.followingCrumbs = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: (#selector(self.followCrumb)), userInfo: nil, repeats: true)
            }
        } else {
            followingCrumbs = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: (#selector(self.followCrumb)), userInfo: nil, repeats: true)
        }
        
        feedbackTimer = Date()
        // make sure there are no old values hanging around
        headingRingBuffer.clear()
        locationRingBuffer.clear()
        hapticTimer = Timer.scheduledTimer(timeInterval: 0.01, target: self, selector: (#selector(getHapticFeedback)), userInfo: nil, repeats: true)
        print("turning off auto snap to route")
        //snapToRouteTimer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: (#selector(snapToRoute)), userInfo: nil, repeats: true)
    }
    
    /// Handler for the route rating app state
    ///
    /// - Parameter announceArrival: a Boolean that is true if we should announce that the user has arrived at the destination and false otherwise
    func handleStateTransitionToRatingRoute(announceArrival: Bool) {
        showRouteRating(announceArrival: announceArrival)
    }
    
    /// Handler for the startingResumeProcedure app state
    ///
    /// - Parameters:
    ///   - route: the route to navigate
    ///   - mapAsAny: the world map to use (expressed as `Any?` since it is optional and we want to maintain backwards compatibility with iOS 11.3)
    ///   - navigateStartToEnd: a Boolean that is true if we want to navigate from the start to the end and false if we want to navigate from the end to the start.
    func handleStateTransitionToStartingResumeProcedure(route: SavedRoute, mapAsAny: Any?, navigateStartToEnd: Bool) {
        // load the world map and restart the session so that things have a chance to quiet down before putting it up to the wall
        let isTrackingPerformanceNormal: Bool
        if case .normal? = sceneView.session.currentFrame?.camera.trackingState {
            isTrackingPerformanceNormal = true
        } else {
            isTrackingPerformanceNormal = false
        }
        
        var isSameMap = false
        if #available(iOS 12.0, *) {
            let map = mapAsAny as! ARWorldMap?
            isSameMap = configuration.initialWorldMap != nil && configuration.initialWorldMap == map
            configuration.initialWorldMap = map
        
            attemptingRelocalization =  isSameMap && !isTrackingPerformanceNormal || map != nil && !isSameMap
        }

        if navigateStartToEnd {
            crumbs = route.crumbs.reversed()
            pausedLandmark = route.beginRouteLandmark
        } else {
            crumbs = route.crumbs
            pausedLandmark = route.endRouteLandmark
        }
        // TODO: we may need to revisit whether we need to undo previously applied relativeTransforms (I suspect not though)
        sceneView.session.run(configuration, options: [.removeExistingAnchors])

        if isTrackingPerformanceNormal, isSameMap {
            // we can skip the whole process of relocalization since we are already using the correct map and tracking is normal.  It helps to strip out old anchors to reduce jitter though
            isResumedRoute = true
            state = .readyToNavigateOrPause(allowPause: false)
        } else {
            // setting this flag after entering the .limited(reason: .relocalizing) state is a bit error prone.  Since there is a waiting period, there is no way that we will ever finish the alignment countdown before the session has successfully restarted
            state = .readyForFinalResumeAlignment
            showResumeTrackingConfirmButton(route: route, navigateStartToEnd: navigateStartToEnd)
        }
    }
    
    /// Handler for the startingPauseProcedure app state
    func handleStateTransitionToStartingPauseProcedure() {
        // clear out these variables in case they had already been created
        if creatingRouteLandmark {
            beginRouteLandmark = RouteLandmark()
        } else {
            endRouteLandmark = RouteLandmark()
        }
        do {
            try showPauseTrackingButton()
        } catch {
            // nothing to fall back on
        }
    }
    
    /// Handler for the pauseWaitingPeriod app state
    func handleStateTransitionToPauseWaitingPeriod() {
        hideAllViewsHelper()
        ///sets the length of the timer to be equal to what the person has in their settings
        ViewController.alignmentWaitingPeriod = timerLength
        rootContainerView.countdownTimer.isHidden = false
        rootContainerView.countdownTimer.start(beginingValue: ViewController.alignmentWaitingPeriod, interval: 1)
        delayTransition()
        playAlignmentConfirmation = DispatchWorkItem{
            self.rootContainerView.countdownTimer.isHidden = true
            self.pauseTracking()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(ViewController.alignmentWaitingPeriod), execute: playAlignmentConfirmation!)
    }
    
    /// Handler for the completingPauseProcedure app state
    func handleStateTransitionToCompletingPauseProcedure() {
        // TODO: we should not be able to create a route landmark if we are in the relocalizing state... (might want to handle this when the user stops navigation on a route they loaded.... This would obviate the need to handle this in the recordPath code as well
        print("completing pause procedure")
        if creatingRouteLandmark {
            guard let currentTransform = sceneView.session.currentFrame?.camera.transform else {
                print("can't properly save landmark: TODO communicate this to the user somehow")
                return
            }
            beginRouteLandmark.transform = currentTransform
            Timer.scheduledTimer(timeInterval: 1, target: self, selector: (#selector(playSound)), userInfo: nil, repeats: false)
            pauseTrackingController.remove()
            state = .mainScreen(announceArrival: false)
            return
        } else if let currentTransform = sceneView.session.currentFrame?.camera.transform {
            endRouteLandmark.transform = currentTransform

            if #available(iOS 12.0, *) {
                sceneView.session.getCurrentWorldMap { worldMap, error in
                    self.getRouteNameAndSaveRouteHelper(mapAsAny: worldMap)
                    self.showResumeTrackingButton()
                    Timer.scheduledTimer(timeInterval: 1, target: self, selector: (#selector(self.playSound)), userInfo: nil, repeats: false)
                    self.state = .pauseProcedureCompleted
                }
            } else {
                getRouteNameAndSaveRouteHelper(mapAsAny: nil)
                showResumeTrackingButton()
                Timer.scheduledTimer(timeInterval: 1, target: self, selector: (#selector(self.playSound)), userInfo: nil, repeats: false)
                state = .pauseProcedureCompleted
            }
        }
    }
    
    /// Prompt the user for the name of a route and persist the route data if the user supplies one.  If the user cancels, no action is taken.
    ///
    /// - Parameter mapAsAny: the world map (the `Any?` type is used since it is optional and we want to maintain backward compatibility with iOS 11.3
    func getRouteNameAndSaveRouteHelper(mapAsAny: Any?) {
        if routeName == nil {
            // get a route name
            showRouteNamingDialog(mapAsAny: mapAsAny)
        } else {
            do {
                // TODO: factor this out since it shows up in a few places
                let id = String(Int64(NSDate().timeIntervalSince1970 * 1000)) as NSString
                try archive(routeId: id, beginRouteLandmark: beginRouteLandmark, endRouteLandmark: endRouteLandmark, worldMapAsAny: mapAsAny)
            } catch {
                fatalError("Can't archive route: \(error.localizedDescription)")
            }
        }
    }
    
    /// Called when the user presses the routes button.  The function will display the `Routes` view, which is managed by `RoutesViewController`.
    @objc func routesButtonPressed() {
        let storyBoard: UIStoryboard = UIStoryboard(name: "SettingsAndHelp", bundle: nil)
        let popoverContent = storyBoard.instantiateViewController(withIdentifier: "Routes") as! RoutesViewController
        popoverContent.preferredContentSize = CGSize(width: UIScreen.main.bounds.size.width, height: UIScreen.main.bounds.size.height)
        popoverContent.rootViewController = self
        popoverContent.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: popoverContent, action: #selector(popoverContent.doneWithRoutes))
        popoverContent.updateRoutes(routes: dataPersistence.routes)
        let nav = UINavigationController(rootViewController: popoverContent)
        nav.modalPresentationStyle = .popover
        let popover = nav.popoverPresentationController
        popover?.delegate = self
        popover?.sourceView = self.view
        popover?.sourceRect = CGRect(x: 0,
                                     y: UIConstants.settingsAndHelpFrameHeight/2,
                                     width: 0,height: 0)
        
        self.present(nav, animated: true, completion: nil)
    }
    
    /// Hide all the subviews.  TODO: This should probably eventually refactored so it happens more automatically.
    func hideAllViewsHelper() {
        recordPathController.remove()
        routeRatingController.remove()
        stopRecordingController.remove()
        startNavigationController.remove()
        stopNavigationController.remove()
        pauseTrackingController.remove()
        resumeTrackingConfirmController.remove()
        resumeTrackingController.remove()
        rootContainerView.countdownTimer.isHidden = true
    }
    
    /// This handles when a route cell is clicked (triggering the route to be loaded).
    ///
    /// - Parameters:
    ///   - route: the route that was clicked
    ///   - navigateStartToEnd: a Boolean indicating the navigation direction (true is start to end)
    func onRouteTableViewCellClicked(route: SavedRoute, navigateStartToEnd: Bool) {
        let worldMapAsAny = dataPersistence.unarchiveMap(id: route.id as String)
        hideAllViewsHelper()
        state = .startingResumeProcedure(route: route, mapAsAny: worldMapAsAny, navigateStartToEnd: navigateStartToEnd)
    }
    
    /// Saves the specified route.  The bulk of the work is done by the `DataPersistence` class, but this is a convenient wrapper.
    ///
    /// - Parameters:
    ///   - routeId: the ID of the route
    ///   - beginRouteLandmark: the route landmark for the beginning (if there is no route landmark at the beginning, the elements of this struct can be nil)
    ///   - endRouteLandmark: the route landmark for the end (if there is no route landmark at the end, the elements of this struct can be nil)
    ///   - worldMapAsAny: the world map (we use `Any?` since it is optional and we want to maintain backward compatibility with iOS 11.3)
    /// - Throws: an error if something goes wrong
    func archive(routeId: NSString, beginRouteLandmark: RouteLandmark, endRouteLandmark: RouteLandmark, worldMapAsAny: Any?) throws {
        let savedRoute = SavedRoute(id: routeId, name: routeName!, crumbs: crumbs, dateCreated: Date() as NSDate, beginRouteLandmark: beginRouteLandmark, endRouteLandmark: endRouteLandmark)
        try dataPersistence.archive(route: savedRoute, worldMapAsAny: worldMapAsAny)
        justTraveledRoute = savedRoute
    }

    /// A threshold to determine when a segment is long enough to use for soft alignment
    var softAlignmentSegmentLengthThreshold = 1.0
    
    /// While recording, every 0.01s, check to see if we should reset the heading offset
    var angleOffsetTimer: Timer?
    
    /// A threshold to determine when the phone rotated too much to update the angle offset
    let angleDeviationThreshold : Float = 0.2
    /// The minimum distance traveled in the floor plane in order to update the angle offset
    let requiredDistance : Float = 0.3
    /// A threshold to determine when a path is too curvy to update the angle offset
    let linearDeviationThreshold: Float = 0.05
    
    /// a ring buffer used to keep the last 50 positions of the phone
    var locationRingBuffer = RingBuffer<Vector3>(capacity: 50)
    /// a ring buffer used to keep the last 100 headings of the phone
    var headingRingBuffer = RingBuffer<Float>(capacity: 50)

    /// The conection to the Firebase real-time database
    var databaseHandle = Database.database()
    
    /// Keypoint object
    var keypointObject : MDLObject!
    
    /// Route persistence
    var dataPersistence = DataPersistence()
    
    // MARK: - Parameters that can be controlled remotely via Firebase
    
    /// True if the offset between direction of travel and phone should be updated over time
    var adjustOffset = false
    
    /// True if we should use a cone of pi/12 and false if we should use a cone of pi/6 when deciding whether to issue haptic feedback
    var strictHaptic = true
    
    /// This is embeds an AR scene.  The ARSession is a part of the scene view, which allows us to capture where the phone is in space and the state of the world tracking.  The scene also allows us to insert virtual objects
    var sceneView = ARSCNView()
    
    /// Hide status bar
    override var prefersStatusBarHidden: Bool {
        return true
    }

    /// audio players for playing system sounds through an `AVAudioSession` (this allows them to be audible even when the rocker switch is muted.
    var audioPlayers: [Int: AVAudioPlayer] = [:]
    
    /// Callback function for when `countdownTimer` updates.  This allows us to announce the new value via voice
    ///
    /// - Parameter newValue: the new value (in seconds) displayed on the countdown timer
    @objc func timerDidUpdateCounterValue(newValue: Int) {
        UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: String(newValue))
    }
    
    /// Hook in the view class as a view, so that we can access its variables easily
    var rootContainerView: RootContainerView {
        return view as! RootContainerView
    }
    
    /// child view controllers for various app states
    
    /// route rating VC
    var routeRatingController: RouteRatingController!
    
    /// route navigation pausing VC
    var pauseTrackingController: PauseTrackingController!
    
    /// route navigation resuming VC
    var resumeTrackingController: ResumeTrackingController!
    
    /// route navigation resuming alignment and confirmation VC
    var resumeTrackingConfirmController: ResumeTrackingConfirmController!
    
    /// route recording dismissal VC
    var stopRecordingController: StopRecordingController!
    
    /// route recording VC (called on app start)
    var recordPathController: RecordPathController!
    
    /// start route navigation VC
    var startNavigationController: StartNavigationController!
    
    /// work item for playing alignment confirmation sound
    var playAlignmentConfirmation: DispatchWorkItem?
    
    /// stop route navigation VC
    var stopNavigationController: StopNavigationController!

    /// called when the view has loaded.  We setup various app elements in here.
    override func viewDidLoad() {
        super.viewDidLoad()

        // set the main view as active
        view = RootContainerView(frame: UIScreen.main.bounds)
        
        // initialize child view controllers
        routeRatingController = RouteRatingController()
        pauseTrackingController = PauseTrackingController()
        resumeTrackingController = ResumeTrackingController()
        resumeTrackingConfirmController = ResumeTrackingConfirmController()
        stopRecordingController = StopRecordingController()
        recordPathController = RecordPathController()
        startNavigationController = StartNavigationController()
        stopNavigationController = StopNavigationController()
        
        // Add the scene to the view, which is a RootContainerView
        sceneView.frame = view.frame
        view.addSubview(sceneView)

        setupAudioPlayers()
        loadAssets()
        createSettingsBundle()
        createARSession()
        
        state = .mainScreen(announceArrival: false)
        view.sendSubviewToBack(sceneView)
        
        // targets for global buttons
        rootContainerView.settingsButton.addTarget(self, action: #selector(settingsButtonPressed), for: .touchUpInside)

        rootContainerView.helpButton.addTarget(self, action: #selector(helpButtonPressed), for: .touchUpInside)
        
        rootContainerView.homeButton.addTarget(self, action: #selector(homeButtonPressed), for: .touchUpInside)

        rootContainerView.getDirectionButton.addTarget(self, action: #selector(announceDirectionHelpPressed), for: .touchUpInside)

        rootContainerView.feedbackButton.addTarget(self, action: #selector(feedbackButtonPressed), for: .touchUpInside)

        // make sure this happens after the view is created!
        rootContainerView.countdownTimer.delegate = self
        ///sets the length of the timer to be equal to what the person has in their settings
        ViewController.alignmentWaitingPeriod = timerLength
        
        addGestures()
        setupFirebaseObservers()
        
        // create listeners to ensure that the isReadingAnnouncement flag is reset properly
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { (notification) -> Void in
            self.currentAnnouncement = nil
        }
        
        NotificationCenter.default.addObserver(forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: nil) { (notification) -> Void in
            self.currentAnnouncement = nil
        }
        
        // we use a custom notification to communicate from the help controller to the main view controller that the help was dismissed
        NotificationCenter.default.addObserver(forName: Notification.Name("ClewPopoverDismissed"), object: nil, queue: nil) { (notification) -> Void in
            self.suppressTrackingWarnings = false
        }
    }
    
    /// Create the audio player objects for the various app sounds.  Creating them ahead of time helps reduce latency when playing them later.
    func setupAudioPlayers() {
        do {
            audioPlayers[1103] = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: "/System/Library/Audio/UISounds/Tink.caf"))
            audioPlayers[1016] = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: "/System/Library/Audio/UISounds/tweet_sent.caf"))
            audioPlayers[1050] = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: "/System/Library/Audio/UISounds/ussd.caf"))
            audioPlayers[1025] = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: "/System/Library/Audio/UISounds/New/Fanfare.caf"))

            for p in audioPlayers.values {
                p.prepareToPlay()
            }
        } catch let error {
            print("count not setup audio players", error)
        }
    }
    
    /// Load the crumb 3D model
    func loadAssets() {
        let url = NSURL(fileURLWithPath: Bundle.main.path(forResource: "Crumb", ofType: "obj")!)
        let asset = MDLAsset(url: url as URL)
        keypointObject = asset.object(at: 0)
    }
    
    /// Observe the relevant Firebase paths to handle any dynamic reconfiguration requests (this is currently not used in the app store version of Clew)
    func setupFirebaseObservers() {
        let responsePathRef = databaseHandle.reference(withPath: "config/" + UIDevice.current.identifierForVendor!.uuidString)
        responsePathRef.observe(.childChanged) { (snapshot) -> Void in
            self.handleNewConfig(snapshot: snapshot)
        }
        responsePathRef.observe(.childAdded) { (snapshot) -> Void in
            self.handleNewConfig(snapshot: snapshot)
        }
    }
    
    /// Respond to any dynamic reconfiguration requests (this is currently not used in the app store version of Clew).
    ///
    /// - Parameter snapshot: the new configuration data
    func handleNewConfig(snapshot: DataSnapshot) {
        if snapshot.key == "adjust_offset", let newValue = snapshot.value as? Bool {
            adjustOffset = newValue
            if !adjustOffset {
                // clear the offset in case one was set from before
                nav.headingOffset = 0.0
            }
            print("set new adjust offset value", newValue)
        } else if snapshot.key == "strict_haptic", let newValue = snapshot.value as? Bool {
            strictHaptic = newValue
            print("set new strict haptic value", newValue)
        }
    }
    
    /// Called when the view appears on screen.
    ///
    /// - Parameter animated: True if the appearance is animated
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        let userDefaults: UserDefaults = UserDefaults.standard
        let firstTimeLoggingIn: Bool? = userDefaults.object(forKey: "firstTimeLogin") as? Bool
        
        if (firstTimeLoggingIn == nil) {
            userDefaults.set(true, forKey: "firstTimeLogin")
            showLogAlert()
        }
        
        synth.delegate = self
        NotificationCenter.default.addObserver(forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: nil) { (notification) -> Void in
            self.currentAnnouncement = nil
            if let nextAnnouncement = self.nextAnnouncement {
                self.nextAnnouncement = nil
                self.announce(announcement: nextAnnouncement)
            }
        }
    }
    
    
    /// func that prepares the state transition to home by clearing active processes and data
    func clearState() {
        // TODO: check for code reuse
        // Clearing All State Processes and Data
        rootContainerView.homeButton.isHidden = true
        recordPathController.isAccessibilityElement = false
        if case .navigatingRoute = self.state {
            keypointNode.removeFromParentNode()
        }
        followingCrumbs?.invalidate()
        routeName = nil
        beginRouteLandmark = RouteLandmark()
        endRouteLandmark = RouteLandmark()
        playAlignmentConfirmation?.cancel()
        rootContainerView.announcementText.isHidden = true
        nav.headingOffset = 0.0
        headingRingBuffer.clear()
        locationRingBuffer.clear()
        logger.resetNavigationLog()
        logger.resetPathLog()
        hapticTimer?.invalidate()
        snapToRouteTimer?.invalidate()
        logger.resetStateSequenceLog()
    }
    
    /// function that creates alerts for the home button
    func homePageNavigationProcesses() {
        // Create alert to warn users of lost information
        let alert = UIAlertController(title: "Are you sure?",
                                      message: "If you exit this process right now, your active route information will be lost.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Go to the Home Page", style: .default, handler: { action -> Void in
            // proceed to home page
            self.clearState()
            self.hideAllViewsHelper()
            self.state = .mainScreen(announceArrival: false)
        }
        ))
        alert.addAction(UIAlertAction(title: "Cancel", style: .default, handler: { action -> Void in
            // nothing to do, just stay on the page
        }
        ))
        self.present(alert, animated: true, completion: nil)
    }

    
    /// Display a warning that tells the user they must create a landmark to be able to use this route again in the forward direction
    /// Display the dialog that prompts the user to enter a route name.  If the user enters a route name, the route along with the optional world map will be persisted.
    ///
    /// - Parameter mapAsAny: the world map to save (the `Any?` type is used to indicate that the map is optional and to preserve backwards compatibility with iOS 11.3)
    @objc func showRouteNamingDialog(mapAsAny: Any?) {
        // Set title and message for the alert dialog
        if #available(iOS 12.0, *) {
            justUsedMap = mapAsAny as! ARWorldMap?
        }
        let alertController = UIAlertController(title: NSLocalizedString("Save route", comment: "The title of a popup window where user enters a name for the route they want to save."), message: NSLocalizedString("Enter the name of the route", comment: "Ask user to provide a descriptive name for the route they want to save."), preferredStyle: .alert)
        // The confirm action taking the inputs
        let saveAction = UIAlertAction(title: NSLocalizedString("Save", comment: "An option for the user to select"), style: .default) { (_) in
            let id = String(Int64(NSDate().timeIntervalSince1970 * 1000)) as NSString
            // Get the input values from user, if it's nil then use timestamp
            self.routeName = alertController.textFields?[0].text as NSString? ?? id
            try! self.archive(routeId: id, beginRouteLandmark: self.beginRouteLandmark, endRouteLandmark: self.endRouteLandmark, worldMapAsAny: mapAsAny)
        }
            
        // The cancel action saves the just traversed route so you can navigate back along it later
        let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: "An option for the user to select"), style: .cancel) { (_) in
            self.justTraveledRoute = SavedRoute(id: "dummyid", name: "Last route", crumbs: self.crumbs, dateCreated: Date() as NSDate, beginRouteLandmark: self.beginRouteLandmark, endRouteLandmark: self.endRouteLandmark)
        }
        
        // Add textfield to our dialog box
        alertController.addTextField { (textField) in
            textField.becomeFirstResponder()
            textField.placeholder = NSLocalizedString("Enter route title", comment: "A placeholder before user enters text in textbox")
        }
            
        // Add the action to dialogbox
        alertController.addAction(saveAction)
        alertController.addAction(cancelAction)
            
        // Finally, present the dialog box
        present(alertController, animated: true, completion: nil)
    }

    
    /// Show the dialog that allows the user to enter textual information to help them remember a landmark.
    @objc func showLandmarkInformationDialog() {
        rootContainerView.homeButton.isHidden = false
//        backButton.isHidden = true
        // Set title and message for the alert dialog
        let alertController = UIAlertController(title: NSLocalizedString("Landmark information", comment: "The header of a pop-up menu"), message: NSLocalizedString("Enter text about the landmark that will help you find it later.", comment: "Prompts user to enter information"), preferredStyle: .alert)
        // The confirm action taking the inputs
        let saveAction = UIAlertAction(title: NSLocalizedString("Ok", comment: "A button for user to click to acknowledge and close a pop-up"), style: .default) { (_) in
            if self.creatingRouteLandmark {
                self.beginRouteLandmark.information = alertController.textFields?[0].text as NSString?
            } else {
                self.endRouteLandmark.information = alertController.textFields?[0].text as NSString?
            }
        }
        
        // The cancel action saves the just traversed route so you can navigate back along it later
        let cancelAction = UIAlertAction(title: NSLocalizedString("Don't specify this information", comment: "A button for user to click"), style: .cancel) { (_) in
        }
        
        // Add textfield to our dialog box
        alertController.addTextField { (textField) in
            textField.becomeFirstResponder()
            textField.placeholder = NSLocalizedString("Enter landmark information", comment: "A placeholder that appears in text box before user enters any text.")
        }
        
        // Add the action to dialogbox
        alertController.addAction(saveAction)
        alertController.addAction(cancelAction)
        
        // Finally, present the dialog box
        present(alertController, animated: true, completion: nil)
    }
    
    /// Plays back the loaded voice note.  This method assumes that the `voiceNoteToPlay` attribute has already been loaded with an appropriate audio player.
    @objc func readVoiceNote() {
        if let voiceNoteToPlay = self.voiceNoteToPlay {
            do {
                try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                voiceNoteToPlay.volume = 1.0
                voiceNoteToPlay.play()
            } catch let error {
                print("Couldn't play back the voice note", error.localizedDescription)
            }
        }
    }
    
    /// Record a voice note by displaying the RecorderView
    @objc func recordVoiceNote() {
        let popoverContent = RecorderViewController()
        //says that the recorder should dismiss tiself when it is done
        popoverContent.shouldAutoDismiss = true
        popoverContent.delegate = self
        popoverContent.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: popoverContent, action: #selector(popoverContent.doneWithRecording))
        let nav = UINavigationController(rootViewController: popoverContent)
        nav.modalPresentationStyle = .popover
        let popover = nav.popoverPresentationController
        popover?.delegate = self
        popover?.sourceView = self.view
        popover?.sourceRect = CGRect(x: 0, y: UIConstants.settingsAndHelpFrameHeight/2, width: 0,height: 0)
        suppressTrackingWarnings = true
        self.present(nav, animated: true, completion: nil)
    }
    
    /// Show logging disclaimer when user opens app for the first time.
    func showLogAlert() {
        let logAlertVC = UIAlertController(title: NSLocalizedString("Sharing your experience with Clew", comment: "The heading of a pop-up"),
                                           message: NSLocalizedString("Help us improve the app by logging your Clew experience. These logs will not include any images or personal information. You can turn this off in Settings.", comment: "Disclaimer shown to the user when they open the app for the first time"),
                                           preferredStyle: .alert)
        logAlertVC.addAction(UIAlertAction(title: NSLocalizedString("Ok", comment: "What the user clicks to acknowledge a message and dismiss pop-up"), style: .default, handler: { action -> Void in
            self.showSafetyAlert()
        }
        ))
        self.present(logAlertVC, animated: true, completion: nil)
    }
    
    /// Show safety disclaimer when user opens app for the first time.
    func showSafetyAlert() {
        let safetyAlertVC = UIAlertController(title: NSLocalizedString("For your safety", comment: "The heading of a pop-up"),
                                              message: NSLocalizedString("While using the app, please be aware of your surroundings. You agree that your use of the App is at your own risk, and it is solely your responsibility to maintain your personal safety. Visit www.clewapp.org for more information on how to use the app.", comment: "Disclaimer shown to the user when they open the app for the first time"),
                                              preferredStyle: .alert)
        safetyAlertVC.addAction(UIAlertAction(title: NSLocalizedString("Ok", comment: "What the user clicks to acknowledge a message and dismiss pop-up"), style: .default, handler: nil))
        self.present(safetyAlertVC, animated: true, completion: nil)
    }
    
    /// Configure Settings Bundle
    func createSettingsBundle() {
        registerSettingsBundle()
        updateDisplayFromDefaults()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification,
                                               object: nil)
    }
    
    /// Register settings bundle
    func registerSettingsBundle(){
        let appDefaults = ["crumbColor": 0, "hapticFeedback": true, "sendLogs": true, "voiceFeedback": true, "soundFeedback": true, "units": 0, "timerLength":5] as [String : Any]
        UserDefaults.standard.register(defaults: appDefaults)
    }

    /// Respond to update events to the `UserDefaults` object (the settings of the app).
    func updateDisplayFromDefaults(){
        let defaults = UserDefaults.standard
        
        defaultUnit = defaults.integer(forKey: "units")
        defaultColor = defaults.integer(forKey: "crumbColor")
        soundFeedback = defaults.bool(forKey: "soundFeedback")
        voiceFeedback = defaults.bool(forKey: "voiceFeedback")
        hapticFeedback = defaults.bool(forKey: "hapticFeedback")
        sendLogs = defaults.bool(forKey: "sendLogs")
        timerLength = defaults.integer(forKey: "timerLength")
    }
    
    /// Handles updates to the app settings.
    @objc func defaultsChanged(){
        updateDisplayFromDefaults()
    }
    
    /// Create a new ARSession.
    func createARSession() {
        configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.isAutoFocusEnabled = false
        sceneView.debugOptions = .showWorldOrigin
        sceneView.session.run(configuration)
        sceneView.delegate = self
    }
    
    /// Handle the user clicking the confirm alignment to a saved landmark.  Depending on the app state, the behavior of this function will differ (e.g., if the route is being resumed versus reloaded)
    @objc func confirmAlignment() {
        if case .startingPauseProcedure = state {
            state = .pauseWaitingPeriod
        } else if case .startingResumeProcedure = state {
            resumeTracking()
        } else if case .readyForFinalResumeAlignment = state {
            resumeTracking()
        }
    }
    
    /// Play audio feedback and system sound.  This is used currently when the user is facing the appropriate direction along the route.
    @objc func playSound() {
        feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
        feedbackGenerator?.impactOccurred()
        feedbackGenerator = nil
        playSystemSound(id: 1103)
    }
    
    /// Play the specified system sound.  If the system sound has been preloaded as an audio player, then play using the AVAudioSession.  If there is no corresponding player, use the `AudioServicesPlaySystemSound` function.
    ///
    /// - Parameter id: the id of the system sound to play
    func playSystemSound(id: Int) {
        do {
            try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            guard let player = audioPlayers[id] else {
                // fallback on system sounds
                AudioServicesPlaySystemSound(SystemSoundID(id))
                return
            }
            
            player.play()
        } catch let error {
            print(error.localizedDescription)
        }
    }
    
    /// Adds double tap gesture to the sceneView to handle the anounce direction button (TODO: I'm not sure exactly what this does at the moment and how it differs from the button itself)
    func addGestures() {
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(announceDirectionHelp))
        tapGestureRecognizer.numberOfTapsRequired = 2
        self.view.addGestureRecognizer(tapGestureRecognizer)
    }

    /// display RECORD PATH button/hide all other views
    @objc func showRecordPathButton(announceArrival: Bool) {
        add(recordPathController)
        /// handling main screen transitions outside of the first load
        /// add the view of the child to the view of the parent
        routeRatingController.remove()
        stopNavigationController.remove()
        
        rootContainerView.getDirectionButton.isHidden = true
        // the options button is hidden if the route rating shows up
        rootContainerView.settingsButton.isHidden = false
        rootContainerView.helpButton.isHidden = false
        rootContainerView.feedbackButton.isHidden = false
        rootContainerView.homeButton.isHidden = true

        if announceArrival {
            delayTransition(announcement: NSLocalizedString("You've arrived.", comment: "You have arrived at your destination."))
        } else {
            delayTransition()
        }
    }
    
    /// Called when the UI of the view changes dramatically (e.g., if a different subview is displayed).  The optional `announcement` input is will be spoken 2 seconds after the transition occurs.  The delay is necessary to prevent the accessibility notification for screen changed to cut off the announcement.
    ///
    /// - Parameter announcement: the announcement to read after a 2 second delay
    func delayTransition(announcement: String? = nil, initialFocus: UIView? = nil) {
        // this notification currently cuts off the announcement of the button that was just pressed
        UIAccessibility.post(notification: UIAccessibility.Notification.screenChanged, argument: initialFocus)
        if let announcement = announcement {
            if UIAccessibility.isVoiceOverRunning {
                Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { timer in
                    self.announce(announcement: announcement)
                }
            } else {
                announce(announcement: announcement)
            }
        }
    }
    
    /// Display stop recording view/hide all other views
    @objc func showStopRecordingButton() {
        rootContainerView.homeButton.isHidden = false // home button here
        recordPathController.remove()
        recordPathController.view.isAccessibilityElement = false
        add(stopRecordingController)
        delayTransition(announcement: NSLocalizedString("Hold vertically with the rear camera facing forward.", comment: "Hold the phone vertically with the rear camera facing forward."))
    }
    
    /// Display start navigation view/hide all other views
    @objc func showStartNavigationButton(allowPause: Bool) {
        rootContainerView.homeButton.isHidden = false // home button here
        resumeTrackingController.remove()
        resumeTrackingConfirmController.remove()
        stopRecordingController.remove()
        add(startNavigationController)
        startNavigationController.pauseButton.isHidden = !allowPause
        startNavigationController.fillerSpace.isHidden = !allowPause
        startNavigationController.stackView.layoutIfNeeded()
        UIAccessibility.post(notification: UIAccessibility.Notification.screenChanged, argument: startNavigationController.startNavigationButton)
    }

    /// Display the pause tracking view/hide all other views
    func showPauseTrackingButton() throws {
        rootContainerView.homeButton.isHidden = false // home button here
        recordPathController.remove()
        startNavigationController.remove()
        add(pauseTrackingController)
        
        delayTransition()
    }
    
    /// Display the resume tracking view/hide all other views
    @objc func showResumeTrackingButton() {
        rootContainerView.homeButton.isHidden = false // no home button here
        pauseTrackingController.remove()
        add(resumeTrackingController)
        UIApplication.shared.keyWindow!.bringSubviewToFront(rootContainerView)
        delayTransition()
    }
    
    /// Display the resume tracking confirm view/hide all other views.
    func showResumeTrackingConfirmButton(route: SavedRoute, navigateStartToEnd: Bool) {
        rootContainerView.homeButton.isHidden = false
        resumeTrackingController.remove()
        add(resumeTrackingConfirmController)
        resumeTrackingConfirmController.view.mainText?.text = ""
        voiceNoteToPlay = nil
        if navigateStartToEnd {
            if let landmarkInformation = route.beginRouteLandmark.information as String? {
                let infoString = "\n\n" + "The landmark information you entered is: " + landmarkInformation + "\n\n"
                resumeTrackingConfirmController.landmarkLabel.text = infoString

            }
            if let beginRouteLandmarkVoiceNote = route.beginRouteLandmark.voiceNote {
                let voiceNoteToPlayURL = beginRouteLandmarkVoiceNote.documentURL
                do {
                    let data = try Data(contentsOf: voiceNoteToPlayURL)
                    voiceNoteToPlay = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.caf.rawValue)
                    voiceNoteToPlay?.prepareToPlay()
                } catch {}
            }
        } else {
            if let landmarkInformation = route.endRouteLandmark.information as String? {
                let infoString = "\n\n" + "The landmark information you entered is: " + landmarkInformation + "\n\n"
                resumeTrackingConfirmController.landmarkLabel.text = infoString
            }
            if let endRouteLandmarkVoiceNote = route.endRouteLandmark.voiceNote {
                let voiceNoteToPlayURL = endRouteLandmarkVoiceNote.documentURL
                do {
                    let data = try Data(contentsOf: voiceNoteToPlayURL)
                    voiceNoteToPlay = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.caf.rawValue)
                    voiceNoteToPlay?.prepareToPlay()
                } catch {}
            }
        }
        resumeTrackingConfirmController.readVoiceNoteButton?.isHidden = voiceNoteToPlay == nil
        let waitingPeriod = ViewController.alignmentWaitingPeriod
        resumeTrackingConfirmController.view.mainText?.text?.append(String.localizedStringWithFormat(NSLocalizedString("Hold your device flat with the screen facing up. Press the top (short) edge flush against the same vertical surface that you used to create the landmark.  When you are ready, activate the align button to start the alignment countdown that will complete the procedure. Do not move the device until the phone provides confirmation via a vibration or sound cue.", comment: "Informative mssage that appears to the user."), waitingPeriod))
        delayTransition()
    }
    
    /// display stop navigation view/hide all other views
    @objc func showStopNavigationButton() {
        rootContainerView.homeButton.isHidden = false
        rootContainerView.getDirectionButton.isHidden = false
        startNavigationController.remove()
        add(stopNavigationController)
        
        // this does not auto update, so don't use it as an accessibility element
        delayTransition()
    }
    
    /// display route rating view/hide all other views
    @objc func showRouteRating(announceArrival: Bool) {
        rootContainerView.getDirectionButton.isHidden = true
        rootContainerView.homeButton.isHidden = true
        stopNavigationController.remove()
        add(routeRatingController)
        if announceArrival {
            routeRatingController.view.mainText?.text = NSLocalizedString("You've arrived. Please rate your service.", comment: "Announce to the user that they have arrived at their destination and ask user to rate their experience.")
        } else {
            routeRatingController.view.mainText?.text = NSLocalizedString("Please rate your service.", comment: "Ask user to rate their experience.")
        }
        
        feedbackGenerator = nil
        waypointFeedbackGenerator = nil
        delayTransition()
    }
    
    /*
     *
     */
    
    /// Announce the direction (both in text and using speech if appropriate).  The function will automatically use the appropriate units based on settings to convert `distance` from meters to the appropriate unit.
    ///
    /// - Parameters:
    ///   - description: the direction text to display (e.g., may include the direction to turn)
    ///   - distance: the distance (expressed in meters)
    ///   - displayDistance: a Boolean that indicates whether to display the distance (true means display distance)
    func updateDirectionText(_ description: String, distance: Float, displayDistance: Bool) {
        let distanceToDisplay = roundToTenths(distance * unitConversionFactor[defaultUnit]!)
        var altText = description
        if (displayDistance) {
            if defaultUnit == 0 || distanceToDisplay >= 10 {
                // don't use fractional feet or for higher numbers of meters (round instead)
                // Related to higher number of meters, there is a somewhat strange behavior in VoiceOver where numbers greater than 10 will be read as, for instance, 11 dot 4 meters (instead of 11 point 4 meters).
                altText += " for \(Int(distanceToDisplay))" + unitText[defaultUnit]!
            } else {
                altText += " for \(distanceToDisplay)" + unitText[defaultUnit]!
            }
        }
        if case .navigatingRoute = state {
            logger.logSpeech(utterance: altText)
        }
        announce(announcement: altText)
    }
    
    // MARK: - BreadCrumbs
    
    /// AR Session Configuration
    var configuration: ARWorldTrackingConfiguration!
    
    /// MARK: - Clew internal datastructures
    
    /// list of crumbs dropped when recording pth
    var crumbs: [LocationInfo]!
    
    /// list of crumbs dropped when following path
    var followCrumbs: [LocationInfo] {
        guard let anchors = sceneView.session.currentFrame?.anchors else {
            return []
        }
        return anchors.compactMap({$0.name != nil && $0.name! == "followCrumb" ? LocationInfo(transform: $0.transform) : nil })
    }
    
    /// list of keypoints calculated after path completion
    var keypoints: [KeypointInfo]!
    
    /// stores the keypoints that have been checked off along the route thus far
    var checkedOffKeypoints: [KeypointInfo]!
    
    /// SCNNode of the next keypoint
    var keypointNode: SCNNode!
    
    /// previous keypoint location - originally set to current location
    var prevKeypointPosition: LocationInfo!

    /// Interface for logging data about the session and the path
    var logger = PathLogger()
    
    /// Interface for matching points to a saved route
    var pathMatcher = PathMatcher()
    
    // MARK: - Timers for background functions
    
    /// times the recording of path crumbs
    var droppingCrumbs: Timer?
    
    /// times the checking of the path navigation process (e.g., have we reached a waypoint)
    var followingCrumbs: Timer?
    
    /// times the generation of haptic feedback
    var hapticTimer: Timer?
    
    /// times the generation of snap to route
    var snapToRouteTimer: Timer?
    
    /// times when an announcement should be removed.  These announcements are displayed on the `announcementText` label.
    var announcementRemovalTimer: Timer?
    
    /// times when the heading offset should be recalculated.  The ability to use the heading offset is currently not exposed to the user.
    var updateHeadingOffsetTimer: Timer?
    
    /// Navigation class and state
    var nav = Navigation()
    
    // MARK: - Haptic generators
    
    /// The haptic feedback generator to use when facing towards the keypoint
    var feedbackGenerator : UIImpactFeedbackGenerator? = nil
    /// The haptic feedback generator to use when a keypoint is reached
    var waypointFeedbackGenerator: UINotificationFeedbackGenerator? = nil
    /// The time of last haptic feedback
    var feedbackTimer: Date!
    /// The delay between haptic feedback pulses in seconds
    static let FEEDBACKDELAY = 0.4
    
    // MARK: - Settings bundle configuration
    
    /// the bundle configuration has 0 as feet and 1 as meters
    let unit = [0: "ft", 1: "m"]
    
    /// the text to display for each possible unit
    let unitText = [0: " feet", 1: " meters"]
    
    /// the converstion factor to apply to distances as reported by ARKit so that they are expressed in the user's chosen distance units.  ARKit's unit of distance is meters.
    let unitConversionFactor = [0: Float(100.0/2.54/12.0), 1: Float(1.0)]

    /// the selected default unit index (this index cross-references `unit`, `unitText`, and `unitConversionFactor`
    var defaultUnit: Int!
    
    /// the color of the waypoints.  0 is red, 1 is green, 2 is blue, and 3 is random
    var defaultColor: Int!
    
    /// true if sound feedback should be generated when the user is facing the next waypoint, false otherwise
    var soundFeedback: Bool!
    
    /// true if the app should announce directions via text to speech, false otherwise
    var voiceFeedback: Bool!
    
    /// true if haptic feedback should be generated when the user is facing the next waypoint, false otherwise
    var hapticFeedback: Bool!

    /// true if we should prompt the user to rate route navigation and then send log data to the cloud
    var sendLogs: Bool!
    
    /// The length of time that the timer will run for
    var timerLength: Int!

    /// This keeps track of the paused transform while the current session is being realigned to the saved route
    var pausedLandmark : RouteLandmark?
    
    /// the landmark to use to mark the beginning of the route currently being recorded
    var beginRouteLandmark = RouteLandmark()
    
    /// the landmark to use to mark the end of the route currently being recorded
    var endRouteLandmark = RouteLandmark()

    /// the name of the route being recorded
    var routeName: NSString?

    /// the route just recorded.  This is useful for when the user resumes a route that wasn't saved.
    var justTraveledRoute: SavedRoute?
    
    /// this is a generically typed placeholder for the justUsedMap computed property.  This is needed due to the fact that @available cannot be used for stored attributes
    private var justUsedMapAsAny: Any?

    /// the most recently used map.  This helps us determine whether a route the user is attempting to load requires alignment.  If we have already aligned within a particular map, we can skip the alignment procedure.
    @available(iOS 12.0, *)
    var justUsedMap : ARWorldMap? {
        get {
            return justUsedMapAsAny as! ARWorldMap?
        }
        set (newValue) {
            justUsedMapAsAny = newValue
        }
    }
    
    /// DirectionText based on hapic/voice settings
    var Directions: Dictionary<Int, String> {
        if (hapticFeedback) {
            return HapticDirections
        } else {
            return ClockDirections
        }
    }
    
    /// handles the user pressing the record path button.
    @objc func recordPath() {
        state = .recordingRoute
    }
    
    /// Gets a transform suitable for soft alignment.  The transform that is returned will be based on  `firstTransformToUse` if `secondTransformToUse` is not specified or if the translation between the two is less than `softAlignmentSegmentLengthThreshold`.  The transform returned from this function is preleveled use in the realignment step (i.e., no leveling should be performed during the realignemnt process).
    ///
    /// - Parameters:
    ///   - firstTransformToUse: the first transform to use for soft alignment (this should be the first or last keypoint depending on direction)
    ///   - secondTransformToUse: the second transform to use for soft alignment (this should be the second or second to- last-keypoint if one exists)
    ///   - isReversed: true if the path is reversed
    /// - Returns: a leveled transform suitable for alignment
    func getSoftAlignment(firstTransformToUse: simd_float4x4, secondTransformToUse: simd_float4x4?, isReversed: Bool)->simd_float4x4 {
        guard let secondTransformToUse = secondTransformToUse else {
            if isReversed {
                return firstTransformToUse.level.flipOrientationAboutYAxis
            } else {
                return firstTransformToUse.level
            }
        }

        if simd_length(firstTransformToUse.level.columns.3 - secondTransformToUse.level.columns.3) < Float(softAlignmentSegmentLengthThreshold) {
            if isReversed {
                return firstTransformToUse.level.flipOrientationAboutYAxis
            } else {
                return firstTransformToUse.level
            }
        }
        let alignmentYaw = atan2(firstTransformToUse.x - secondTransformToUse.x, firstTransformToUse.z - secondTransformToUse.z)
        var alignmentTransform = simd_float4x4.makeRotate(radians: alignmentYaw, 0, 1, 0)
        alignmentTransform.columns.3 = firstTransformToUse.columns.3
        return alignmentTransform
    }
    
    /// handles the user pressing the stop recording button.
    ///
    /// - Parameter sender: the button that generated the event
    @objc func stopRecording(_ sender: UIButton) {
        // fill out landmarks with the first and last crumb
        let p = PathFinder(crumbs: crumbs, hapticFeedback: hapticFeedback, voiceFeedback: voiceFeedback)
        let keypoints = p.keypoints
        if beginRouteLandmark.transform == nil, let firstKeypointTransform = keypoints.first?.location.transform {
            beginRouteLandmark.information = "Route start"
            var secondKeypointTransform: simd_float4x4? = nil

            if keypoints.count > 1 {
                secondKeypointTransform = keypoints[1].location.transform
            }
            
            beginRouteLandmark.transform = getSoftAlignment(firstTransformToUse: firstKeypointTransform, secondTransformToUse: secondKeypointTransform, isReversed: false)
            beginRouteLandmark.isSoftAlignment = true
        }
        
        if endRouteLandmark.transform == nil, let lastKeypointTransform = keypoints.last?.location.transform {
            endRouteLandmark.information = "Route end"
            var secondToLastKeypointTransform: simd_float4x4? = nil

            if keypoints.count > 1 {
                secondToLastKeypointTransform = keypoints[keypoints.endIndex - 2].location.transform
            }
            
            endRouteLandmark.transform = getSoftAlignment(firstTransformToUse: lastKeypointTransform, secondTransformToUse: secondToLastKeypointTransform, isReversed: true)
            endRouteLandmark.isSoftAlignment = true
        }
        
        if beginRouteLandmark.transform != nil {
            if #available(iOS 12.0, *) {
                sceneView.session.getCurrentWorldMap {
                    worldMap, error in
                    self.getRouteNameAndSaveRouteHelper(mapAsAny: worldMap)
                }
            } else {
                getRouteNameAndSaveRouteHelper(mapAsAny: nil)
            }
        }

        isResumedRoute = false
        state = .readyToNavigateOrPause(allowPause: true)
    }
    
    /// handles the user pressing the start navigation button.
    ///
    /// - Parameter sender: the button that generated the event
    @objc func startNavigation(_ sender: UIButton) {
        state = .navigatingRoute
    }
    
    /// This helper function will restart the tracking session if a relocalization was in progress but did not succeed.  This is useful in the case when you want to allow for the recording of a new route and don't want to have the possibility achieving relocalization halfway through recording the route.
    func restartSessionIfFailedToRelocalize() {
        if attemptingRelocalization {
            if !suppressTrackingWarnings {
                announce(announcement: NSLocalizedString("Could not match environment to the saved route. Starting new tracking session.", comment: "Current environment does not match up with the environment in previously saved route. About to start a new tracking session."))
            }
            if #available(iOS 12.0, *) {
                configuration.initialWorldMap = nil
            }
            sceneView.session.run(configuration, options: [.removeExistingAnchors, .resetTracking])
            attemptingRelocalization = false
        }
    }
    
    /// handles the user pressing the stop navigation button.
    ///
    /// - Parameter sender: the button that generated the event
    @objc func stopNavigation(_ sender: UIButton) {
        // stop navigation
        followingCrumbs?.invalidate()
        hapticTimer?.invalidate()
        snapToRouteTimer?.invalidate()
        
        feedbackGenerator = nil
        waypointFeedbackGenerator = nil

        restartSessionIfFailedToRelocalize()
        
        // erase nearest keypoint
        keypointNode.removeFromParentNode()
        
        if(sendLogs) {
            state = .ratingRoute(announceArrival: false)
        } else {
            state = .mainScreen(announceArrival: false)
            logger.resetStateSequenceLog()
        }
    }
    
    /// The handler for the snap to route button.
    ///
    /// - Parameter send: the sender of the button pressed event
    @objc func snapToRoute(_ send: UIButton) {
        var keypointsToUse: [KeypointInfo] = checkedOffKeypoints
        // always append the next point to check off
        if let firstKeypoint = keypoints.first {
            keypointsToUse.append(firstKeypoint)
        }

        let optimalTransform = pathMatcher.match(points: followCrumbs, toPath: keypointsToUse)
        sceneView.session.setWorldOrigin(relativeTransform: optimalTransform.inverse)
    }
    
    /// handles the user pressing the pause button
    @objc func startPauseProcedure() {
        creatingRouteLandmark = false
        state = .startingPauseProcedure
    }
    
    /// handles the user pressing the landmark button
    @objc func startCreateLandmarkProcedure() {
        rootContainerView.homeButton.isHidden = false
//        backButton.isHidden = true
        creatingRouteLandmark = true
        state = .startingPauseProcedure
    }
    
    /// this is called after the alignment countdown timer finishes in order to complete the pause tracking procedure
    @objc func pauseTracking() {
        // pause AR pose tracking
        state = .completingPauseProcedure
    }
    
    /// this is called when the user has confirmed the alignment and is the alignment countdown should begin.  Once the alignment countdown has finished, the alignment will be performed and the app will move to the ready to navigate view.
    func resumeTracking() {
        // resume pose tracking with existing ARSessionConfiguration
        guard let pausedLandmark = pausedLandmark else {
            return
        }
        hideAllViewsHelper()
        let deadline: DispatchTime
        
        if !pausedLandmark.isSoftAlignment {
            deadline = .now() + .seconds(ViewController.alignmentWaitingPeriod)
        } else {
            deadline = .now()
        }
        
        pauseTrackingController.remove()
        rootContainerView.countdownTimer.isHidden = false
        rootContainerView.countdownTimer.start(beginingValue: ViewController.alignmentWaitingPeriod, interval: 1)
        delayTransition()
        DispatchQueue.main.asyncAfter(deadline: deadline) {
            self.rootContainerView.countdownTimer.isHidden = true

            // The first check is necessary in case the phone relocalizes before this code executes
            if case .readyForFinalResumeAlignment = self.state, let alignTransform = self.pausedLandmark?.transform, let camera = self.sceneView.session.currentFrame?.camera {
            // yaw can be determined by projecting the camera's z-axis into the ground plane and using arc tangent (note: the camera coordinate conventions of ARKit https://developer.apple.com/documentation/arkit/arsessionconfiguration/worldalignment/camera
                let leveledCameraPose = camera.transform.level
                
                var leveledAlignPose = alignTransform
                if !pausedLandmark.isSoftAlignment {
                    // soft alignments are preleveled, so we only level if we are doing hard alignment
                    leveledAlignPose = alignTransform.level
                }
                
                let relativeTransform = leveledCameraPose * leveledAlignPose.inverse
                self.sceneView.session.setWorldOrigin(relativeTransform: relativeTransform)
                Timer.scheduledTimer(timeInterval: 1, target: self, selector: (#selector(self.playSound)), userInfo: nil, repeats: false)
                self.isResumedRoute = true
                self.state = .readyToNavigateOrPause(allowPause: false)
            }
        }
    }
    
    /// handles the user pressing the resume tracking confirmation button.
    @objc func confirmResumeTracking() {
        if let route = justTraveledRoute {
            state = .startingResumeProcedure(route: route, mapAsAny: justUsedMapAsAny, navigateStartToEnd: false)
        }
    }
    
    // MARK: - Logging
    
    /// send log data for an successful route navigation (thumbs up)
    @objc func sendLogData() {
        // send success log data to Firebase
        logger.compileLogData(false)
        logger.resetStateSequenceLog()
        state = .mainScreen(announceArrival: false)
    }
    
    /// send log data for an unsuccessful route navigation (thumbs down)
    @objc func sendDebugLogData() {
        // send debug log data to Firebase
        logger.compileLogData(true)
        logger.resetStateSequenceLog()
        state = .mainScreen(announceArrival: false)
    }
    
    /// drop a crumb during path recording
    @objc func dropCrumb() {
        // drop waypoint markers to record path
        // TODO: gracefully handle error
        let curLocation = getRealCoordinates(record: true)!.location
        crumbs.append(curLocation)
    }
    
    /// checks to see if user is on the right path during navigation.
    @objc func followCrumb() {
        guard let curLocation = getRealCoordinates(record: true) else {
            // TODO: might want to indicate that something is wrong to the user
            return
        }
        let minDistance = followCrumbs.map({sqrt(pow($0.x - curLocation.location.x, 2) + pow($0.y - curLocation.location.y, 2) + pow($0.z - curLocation.location.z, 2)) }).min()
        // always allow this for now if minDistance == nil || minDistance! > 0.2 {
        sceneView.session.add(anchor: ARAnchor(name: "followCrumb", transform: curLocation.location.transform))
       // }
        var directionToNextKeypoint = getDirectionToNextKeypoint(currentLocation: curLocation)
        
        if (directionToNextKeypoint.targetState == PositionState.atTarget) {
            if (keypoints.count > 1) {
                // arrived at keypoint
                // send haptic/sonic feedback
                waypointFeedbackGenerator?.notificationOccurred(.success)
                if (soundFeedback) { playSystemSound(id: 1016) }
                
                // remove current visited keypont from keypoint list
                prevKeypointPosition = keypoints[0].location
                checkedOffKeypoints.append(keypoints[0])
                keypoints.remove(at: 0)
                
                // erase current keypoint and render next keypoint node
                keypointNode.removeFromParentNode()
                renderKeypoint(keypoints[0].location)
                
                // update directions to next keypoint
                directionToNextKeypoint = getDirectionToNextKeypoint(currentLocation: curLocation)
                setDirectionText(currentLocation: curLocation.location, direction: directionToNextKeypoint, displayDistance: false)
            } else {
                // arrived at final keypoint
                // send haptic/sonic feedback
                waypointFeedbackGenerator?.notificationOccurred(.success)
                if (soundFeedback) { playSystemSound(id: 1016) }
                
                // erase current keypoint node
                keypointNode.removeFromParentNode()
                
                followingCrumbs?.invalidate()
                hapticTimer?.invalidate()
                snapToRouteTimer?.invalidate()
                
                restartSessionIfFailedToRelocalize()
                
                // update text and stop navigation
                if(sendLogs) {
                    state = .ratingRoute(announceArrival: true)
                } else {
                    state = .mainScreen(announceArrival: true)
                    logger.resetStateSequenceLog()
                }
            }
        }
    }
    
    /// Calculate the offset between the phone's heading (either its z-axis or y-axis projected into the floor plane) and the user's direction of travel.  This offset allows us to give directions based on the user's movement rather than the direction of the phone.
    ///
    /// - Returns: the offset
    func getHeadingOffset() -> Float? {
        guard let startHeading = headingRingBuffer.get(0), let endHeading = headingRingBuffer.get(-1), let startPosition = locationRingBuffer.get(0), let endPosition = locationRingBuffer.get(-1) else {
            return nil
        }
        // make sure the path was far enough in the ground plane
        if sqrt(pow(startPosition.x - endPosition.x, 2) + pow(startPosition.z - endPosition.z, 2)) < requiredDistance {
            return nil
        }
        
        // make sure that the headings are all close to the start and end headings
        for i in 0..<headingRingBuffer.capacity {
            guard let currAngle = headingRingBuffer.get(i) else {
                return nil
            }
            if abs(nav.getAngleDiff(angle1: currAngle, angle2: startHeading)) > angleDeviationThreshold || abs(nav.getAngleDiff(angle1: currAngle, angle2: endHeading)) > angleDeviationThreshold {
                // the phone turned too much during the last second
                return nil
            }
        }
        // make sure the path is straight
        let u = (endPosition - startPosition).normalized()
        
        for i in 0..<locationRingBuffer.capacity {
            let d = locationRingBuffer.get(i)! - startPosition
            let orthogonalVector = d - u*Scalar(d.dot(u))
            if orthogonalVector.length > linearDeviationThreshold {
                // the phone didn't move in a straight path during the last second
                return nil
            }
        }
        let movementAngle = atan2f((startPosition.x - endPosition.x), (startPosition.z - endPosition.z))
        
        let potentialOffset = nav.getAngleDiff(angle1: movementAngle, angle2: nav.averageAngle(a: startHeading, b: endHeading))
        // check if the user is potentially moving backwards.  We only try to correct for this if the potentialOffset is in the range [0.75 pi, 1.25 pi]
        if cos(potentialOffset) < -sqrt(2)/2 {
            return potentialOffset - Float.pi
        }
        return potentialOffset
    }
  
    /// update the offset between direction of travel and the orientation of the phone.  This supports a feature which allows the user to navigate with the phone pointed in a direction other than the direction of travel.  The feature cannot be accessed by users in the app store version.
    @objc func updateHeadingOffset() {
        // send haptic feedback depending on correct device
        guard let curLocation = getRealCoordinates(record: false) else {
            return
        }
        // NOTE: currPhoneHeading is not the same as curLocation.location.yaw
        let currPhoneHeading = nav.getPhoneHeadingYaw(currentLocation: curLocation)
        headingRingBuffer.insert(currPhoneHeading)
        locationRingBuffer.insert(Vector3(curLocation.location.x, curLocation.location.y, curLocation.location.z))
        
        if let newOffset = getHeadingOffset() {
            if adjustOffset {
                nav.headingOffset = newOffset
            }
        }
    }
    
    /// Compute the heading vector of the phone.  When the phone is mostly upright, this is just the project of the negative z-axis of the device into the x-z plane.  When the phone is mostly flat, this is the y-axis of the phone projected into the x-z plane after the pitch and roll of the phone are undone.  The case where the phone is mostly flat is used primarily for alignment to and creation of landmarks.
    ///
    /// - Parameter transform: the position and orientation of the phone
    /// - Returns: the heading vector as a 4 dimensional vector (y-component and w-component will necessarily be 0)
    static func getProjectedHeading(_ transform: simd_float4x4) -> simd_float4 {
        if abs(transform.columns.2.y) < abs(transform.columns.0.y) {
            return -simd_make_float4(transform.columns.2.x, 0, transform.columns.2.z, 0)
        } else {
            // this is a slightly different notion of yaw when the phone is rolled.  This works better for alignment to saved transforms.  I'm not sure whether it is better when navigating a route.
            // This calculates the angle necessary to align the phone's x-axis (long axis) so that it has a 0 component in the y-direction
            let pitchAngle = atan2f(-transform.columns.0.y, transform.columns.2.y)
            let depitchedTransform = transform.rotate(radians: -pitchAngle, 0, 1, 0)
            return -simd_make_float4(depitchedTransform.columns.0.x, 0, depitchedTransform.columns.0.z, 0)
        }
        
    }
    
    /// this gets the yaw of the phone using the heading vector returned by `getProjectedHeading`.
    static func getYawHelper(_ transform: simd_float4x4) -> Float {
        let projectedHeading = getProjectedHeading(transform)
        return atan2f(-projectedHeading.x, -projectedHeading.z)
    }
    
    // MARK: - Render directions
    
    /// send haptic feedback if the device is pointing towards the next keypoint.
    @objc func getHapticFeedback() {
        updateHeadingOffset()
        guard let curLocation = getRealCoordinates(record: false) else {
            // TODO: might want to indicate that something is wrong to the user
            return
        }
        let directionToNextKeypoint = getDirectionToNextKeypoint(currentLocation: curLocation)
        let coneWidth: Float!
        if strictHaptic {
            coneWidth = Float.pi/12
        } else {
            coneWidth = Float.pi/6
        }
        
        // use a stricter criteria than 12 o'clock for providing haptic feedback
        if abs(directionToNextKeypoint.angleDiff) < coneWidth {
            let timeInterval = feedbackTimer.timeIntervalSinceNow
            if(-timeInterval > ViewController.FEEDBACKDELAY) {
                // wait until desired time interval before sending another feedback
                if (hapticFeedback) { feedbackGenerator?.impactOccurred() }
                if (soundFeedback) { playSystemSound(id: 1103) }
                feedbackTimer = Date()
            }
        }
    }
    
    /// Communicates a message to the user via speech.  If VoiceOver is active, then VoiceOver is used to communicate the announcement, otherwise we use the AVSpeechEngine
    ///
    /// - Parameter announcement: the text to read to the user
    func announce(announcement: String) {
        if let currentAnnouncement = currentAnnouncement {
            // don't interrupt current announcement, but if there is something new to say put it on the queue to say next.  Note that adding it to the queue in this fashion could result in the next queued announcement being preempted
            if currentAnnouncement != announcement {
                nextAnnouncement = announcement
            }
            return
        }
        
        rootContainerView.announcementText.isHidden = false
        rootContainerView.announcementText.text = announcement
        announcementRemovalTimer?.invalidate()
        announcementRemovalTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { timer in
            self.rootContainerView.announcementText.isHidden = true
        }
        if UIAccessibility.isVoiceOverRunning {
            // use the VoiceOver API instead of text to speech
            currentAnnouncement = announcement
            UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: announcement)
        } else if voiceFeedback {
            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setCategory(AVAudioSession.Category.playback)
                try audioSession.setActive(true)
                let utterance = AVSpeechUtterance(string: announcement)
                utterance.rate = 0.6
                currentAnnouncement = announcement
                synth.speak(utterance)
            } catch {
                print("Unexpeced error announcing something using AVSpeechEngine!")
            }
        }
    }
    
    /// Get direction to next keypoint based on the current location
    ///
    /// - Parameter currentLocation: the current location of the device
    /// - Returns: the direction to the next keypoint with the distance rounded to the nearest tenth of a meter
    func getDirectionToNextKeypoint(currentLocation: CurrentCoordinateInfo) -> DirectionInfo {
        // returns direction to next keypoint from current location
        var dir = nav.getDirections(currentLocation: currentLocation, nextKeypoint: keypoints[0])
        dir.distance = roundToTenths(dir.distance)
        return dir
    }
    
    /// Called when the "get directions" button is pressed.  The announcement is made with a 0.5 second delay to allow the button name to be announced.
    @objc func announceDirectionHelpPressed() {
        Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: (#selector(announceDirectionHelp)), userInfo: nil, repeats: false)
    }
    
    // Called when home button is pressed
    // Chooses the states in which the home page alerts pop up
    @objc func homeButtonPressed() {
    // if the state case needs to have a home button alert, send it to the function that creates the relevant alert
        if case .navigatingRoute = self.state {
            homePageNavigationProcesses()
        }
        else if case .recordingRoute = self.state {
            homePageNavigationProcesses()
        }
        else if case .readyToNavigateOrPause = self.state {
            homePageNavigationProcesses()
        }
        else if case .pauseWaitingPeriod = self.state {
            homePageNavigationProcesses()
        }
        else if case .startingPauseProcedure = self.state {
            homePageNavigationProcesses()
        }
        else if case .completingPauseProcedure = self.state {
            homePageNavigationProcesses()
        }
        else if case .pauseProcedureCompleted = self.state {
            homePageNavigationProcesses()
        }
        else if case .readyForFinalResumeAlignment = self.state {
            homePageNavigationProcesses()
        }
        else if case .startingResumeProcedure = self.state {
            homePageNavigationProcesses()
        }
        else {
            // proceed to home page
            clearState()
            hideAllViewsHelper()
            self.state = .mainScreen(announceArrival: false)
        }
    }
    
    /// Called when the settings button is pressed.  This function will display the settings view (managed by SettingsViewController) as a popover.
    @objc func settingsButtonPressed() {
        let storyBoard: UIStoryboard = UIStoryboard(name: "SettingsAndHelp", bundle: nil)
        let popoverContent = storyBoard.instantiateViewController(withIdentifier: "Settings") as! SettingsViewController
        popoverContent.preferredContentSize = CGSize(width: UIScreen.main.bounds.size.width, height: UIScreen.main.bounds.size.height)
        let nav = UINavigationController(rootViewController: popoverContent)
        nav.modalPresentationStyle = .popover
        let popover = nav.popoverPresentationController
        popover?.delegate = self
        popover?.sourceView = self.view
        popover?.sourceRect = CGRect(x: 0, y: UIConstants.settingsAndHelpFrameHeight/2, width: 0,height: 0)
        
        popoverContent.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: popoverContent, action: #selector(popoverContent.doneWithSettings))

        
        self.present(nav, animated: true, completion: nil)
    }
    
    /// Called when the help button is pressed.  This function will display the help view (managed by HelpViewController) as a popover.
    @objc func helpButtonPressed() {
        let storyBoard: UIStoryboard = UIStoryboard(name: "SettingsAndHelp", bundle: nil)
        let popoverContent = storyBoard.instantiateViewController(withIdentifier: "Help") as! HelpViewController
        popoverContent.preferredContentSize = CGSize(width: UIScreen.main.bounds.size.width, height: UIScreen.main.bounds.size.height)
        let nav = UINavigationController(rootViewController: popoverContent)
        nav.modalPresentationStyle = .popover
        let popover = nav.popoverPresentationController
        popover?.delegate = self
        popover?.sourceView = self.view
        popover?.sourceRect = CGRect(x: 0, y: 0, width: 0, height: 0)
        popoverContent.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: popoverContent, action: #selector(popoverContent.doneWithHelp))
        suppressTrackingWarnings = true
        self.present(nav, animated: true, completion: nil)
    }
    
    /// Called when the Feedback button is pressed.  This function will display the Feedback view (managed by FeedbackViewController) as a popover.
    @objc func feedbackButtonPressed() {
        let storyBoard: UIStoryboard = UIStoryboard(name: "SettingsAndHelp", bundle: nil)
        let popoverContent = storyBoard.instantiateViewController(withIdentifier: "Feedback") as! FeedbackViewController
        popoverContent.preferredContentSize = CGSize(width: UIScreen.main.bounds.size.width, height: UIScreen.main.bounds.size.height)
        let nav = UINavigationController(rootViewController: popoverContent)
        nav.modalPresentationStyle = .popover
        let popover = nav.popoverPresentationController
        popover?.delegate = self
        popover?.sourceView = self.view
        popover?.sourceRect = CGRect(x: 0,
                                     y: UIConstants.settingsAndHelpFrameHeight/2,
                                     width: 0,
                                     height: 0)
        popoverContent.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: popoverContent, action: #selector(popoverContent.closeFeedback))
        suppressTrackingWarnings = true
        self.present(nav, animated: true, completion: nil)
    }
    
    /// Announce directions at any given point to the next keypoint
    @objc func announceDirectionHelp() {
        if case .navigatingRoute = state, let curLocation = getRealCoordinates(record: false) {
            let directionToNextKeypoint = getDirectionToNextKeypoint(currentLocation: curLocation)
            setDirectionText(currentLocation: curLocation.location, direction: directionToNextKeypoint, displayDistance: true)
        }
    }
    
    /// Set the direction text based on the current location and direction info.
    ///
    /// - Parameters:
    ///   - currentLocation: the current location of the device
    ///   - direction: the direction info struct (e.g., as computed by the `Navigation` class)
    ///   - displayDistance: a Boolean that indicates whether the distance to the net keypoint should be displayed (true if it should be displayed, false otherwise)
    func setDirectionText(currentLocation: LocationInfo, direction: DirectionInfo, displayDistance: Bool) {
        // Set direction text for text label and VoiceOver
        let xzNorm = sqrtf(powf(currentLocation.x - keypoints[0].location.x, 2) + powf(currentLocation.z - keypoints[0].location.z, 2))
        let slope = (keypoints[0].location.y - prevKeypointPosition.y) / xzNorm
        var dir = ""
        
        if(slope > 0.3) { // Go upstairs
            if(hapticFeedback) {
                dir += "\(Directions[direction.hapticDirection]!)" + NSLocalizedString(" and proceed upstairs", comment: "Additional directions given to user")
            } else {
                dir += "\(Directions[direction.clockDirection]!)" + NSLocalizedString(" and proceed upstairs", comment: "Additional directions given to user")
            }
            updateDirectionText(dir, distance: 0, displayDistance: false)
        } else if (slope < -0.3) { // Go downstairs
            if(hapticFeedback) {
                dir += "\(Directions[direction.hapticDirection]!) and proceed downstairs"
            } else {
                dir += "\(Directions[direction.clockDirection]!) and proceed downstairs"
            }
            updateDirectionText(dir, distance: direction.distance, displayDistance: false)
        } else { // nromal directions
            if(hapticFeedback) {
                dir += "\(Directions[direction.hapticDirection]!)"
            } else {
                dir += "\(Directions[direction.clockDirection]!)"
            }
            updateDirectionText(dir, distance: direction.distance, displayDistance:  displayDistance)
        }
    }
    
    /// Create the keypoint SCNNode that corresponds to the rotating flashing element that looks like a navigation pin.
    ///
    /// - Parameter location: the location of the keypoint
    func renderKeypoint(_ location: LocationInfo) {
        // render SCNNode of given keypoint
        keypointNode = SCNNode(mdlObject: keypointObject)

        // configure node attributes
        keypointNode.scale = SCNVector3(0.0004, 0.0004, 0.0004)
        keypointNode.geometry?.firstMaterial?.diffuse.contents = UIColor.red
        keypointNode.position = SCNVector3(location.x, location.y - 0.2, location.z)
        keypointNode.rotation = SCNVector4(0, 1, 0, (location.yaw - Float.pi/2))
        
        let bound = SCNVector3(
            x: keypointNode.boundingBox.max.x - keypointNode.boundingBox.min.x,
            y: keypointNode.boundingBox.max.y - keypointNode.boundingBox.min.y,
            z: keypointNode.boundingBox.max.z - keypointNode.boundingBox.min.z)
        keypointNode.pivot = SCNMatrix4MakeTranslation(bound.x / 2, bound.y / 2, bound.z / 2)
        
        let spin = CABasicAnimation(keyPath: "rotation")
        spin.fromValue = NSValue(scnVector4: SCNVector4(x: 0, y: 1, z: 0, w: 0))
        spin.toValue = NSValue(scnVector4: SCNVector4(x: 0, y: 1, z: 0, w: Float(CGFloat(2 * Float.pi))))
        spin.duration = 3
        spin.repeatCount = .infinity
        keypointNode.addAnimation(spin, forKey: "spin around")
        
        // animation - SCNNode flashes red
        let flashRed = SCNAction.customAction(duration: 2) { (node, elapsedTime) -> () in
            let percentage = Float(elapsedTime / 2)
            var color = UIColor.clear
            let power: Float = 2.0
            
            
            if (percentage < 0.5) {
                color = UIColor(red: 1,
                                green: CGFloat(powf(2.0*percentage, power)),
                                blue: CGFloat(powf(2.0*percentage, power)),
                                alpha: 1)
            } else {
                color = UIColor(red: 1,
                                green: CGFloat(powf(2-2.0*percentage, power)),
                                blue: CGFloat(powf(2-2.0*percentage, power)),
                                alpha: 1)
            }
            node.geometry!.firstMaterial!.diffuse.contents = color
        }
        
        // animation - SCNNode flashes green
        let flashGreen = SCNAction.customAction(duration: 2) { (node, elapsedTime) -> () in
            let percentage = Float(elapsedTime / 2)
            var color = UIColor.clear
            let power: Float = 2.0
            
            
            if (percentage < 0.5) {
                color = UIColor(red: CGFloat(powf(2.0*percentage, power)),
                                green: 1,
                                blue: CGFloat(powf(2.0*percentage, power)),
                                alpha: 1)
            } else {
                color = UIColor(red: CGFloat(powf(2-2.0*percentage, power)),
                                green: 1,
                                blue: CGFloat(powf(2-2.0*percentage, power)),
                                alpha: 1)
            }
            node.geometry!.firstMaterial!.diffuse.contents = color
        }
        
        // animation - SCNNode flashes blue
        let flashBlue = SCNAction.customAction(duration: 2) { (node, elapsedTime) -> () in
            let percentage = Float(elapsedTime / 2)
            var color = UIColor.clear
            let power: Float = 2.0
            
            
            if (percentage < 0.5) {
                color = UIColor(red: CGFloat(powf(2.0*percentage, power)),
                                green: CGFloat(powf(2.0*percentage, power)),
                                blue: 1,
                                alpha: 1)
            } else {
                color = UIColor(red: CGFloat(powf(2-2.0*percentage, power)),
                                green: CGFloat(powf(2-2.0*percentage, power)),
                                blue: 1,
                                alpha: 1)
            }
            node.geometry!.firstMaterial!.diffuse.contents = color
        }
        let flashColors = [flashRed, flashGreen, flashBlue]
        
        // set flashing color based on settings bundle configuration
        var changeColor: SCNAction!
        if (defaultColor == 3) {
            changeColor = SCNAction.repeatForever(flashColors[Int(arc4random_uniform(3))])
        } else {
            changeColor = SCNAction.repeatForever(flashColors[defaultColor])
        }
        
        // add keypoint node to view
        keypointNode.runAction(changeColor)
        sceneView.scene.rootNode.addChildNode(keypointNode)
    }
    
    /// Compute the location of the device based on the ARSession.  If the record flag is set to true, record this position in the logs.
    ///
    /// - Parameter record: a Boolean indicating whether to record the computed position (true if it should be computed, false otherwise)
    /// - Returns: the current location as a `CurrentCoordinateInfo` object
    func getRealCoordinates(record: Bool) -> CurrentCoordinateInfo? {
        guard var currTransform = sceneView.session.currentFrame?.camera.transform else {
            return nil
        }

        // returns current location & orientation based on starting origin
        let scn = SCNMatrix4(currTransform)
        let transMatrix = Matrix3([scn.m11, scn.m12, scn.m13,
                                   scn.m21, scn.m22, scn.m23,
                                   scn.m31, scn.m32, scn.m33])
        
        // record location data in debug logs
        if(record) {
            logger.logTransformMatrix(state: state, scn: scn)
        }
        return CurrentCoordinateInfo(LocationInfo(transform: currTransform), transMatrix: transMatrix)
    }
    
    ///Called when there is a change in tracking state.  This is important for both announcing tracking errors to the user and also to triggering some app state transitions.
    ///
    /// - Parameters:
    ///   - session: the AR session associated with the change in tracking state
    ///   - camera: the AR camera associated with the change in tracking state
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        var logString: String? = nil

        switch camera.trackingState {
        case .limited(let reason):
            switch reason {
            case .excessiveMotion:
                logString = "ExcessiveMotion"
                print("Excessive motion")
                if !suppressTrackingWarnings {
                    announce(announcement: NSLocalizedString("Excessive motion.\nTracking performance is degraded.", comment: "Let user know that there is too much movement of their phone and thus the app's ability to track a route has been lowered."))
                    if soundFeedback {
                        playSystemSound(id: 1050)
                    }
                }
            case .insufficientFeatures:
                logString = "InsufficientFeatures"
                print("InsufficientFeatures")
                if !suppressTrackingWarnings {
                    announce(announcement: NSLocalizedString("Insufficient visual features.\nTracking performance is degraded.", comment: "Let user know that their current surroundings do not have enough visual markers and thus the app's ability to track a route has been lowered."))
                    if soundFeedback {
                        playSystemSound(id: 1050)
                    }
                }
            case .initializing:
                // don't log anything
                print("initializing")
            case .relocalizing:
                logString = "Relocalizing"
                print("Relocalizing")
            @unknown default:
                print("An error condition arose that we didn't know about when the app was last compiled")
            }
        case .normal:
            logString = "Normal"
            if #available(iOS 12.0, *), configuration.initialWorldMap != nil, attemptingRelocalization {
                if !suppressTrackingWarnings {
                    announce(announcement: NSLocalizedString("Successfully matched current environment to saved route.", comment: "Let user know that their surroundings match up to the surroundings of a saved route and that they can begin navigating."))
                }
                // We clear out `followCrumbs` as we have no way to update their position relative to the updated world origin.  We could potentially circumvent this if we inserted them as proper SCNNodes
                attemptingRelocalization = false
            } else if case let .limited(reason)? = trackingSessionState {
                if !suppressTrackingWarnings {
                    if reason == .initializing {
                        announce(announcement: NSLocalizedString("Tracking session initialized.", comment: "Let user know that the tracking session has started."))
                    } else {
                        announce(announcement: NSLocalizedString("Tracking performance normal.", comment: "Let user know that the ability to track and record a route is normal."))
                        if soundFeedback {
                            playSystemSound(id: 1025)
                        }
                    }
                }
            }
            if case .readyForFinalResumeAlignment = state, configuration.initialWorldMap != nil {
                // this will cancel any realignment if it hasn't happened yet and go straight to route navigation mode.  This only applies if there an initial map (which would employ relocalization has occurred)
                rootContainerView.countdownTimer.isHidden = true
                isResumedRoute = true
                
                state = .readyToNavigateOrPause(allowPause: false)
            }
            print("normal")
        case .notAvailable:
            logString = "NotAvailable"
            print("notAvailable")
        }
        if let logString = logString {
            if case .recordingRoute = state {
                logger.logTrackingError(isRecordingPhase: true, trackingError: logString)
            } else if case .navigatingRoute = state {
                logger.logTrackingError(isRecordingPhase: false, trackingError: logString)
            }
        }
        // update the tracking state so we can use it in the next call to this function
        trackingSessionState = camera.trackingState
    }
    
    /// this tells the ARSession that when the app is becoming active again, we should try to relocalize to the previous world map (rather than proceding with the tracking session in the normal state even though the coordinate systems are no longer aligned).
    /// TODO: not sure if this is actually what we should be doing.  Perhaps we should cancel any recording or navigation if this happens rather than trying to relocalize
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        return true
    }
    
}

// MARK: - methods for implementing RecorderViewControllerDelegate
extension ViewController: RecorderViewControllerDelegate {
    /// Called when a recording starts (currently nothing is done in this function)
    func didStartRecording() {
    }
    
    /// Called when the user finishes recording a voice note.  This function adds the voice note to the `RouteLandmark` object.
    ///
    /// - Parameter audioFileURL: <#audioFileURL description#>
    func didFinishRecording(audioFileURL: URL) {
        if creatingRouteLandmark {
            // delete the file since we are re-recording it
            if let beginRouteLandmarkVoiceNote = self.beginRouteLandmark.voiceNote {
                do {
                    try FileManager.default.removeItem(at: beginRouteLandmarkVoiceNote.documentURL)
                } catch { }
            }
            beginRouteLandmark.voiceNote = audioFileURL.lastPathComponent as NSString
        } else {
            // delete the file since we are re-recording it
            if let endRouteLandmarkVoiceNote = self.endRouteLandmark.voiceNote {
                do {
                    try FileManager.default.removeItem(at: endRouteLandmarkVoiceNote.documentURL)
                } catch { }
            }
            endRouteLandmark.voiceNote = audioFileURL.lastPathComponent as NSString
        }
    }
}

// MARK: - UIPopoverPresentationControllerDelegate
extension ViewController: UIPopoverPresentationControllerDelegate {
    /// Makes sure that popovers are not modal
    ///
    /// - Parameter controller: the presentation controller
    /// - Returns: whether or not to use modal style
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        return .none
    }
    
    /// Called when a popover is dismissed
    ///
    /// - Parameter popoverPresentationController: the popover presentation controller used to display the popover.  Currently all this does is re-enable tracking warnings if they were previously disabled (e.g., when displaying the help menu).
    func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) {
        // this will only fire when the popover is dismissed by some UI action, not when the dismiss function is called from one's own code (this is why we use a custom notification to deal with the case when we dismiss the popover ourselves
        suppressTrackingWarnings = false
    }
    
    /// Ensures that all popover segues are popovers (note: I don't quite understand when this would *not* be the case)
    ///
    /// - Parameters:
    ///   - segue: the segue
    ///   - sender: the sender who generated this prepare call
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        
        // All popover segues should be popovers even on iPhone.
        if let popoverController = segue.destination.popoverPresentationController, let button = sender as? UIButton {
            popoverController.delegate = self
            popoverController.sourceRect = button.bounds
        }
    }
}
