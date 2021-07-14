//
//  EnterCodeIDView.swift
//  Clew
//
//  Created by Berwin Lan on 7/7/21.
//  Copyright © 2021 OccamLab. All rights reserved.
//

import SwiftUI
import Combine

class CodeIDModel: ObservableObject {
    var limit: Int = 3

    @Published var code: String = "" {
        didSet {
             if code.count > limit {
                code = String(code.prefix(limit))
             }
        }
    }
}

struct EnterCodeIDView: View {
    let vc: ViewController
    @ObservedObject private var codeIDModel = CodeIDModel()

     var body: some View {
        VStack {
            TextField("3-digit App Clip Code ID", text: $codeIDModel.code)
                .padding(20)
                .disableAutocorrection(true)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numberPad)
            
            EnterButton(vc: vc, codeID: codeIDModel.code)
                .padding(40)
                .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.clewGreen, lineWidth: 10)
                )
                .frame(minWidth: 0, maxWidth: .infinity)
                .padding(.horizontal, 20)
        }
     }
}

///// A text entry box in which to enter the app clip code ID
//struct EnterCodeIDView: View {
//    let vc: ViewController
//    @State private var appClipCodeID: String = ""
//
//    var body: some View {
//        VStack {
//            TextField(
//                "3-digit App Clip Code ID",
//                 text: $appClipCodeID)
//                .padding(20)
//                .disableAutocorrection(true)
//                .textFieldStyle(RoundedBorderTextFieldStyle())
//                .keyboardType(.numberPad)
//
//            EnterButton(vc: vc, codeID: appClipCodeID)
//                .padding(40)
//                .overlay(
//                        RoundedRectangle(cornerRadius: 10)
//                            .stroke(Color.clewGreen, lineWidth: 10)
//                )
//                .frame(minWidth: 0, maxWidth: .infinity)
//                .padding(.horizontal, 20)
//        }
//    }
//}
//
//
struct EnterButtonView: View {
    var body: some View {
        HStack{
            Spacer()

            Text("Continue to Routes")
                .bold()
                .foregroundColor(Color.primary)
            Spacer()
        }
    }
}

/// Press this button to submit the app clip code ID and proceed to the routes
struct EnterButton: View {
    var vc: ViewController
    var codeID: String
    var body: some View {
        Button(action: {
            vc.appClipCodeID = codeID
            NotificationCenter.default.post(name: NSNotification.Name("shouldDismissCodeIDPopover"), object: nil)
        }) {
            EnterButtonView()
        }
    }
}
