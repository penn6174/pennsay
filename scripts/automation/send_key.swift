#!/usr/bin/env swift
import AppKit

enum KeyError: Error {
    case invalidArguments
    case unsupportedKey(String)
}

struct KeySpec {
    let keyCode: CGKeyCode
    let downFlags: CGEventFlags
    let usesFlagsChanged: Bool
}

let keyName = CommandLine.arguments.dropFirst().first ?? ""
let action = CommandLine.arguments.dropFirst(2).first ?? "tap"
let durationMs = Int(CommandLine.arguments.dropFirst(3).first ?? "100") ?? 100

func spec(for keyName: String) throws -> KeySpec {
    switch keyName {
    case "right_option":
        return KeySpec(keyCode: 61, downFlags: .maskAlternate, usesFlagsChanged: true)
    case "left_option":
        return KeySpec(keyCode: 58, downFlags: .maskAlternate, usesFlagsChanged: true)
    case "right_command":
        return KeySpec(keyCode: 54, downFlags: .maskCommand, usesFlagsChanged: true)
    case "left_command":
        return KeySpec(keyCode: 55, downFlags: .maskCommand, usesFlagsChanged: true)
    case "right_control":
        return KeySpec(keyCode: 62, downFlags: .maskControl, usesFlagsChanged: true)
    case "caps_lock":
        return KeySpec(keyCode: 57, downFlags: .maskAlphaShift, usesFlagsChanged: true)
    case "function":
        return KeySpec(keyCode: 63, downFlags: .maskSecondaryFn, usesFlagsChanged: true)
    case "escape":
        return KeySpec(keyCode: 53, downFlags: [], usesFlagsChanged: false)
    default:
        throw KeyError.unsupportedKey(keyName)
    }
}

func post(_ spec: KeySpec, keyDown: Bool) {
    let source = CGEventSource(stateID: .hidSystemState)
    let event = CGEvent(
        keyboardEventSource: source,
        virtualKey: spec.keyCode,
        keyDown: keyDown
    )
    event?.flags = keyDown ? spec.downFlags : []
    event?.type = spec.usesFlagsChanged ? .flagsChanged : (keyDown ? .keyDown : .keyUp)
    event?.post(tap: .cghidEventTap)
}

let keySpec = try spec(for: keyName)

switch action {
case "down":
    post(keySpec, keyDown: true)
case "up":
    post(keySpec, keyDown: false)
case "tap":
    post(keySpec, keyDown: true)
    usleep(useconds_t(durationMs * 1000))
    post(keySpec, keyDown: false)
case "hold":
    post(keySpec, keyDown: true)
    usleep(useconds_t(durationMs * 1000))
    post(keySpec, keyDown: false)
default:
    throw KeyError.invalidArguments
}
