# Vaelen.app

This directory contains the native SwiftUI menu-bar application target. It is
kept outside the Swift package executable targets because the app must be
bundled and signed by Xcode. The app imports the local `VaelenIPC` package and
does not own Core state.

Build requirements and the Xcode project are documented in the repository
README once full Xcode is available for validation.
