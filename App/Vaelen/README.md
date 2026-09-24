# Vaelen.app

This directory contains the native SwiftUI menu-bar application target. It is
kept outside the Swift package executable targets because the app must be
bundled and signed by Xcode. The app imports the local `VaelenIPC` package and
does not own Core state. Its build phase also builds and embeds the matching
`vaelend` executable. When Core IPC is unavailable, the app starts that
executable, retries IPC for up to two seconds, and terminates only a Core
process it started when the app quits.

Build requirements and the Xcode project are documented in the repository
README once full Xcode is available for validation.
