// Presses and lists the menu commands of one running app, found by its process id, through the
// accessibility API. Scripts/same-behaviour.sh builds it and uses it on the Lockstep it started.
//
//     menu <pid> ready                      waits until the app has its menu bar (20 s at most)
//     menu <pid> press <menu> <item> [<item in its submenu> ...]
//     menu <pid> able <seconds> <menu> <item> [<item in its submenu> ...]
//                                           waits until that item is not greyed out, and presses nothing
//     menu <pid> front                      exit code 0 when the app is the one in front, 1 when it is behind
//     menu <pid> list                       every item: "Menu > Item", then "off" and "ticked" where they hold
//     menu <pid> quit                       presses the last item of the app's own menu (Quit)
//
// It never uses System Events, which finds an app by name and so reaches Max's own copy of Lockstep.
// Everything here starts from the process id it was given.
//
// An item's name may end in "*", which stands for any ending: "Undo*" is Edit > Undo whatever it
// would undo ("Undo Join Clips"). The line printed for a press has the full name.
//
// Exit codes: 0 done, 2 the item is there but greyed out (nothing was pressed), 3 the item or the menu is
// not there, 4 the app has no menu bar or this program may not use the accessibility API.

import AppKit
import ApplicationServices

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data("menu: \(message)\n".utf8))
    exit(code)
}

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) ?? []
}

func title(_ element: AXUIElement) -> String {
    attribute(element, kAXTitleAttribute) ?? ""
}

/// The items of a menu bar item or of an item with a submenu: the children of its one menu.
func items(of element: AXUIElement) -> [AXUIElement] {
    children(element).first.map(children) ?? []
}

let arguments = CommandLine.arguments
guard arguments.count >= 3, let pid = pid_t(arguments[1]) else {
    fail(64, "usage: menu <pid> ready | list | quit | press <menu> <item> [<subitem> ...]")
}
guard AXIsProcessTrusted() else {
    fail(4, "this program may not use the accessibility API. Allow the app it is run from in System Settings > Privacy & Security > Accessibility.")
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)

func menuBar() -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
}

func menus() -> [AXUIElement] {
    guard let bar = menuBar() else { fail(4, "process \(pid) has no menu bar") }
    return children(bar)
}

func press(_ item: AXUIElement, named name: String) {
    let enabled: Bool = attribute(item, kAXEnabledAttribute) ?? false
    guard enabled else {
        print("off: \(name)")
        exit(2)
    }
    let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
    guard result == .success else { fail(3, "could not press \(name) (\(result.rawValue))") }
    print("pressed: \(name)")
}

/// True when an item's title is the name asked for. A name that ends in "*" asks for a beginning.
func matches(_ title: String, _ name: String) -> Bool {
    name.hasSuffix("*") ? title.hasPrefix(String(name.dropLast())) : title == name
}

/// The item at a path of a menu, an item and perhaps items of submenus below it, with its full name.
/// Any depth: Track > Effects > Double > Thick is three items deep.
func item(at path: [String]) -> (item: AXUIElement, name: String)? {
    guard let menu = menus().first(where: { title($0) == path[0] }),
          var found = items(of: menu).first(where: { matches(title($0), path[1]) })
    else { return nil }
    var name = "\(path[0]) > \(title(found))"
    for step in path.dropFirst(2) {
        guard let inner = items(of: found).first(where: { matches(title($0), step) }) else { return nil }
        found = inner
        name += " > \(title(inner))"
    }
    return (found, name)
}

switch arguments[2] {
case "ready":
    // The Track menu is Lockstep's own and comes with the window's commands.
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if kill(pid, 0) != 0 { fail(4, "process \(pid) is gone") }
        if let bar = menuBar(), children(bar).contains(where: { title($0) == "Track" }) { exit(0) }
        Thread.sleep(forTimeInterval: 0.2)
    }
    fail(4, "process \(pid) showed no Track menu within 20 seconds")

case "front":
    // A scratch run is started behind the other apps and nothing this program does brings it forward.
    // In front means somebody clicked its window, and keys typed since then went to it.
    exit(NSRunningApplication(processIdentifier: pid)?.isActive == true ? 0 : 1)

case "list":
    func line(_ path: String, _ item: AXUIElement) {
        let enabled: Bool = attribute(item, kAXEnabledAttribute) ?? false
        let mark: String = attribute(item, kAXMenuItemMarkCharAttribute) ?? ""
        print(path + (enabled ? "" : "  off") + (mark.isEmpty ? "" : "  ticked"))
    }
    // The Apple menu and the app's own menu are the system's and say nothing about the project.
    for menu in menus().dropFirst(2) {
        for item in items(of: menu) where !title(item).isEmpty {
            let path = "\(title(menu)) > \(title(item))"
            line(path, item)
            for inner in items(of: item) where !title(inner).isEmpty {
                line("\(path) > \(title(inner))", inner)
            }
        }
    }

case "quit":
    let all = menus()
    guard all.count >= 2, let last = items(of: all[1]).last(where: { !title($0).isEmpty }),
          title(last).hasPrefix("Quit")
    else { fail(3, "the app's own menu has no Quit item") }
    press(last, named: "Quit")

case "press":
    guard arguments.count >= 5 else { fail(64, "press needs a menu and an item") }
    guard let found = item(at: Array(arguments[3...])) else {
        fail(3, "there is no item \(arguments[3...].joined(separator: " > "))")
    }
    press(found.item, named: found.name)

case "able":
    guard arguments.count >= 6, let seconds = Double(arguments[3]) else { fail(64, "able needs seconds, a menu and an item") }
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if kill(pid, 0) != 0 { fail(4, "process \(pid) is gone") }
        if let found = item(at: Array(arguments[4...])), attribute(found.item, kAXEnabledAttribute) ?? false { exit(0) }
        Thread.sleep(forTimeInterval: 0.2)
    }
    fail(2, "\(arguments[4...].joined(separator: " > ")) stayed greyed out for \(seconds) s")

default:
    fail(64, "unknown command \(arguments[2])")
}
