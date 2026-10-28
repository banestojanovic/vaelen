import Foundation
let path = "/Users/banes/Code/apps/vaelen"
_ = try ConnectionFileBoundary().directory(URL(fileURLWithPath: path, isDirectory: true))
print("PASS descriptor-pinned ancestor validation at \(path)")
