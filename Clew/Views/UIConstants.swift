//
//  UIConstants.swift
//  Clew
//
//  Created by Dieter Brehm on 6/12/19.
//  Copyright © 2019 OccamLab. All rights reserved.
//
//  Storage for UI constraints which need to be set globally for
//  multiple views, view controllers, and components of the app.
//


import Foundation

/// A custom enumeration for storing UI constants defined by the phone size.
enum UIConstants {
    // MARK: UI Dimensions defined by inherent UIScreen dimensions
    
    /// Button frame extends the entire width of screen
    static var buttonFrameWidth: CGFloat {
        return UIScreen.main.bounds.size.width
    }
    
    /// Height of button frame
    static var buttonFrameHeight: CGFloat {
        return UIScreen.main.bounds.size.height * (1/5)
    }
    
    /// Height of settings and help buttons
    static var settingsAndHelpFrameHeight: CGFloat {
        return UIScreen.main.bounds.size.height * (1/12)
    }
    
    /// The margin from the settings and help buttons to the bottom of the window
    static var settingsAndHelpMargin: CGFloat {
        // height of button frame
        return UIScreen.main.bounds.size.height * (1/24)
    }
    
    /// top margin of direction text label
    static var textLabelBuffer: CGFloat {
        return buttonFrameHeight * (1/12)
    }
    
    /// y-origin of the get directions button
    static var yOriginOfGetDirectionsButton: CGFloat {
        return UIScreen.main.bounds.size.height - settingsAndHelpFrameHeight - settingsAndHelpMargin
    }
    
    /// y-origin of the settings and help buttons
    static var yOriginOfSettingsAndHelpButton: CGFloat {
        get {
            // y-origin of button frame
            return UIScreen.main.bounds.size.height - settingsAndHelpFrameHeight - settingsAndHelpMargin
        }
    }
    
    /// y-origin of button frame
    static var yOriginOfButtonFrame: CGFloat {
        return UIScreen.main.bounds.size.height - buttonFrameHeight - settingsAndHelpFrameHeight - settingsAndHelpMargin
    }
    
    /// y-origin of announcement frame
    static var yOriginOfAnnouncementFrame: CGFloat {
        return UIScreen.main.bounds.size.height/15
    }
    
    static var yButtonFrameMargin: CGFloat {
        return 25.0
    }
    
    static var topButtonFrameMargin: CGFloat {
        return 450.0
    }
    
    /// How to align the button horizontally within the button frame
    enum ButtonContainerHorizontalAlignment {
        /// put the button in the center
        case center
        /// put the button right of center
        case rightcenter
        /// put the button to the right
        case right
        /// put the button left of center
        case leftcenter
        /// put the button to the left
        case left
    }
    
    /// The appearance of the button.
    enum ButtonAppearance {
        /// An image button appears using the specified UIImage
        case imageButton(image: UIImage)
        /// A text button appears using the specified text label
        case textButton(label: String)
    }
}
