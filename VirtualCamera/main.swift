// main.swift — entry point of the Airlive Bridge Virtual Camera system extension.
//
// The extension is a separate process macOS launches on demand; every app that
// opens a camera (Zoom, Meet, QuickTime…) talks to it, never to the Bridge.  All
// it does is start the provider and run — CoreMediaIO drives everything else.

import Foundation
import CoreMediaIO

let providerSource = AirliveProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
