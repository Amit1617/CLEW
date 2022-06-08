//
//  RootContainerView.swift
//  Clew
//
//  Created by Dieter Brehm on 6/10/19.
//  Copyright © 2019 OccamLab. All rights reserved.
//
// root view used for placement of global, almost always visible ui objects
// and elements

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

/// View for buttons and elements which are, generally, accessible
/// regardless of current app state
class RootContainerView: UIView {

    // MARK: - UIViews for all UI button containers
    
    /// button for getting directions to the next keypoint
    var getDirectionButton: UIButton!
    
    /// button for bringing up the settings menu
    var settingsButton: UIButton!
    
    /// button for bringing up the help menu
    var helpButton: UIButton!

    /// button for going to the main screen
    var homeButton: UIButton!

    /// button for bringing up the feedback menu
    var feedbackButton: UIButton!
    
    /// a banner that displays an announcement in the top quarter of the screen.
    /// This is used for displaying status updates or directions.
    /// This should only be used to display time-sensitive content.
    var announcementText: UILabel!

    /// a timer that counts down during the alignment procedure
    /// (alignment is captured at the end of the time)
    var countdownTimer: SRCountdownTimer!

    /// required for non storyboard UIView
    /// objects
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented.")
    }
    
    /// initializer for view, initializes all subview objects
    /// like buttons
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        // MARK: Settings Button
        settingsButton = UIButton(frame: CGRect(x: UIConstants.buttonFrameWidth/(10/0.5),
                                                y: 10,
                                                width: UIConstants.buttonFrameWidth/7,
                                                height: UIConstants.buttonFrameWidth/7))
        settingsButton.isAccessibilityElement = true
        settingsButton.setTitle("Settings", for: .normal)
        settingsButton.accessibilityLabel = "Settings"
        settingsButton.titleLabel?.font = UIFont.systemFont(ofSize: 24.0)
        settingsButton.setImage(UIImage(named: "settingsGear"), for: .normal)

        
        // MARK: Help Button
        helpButton = UIButton(frame: CGRect(x: UIConstants.buttonFrameWidth/(7/3),
                                            y: UIConstants.yOriginOfSettingsAndHelpButton + 10,
                                            width: UIConstants.buttonFrameWidth/7,
                                            height: UIConstants.buttonFrameWidth/7))
        helpButton.isAccessibilityElement = true
        helpButton.setTitle("Help", for: .normal)
        helpButton.titleLabel?.font = UIFont.systemFont(ofSize: 24.0)
        helpButton.accessibilityLabel = "Help"
        helpButton.setImage(UIImage(named: "HelpButton"), for: .normal)

        // MARK: Home Button
        homeButton = UIButton(frame: CGRect(x: UIConstants.buttonFrameWidth/7,
                                            y: UIConstants.yOriginOfSettingsAndHelpButton + 10,
                                            width: UIConstants.buttonFrameWidth/7,
                                            height: UIConstants.buttonFrameWidth/7))
        homeButton.isAccessibilityElement = true
        homeButton.setTitle("Home Button", for: .normal)
        homeButton.titleLabel?.font = UIFont.systemFont(ofSize: 24.0)
        homeButton.accessibilityLabel = "Clew Home Screen"
        homeButton.setImage(UIImage(named: "homeButton"), for: .normal)
        
        feedbackButton = UIButton(frame: CGRect(x: UIConstants.buttonFrameWidth/(10/8),
                                                y: 10,
                                                width: UIConstants.buttonFrameWidth/7,
                                                height: UIConstants.buttonFrameWidth/7))
        feedbackButton.isAccessibilityElement = true
        feedbackButton.setTitle("Feedback", for: .normal)
        feedbackButton.titleLabel?.font = UIFont.systemFont(ofSize: 24.0)
        feedbackButton.accessibilityLabel = "Feedback"
        feedbackButton.setImage(UIImage(named: "Contact"), for: .normal)


        getDirectionButton = UIButton(frame: CGRect(x: UIConstants.buttonFrameWidth/(7/5),
                                                    y: UIConstants.yOriginOfSettingsAndHelpButton + 10,
                                                    width: UIConstants.buttonFrameWidth/7,
                                                    height: UIConstants.buttonFrameWidth/7))

        getDirectionButton.isAccessibilityElement = true
        getDirectionButton.accessibilityLabel = "Get Directions"
        getDirectionButton.setImage(UIImage(named: "GetDirection"), for: .normal)
        getDirectionButton.isHidden = true

        // MARK: Announcement Text
        announcementText = UILabel(frame: CGRect(x: 0,
                                                 y: UIConstants.yOriginOfAnnouncementFrame,
                                                 width: UIConstants.buttonFrameWidth,
                                                 height: UIConstants.buttonFrameHeight*(1/2)))
        announcementText.textColor = UIColor.white
        announcementText.textAlignment = .center
        announcementText.isAccessibilityElement = false
        announcementText.lineBreakMode = .byWordWrapping
        announcementText.numberOfLines = 2
        announcementText.font = announcementText.font.withSize(20)
        announcementText.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        announcementText.isHidden = true
        
        // MARK: countdown element
        countdownTimer = SRCountdownTimer(frame: CGRect(x: UIConstants.buttonFrameWidth*1/10,
                                                        y: UIConstants.yOriginOfButtonFrame/10,
                                                        width: UIConstants.buttonFrameWidth*8/10,
                                                        height: UIConstants.buttonFrameWidth*8/10))
        countdownTimer.labelFont = UIFont(name: "HelveticaNeue-Light", size: 100)
        countdownTimer.labelTextColor = UIColor.white
        countdownTimer.timerFinishingText = "End"
        countdownTimer.lineWidth = 10
        countdownTimer.lineColor = UIColor.white
        countdownTimer.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        countdownTimer.isHidden = true
        /// hide the timer as an accessibility element
        /// and announce through VoiceOver by posting appropriate notifications
        countdownTimer.accessibilityElementsHidden = true
        
        /// add all sub views
        addSubview(announcementText)
        addSubview(getDirectionButton)
        addSubview(settingsButton)
        addSubview(helpButton)
        addSubview(countdownTimer)
        addSubview(feedbackButton)
        addSubview(homeButton)
    }
}
