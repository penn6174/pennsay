#!/usr/bin/env swift
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? "VoiceInput"
let nameFilter = CommandLine.arguments.dropFirst(2).first

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    guard (window[kCGWindowOwnerName as String] as? String) == owner else { continue }
    if let nameFilter,
       let name = window[kCGWindowName as String] as? String,
       !name.contains(nameFilter) {
        continue
    }

    if let number = window[kCGWindowNumber as String] as? Int {
        print(number)
        exit(0)
    }
}

exit(1)
