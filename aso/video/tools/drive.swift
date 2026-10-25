// Plays back a JSON list of smooth mouse/keyboard steps with CGEvent at ~60Hz.
// Usage: drive <clip.json>   |   drive --where (prints the pointer position)
//
// Coordinates are global screen points (top-left origin), e.g. 0–1470 × 0–956
// on a 14" MacBook Pro. Steps:
//   {"op":"wait","s":1}
//   {"op":"move","to":[x,y],"s":0.6}            eased pointer move
//   {"op":"click","at":[x,y]}                    moves there first (0.5s) then clicks
//   {"op":"doubleClick","at":[x,y]}
//   {"op":"rightClick","at":[x,y]}
//   {"op":"drag","from":[x,y],"to":[x,y],"s":0.9} down → eased drag → up
//   {"op":"key","key":"s","mods":["cmd","alt","shift"]}
//   {"op":"scroll","at":[x,y],"dy":-1200,"s":3}  smooth pixel scroll (negative = down)
// Needs Accessibility permission for the app you run it from (e.g. Terminal).
import Foundation
import CoreGraphics

struct Step: Decodable {
    let op: String
    var s: Double?
    var to: [Double]?
    var at: [Double]?
    var from: [Double]?
    var key: String?
    var mods: [String]?
    var dy: Double?
}

let hz = 60.0
let src = CGEventSource(stateID: .hidSystemState)
var cursor = CGEvent(source: nil)?.location ?? .zero

func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
func pt(_ a: [Double]) -> CGPoint { CGPoint(x: a[0], y: a[1]) }
func sleep(_ s: Double) { usleep(useconds_t(max(0, s) * 1_000_000)) }

func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button)
    e?.setIntegerValueField(.mouseEventClickState, value: clicks)
    e?.post(tap: .cghidEventTap)
}

/// Eased path from the current cursor to `to`, posting `type` events at 60Hz.
func glide(to: CGPoint, seconds: Double, type: CGEventType = .mouseMoved) {
    let start = cursor
    let n = max(1, Int(seconds * hz))
    for i in 1...n {
        let t = ease(Double(i) / Double(n))
        let p = CGPoint(x: start.x + (to.x - start.x) * t, y: start.y + (to.y - start.y) * t)
        post(type, p)
        sleep(1 / hz)
    }
    cursor = to
}

/// Natural move duration scaled with distance (0.4–0.9s).
func autoDuration(to: CGPoint) -> Double {
    let d = hypot(to.x - cursor.x, to.y - cursor.y)
    return min(0.9, max(0.4, d / 900))
}

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
    "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "return": 36, "tab": 48, "space": 49, "escape": 53, "up": 126, "down": 125,
]

func key(_ name: String, _ mods: [String]) {
    guard let code = keyCodes[name] else { fatalError("Unknown key \(name)") }
    var flags: CGEventFlags = []
    for m in mods {
        switch m {
        case "cmd": flags.insert(.maskCommand)
        case "alt", "opt": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        case "ctrl": flags.insert(.maskControl)
        default: fatalError("Unknown modifier \(m)")
        }
    }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        sleep(0.03)
    }
}

if CommandLine.arguments.dropFirst().first == "--where" {
    let p = CGEvent(source: nil)?.location ?? .zero
    print("[\(Int(p.x)),\(Int(p.y))]"); exit(0)
}

guard CommandLine.arguments.count == 2,
      let data = FileManager.default.contents(atPath: CommandLine.arguments[1]) else {
    print("Usage: drive <clip.json>"); exit(1)
}
let steps = try JSONDecoder().decode([Step].self, from: data)

for step in steps {
    switch step.op {
    case "wait":
        sleep(step.s ?? 0.5)
    case "move":
        let to = pt(step.to!)
        glide(to: to, seconds: step.s ?? autoDuration(to: to))
    case "click", "doubleClick", "rightClick":
        let at = pt(step.at!)
        glide(to: at, seconds: autoDuration(to: at))
        sleep(0.15)
        if step.op == "rightClick" {
            post(.rightMouseDown, at, .right); sleep(0.05); post(.rightMouseUp, at, .right)
        } else {
            post(.leftMouseDown, at); sleep(0.05); post(.leftMouseUp, at)
            if step.op == "doubleClick" {
                sleep(0.08)
                post(.leftMouseDown, at, clicks: 2); sleep(0.05); post(.leftMouseUp, at, clicks: 2)
            }
        }
    case "drag":
        let from = pt(step.from!), to = pt(step.to!)
        glide(to: from, seconds: autoDuration(to: from))
        sleep(0.2)
        post(.leftMouseDown, from)
        sleep(0.1)
        glide(to: to, seconds: step.s ?? 0.9, type: .leftMouseDragged)
        sleep(0.15)
        post(.leftMouseUp, to)
    case "key":
        key(step.key!, step.mods ?? [])
    case "scroll":
        let at = pt(step.at!)
        glide(to: at, seconds: autoDuration(to: at))
        let total = step.dy ?? -1000, secs = step.s ?? 2
        let n = max(1, Int(secs * hz))
        var sent = 0.0
        for i in 1...n {
            let target = total * ease(Double(i) / Double(n))
            let delta = Int32((target - sent).rounded())
            sent += Double(delta)
            CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1,
                    wheel1: delta, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
            sleep(1 / hz)
        }
    default:
        fatalError("Unknown op \(step.op)")
    }
    // Natural beat after each action lands.
    if step.op != "wait" { sleep(0.35) }
}
