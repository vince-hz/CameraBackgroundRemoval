//
//  ContentView.swift
//  CameraBackgroundRemoval
//
//  Created by xuyunshi on 2024/4/2.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var model = Model()

    var body: some View {
        VStack {
            if let image = model.viewfinderImage {
                image
                    .resizable()
                    .frame(width: 480, height: 320)
                    .clipped()
            }

            Button {
                model.camera.switchCaptureDevice()
            } label: {
                Label("Switch Camera", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .padding()
        .task {
            await model.camera.start()
        }
        .background(.black)
    }
}

#Preview {
    ContentView()
}
