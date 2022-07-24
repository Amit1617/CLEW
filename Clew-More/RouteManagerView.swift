//
//  RouteManagerView.swift
//  Clew-More
//
//  Created by Esme Abbot on 7/19/21.
//  Copyright © 2021 OccamLab. All rights reserved.
//

import SwiftUI

struct RouteManagerView: View {
    var route: SavedRoute
    var vc: ViewController
    var body: some View {
        HStack{
            Button(action: {
                self.vc.routeOptionsController?.dismiss(animated: false)
            }) {
                Text("Back To Routes")
                    .bold()
                    .multilineTextAlignment(.leading)
            }.padding()
            Spacer()
        }
     
        Text(String(route.name))
            .font(.title)
            .multilineTextAlignment(.center)
            .accessibility(hint: Text("Route Name"))
        if !route.appClipCodeID.isEmpty {
            Text("\(String(NSLocalizedString("AppClipCodeIDText", comment: "describes an app clip code ID"))): \(String(route.appClipCodeID))")
            .font(.title2)
        }
        VStack {
            Button(action: {
                self.vc.onRouteTableViewCellClicked(route: self.route, navigateStartToEnd: true)
                self.vc.routeOptionsController?.dismiss(animated: false)
            } ){
                Text(String(NSLocalizedString("NavigateText", comment: "This is the text that tells the user to navigate a route")))
                    .frame(minWidth: 0, maxWidth: 300)
                    .padding()
                    .foregroundColor(.black)
                    .background(Color.clewGreen)
                    .cornerRadius(10)
                    .font(.system(size: 18, weight: .bold))
                    .padding(10)
                    .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.clewGreen, lineWidth: 4))
            }.padding()
            
            Button(action: {
                do {
                    try self.vc.dataPersistence.delete(route: self.route)
                    self.vc.routeOptionsController?.dismiss(animated: false)
                    self.vc.hideAllViewsHelper()
                    self.vc.add(self.vc.recordPathController)
                } catch {
                    print("Unexpectedly failed to persist the new routes data")
                }
            }) {
                Text(String(NSLocalizedString("DeleteText", comment: "This is the text that tells the user to delete a route")))
                    .frame(minWidth: 0, maxWidth: 300)
                    .padding()
                    .foregroundColor(.white)
                    .background(Color.red)
                    .cornerRadius(10)
                    .font(.system(size: 18, weight: .bold))
                    .padding(10)
                    .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.red, lineWidth: 4))
            }.padding()
        }
    }
}

