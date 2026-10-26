// Clipboard History: a Raycast-style window for Alfred's clipboard history.
//
// Alfred keeps recording the clipboard as usual; this only reads its database.
// The window is drawn to look like Alfred with the Raycast themes: a list grouped
// by day on the left, and a preview with an Information panel on the right.
// ↩ pastes into the app you were in, ⌘↩ copies, and rows drag out as text or files.
//
// It's an app bundle (ClipHistory.app, LSUIElement) that starts at login (it keeps its own
// LaunchAgent, see installLoginAgent) and stays running, so it opens instantly. Like Alfred, it
// becomes the active app while its window is open; macOS allows that only when the app receives
// the key press itself (it registers ⌃⌘V, see registerHotKey) or is opened through LaunchServices
// (the workflow's keyword runs `open`). Closing hands focus back to the app you were in.
// The app has no Accessibility permission, so to paste it asks Alfred to press ⌘V (askAlfredToPaste).
//
// Build: source/build.sh (add --package for a .alfredworkflow)
import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing
import SQLite3

// MARK: - Alfred's clipboard history

let alfredDatabases = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Alfred/Databases")
let historyPath = alfredDatabases.appendingPathComponent("clipboard.alfdb").path
let cacheDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/com.andreisuslov.alfred-clipboard-history")

/// Lowercased and without accents, so typing "cafe" finds "Café".
func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}

// Compiled once: the history is classified thousands of clippings at a time.
let colorFunction = try! NSRegularExpression(
    pattern: #"^(rgba?|hsla?)\(\s*([\d.]+%?)\s*[,\s]\s*([\d.]+%?)\s*[,\s]\s*([\d.]+%?)\s*(?:[,/]\s*([\d.]+%?)\s*)?\)$"#)
/// A command with a flag within its first few words: "xattr -d …", "git log --oneline".
let commandWithFlag = try! NSRegularExpression(pattern: #"^[a-z][\w.-]*( +[^\s-]\S*){0,3} +-{1,2}[A-Za-z]"#)

/// The color a clipping names when it is only a color value: #RGB(A), #RRGGBB(AA), rgb()/rgba(), hsl()/hsla().
func parseColor(_ item: String) -> NSColor? {
    guard item.utf8.count <= 64 else { return nil }
    let text = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
    // Without "#", only six or eight hex digits mixing letters and numbers: "facade" is a word, "531348" a code.
    if !text.hasPrefix("#"), !([6, 8].contains(hex.count) && hex.contains(where: \.isNumber) && hex.contains(where: \.isLetter)) {
        hex = ""
    }
    // "#123" is more often an issue number than a color; "#000" and "#fff" are colors.
    if hex.count <= 4, hex.allSatisfy(\.isNumber), Set(hex).count > 1 { hex = "" }
    if [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) {
        if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        if hex.count == 6 { hex += "ff" }
        let value = UInt32(hex, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat(value >> 24 & 0xFF) / 255, green: CGFloat(value >> 16 & 0xFF) / 255,
                       blue: CGFloat(value >> 8 & 0xFF) / 255, alpha: CGFloat(value & 0xFF) / 255)
    }
    guard let match = colorFunction.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    func part(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
    /// A component as 0...1: "50%" is a percentage, a bare number is out of `scale`.
    func unit(_ value: String, scale: Double) -> CGFloat {
        let number = value.hasSuffix("%") ? (Double(value.dropLast()) ?? 0) / 100 : (Double(value) ?? 0) / scale
        return CGFloat(min(max(number, 0), 1))
    }
    guard let function = part(1), let a = part(2), let b = part(3), let c = part(4) else { return nil }
    let alpha = part(5).map { unit($0, scale: 1) } ?? 1
    if function.hasPrefix("rgb") {
        return NSColor(srgbRed: unit(a, scale: 255), green: unit(b, scale: 255), blue: unit(c, scale: 255), alpha: alpha)
    }
    // HSL to the HSB that NSColor takes.
    let hue = CGFloat((Double(a.replacingOccurrences(of: "%", with: "")) ?? 0).truncatingRemainder(dividingBy: 360) / 360)
    let saturation = unit(b, scale: 100), lightness = unit(c, scale: 100)
    let brightness = lightness + saturation * min(lightness, 1 - lightness)
    let hsbSaturation = brightness == 0 ? 0 : 2 * (1 - lightness / brightness)
    return NSColor(colorSpace: .sRGB, hue: hue, saturation: hsbSaturation, brightness: brightness, alpha: alpha)
}

/// A color as "#RRGGBB" (plus alpha when not opaque) and as "rgb(r, g, b)".
func colorValues(_ color: NSColor) -> (hex: String, rgb: String) {
    let srgb = color.usingColorSpace(.sRGB) ?? color
    let r = Int((srgb.redComponent * 255).rounded()), g = Int((srgb.greenComponent * 255).rounded())
    let b = Int((srgb.blueComponent * 255).rounded()), alpha = srgb.alphaComponent
    if alpha < 1 {
        return (String(format: "#%02X%02X%02X%02X", r, g, b, Int((alpha * 255).rounded())),
                "rgba(\(r), \(g), \(b), \(String(format: "%.2f", alpha)))")
    }
    return (String(format: "#%02X%02X%02X", r, g, b), "rgb(\(r), \(g), \(b))")
}

/// A rounded square of a color, outlined so white and near-background colors still show.
func swatch(_ color: NSColor, side: CGFloat, radius: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        color.setFill()
        path.fill()
        NSColor(white: 0.5, alpha: 0.35).setStroke()
        path.stroke()
        return true
    }
}

let codeStarts = ["import ", "def ", "class ", "func ", "function ", "fn ", "const ", "let ", "var ",
                  "return ", "if (", "for (", "while (", "} else", "public ", "private ", "static ", "struct ",
                  "enum ", "#include", "#!/", "package ", "select ", "insert into ", "create table", "$ ",
                  "sudo ", "git ", "brew ", "npm ", "npx ", "yarn ", "pip ", "cd ", "curl ", "docker ",
                  "kubectl ", "ssh ", "export ", "echo ", "python", "node ", "</", "<div", "<?xml"]

/// A guess at whether a clipping is code or a shell command rather than prose: code keywords,
/// lines ending in ; { or }, commands with flags, indentation and a high density of symbols.
func looksLikeCode(_ item: String) -> Bool {
    let rawLines = item.prefix(4000).split(whereSeparator: \.isNewline)
    let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !lines.isEmpty else { return false }
    var score = 0
    for line in lines {
        let lower = line.lowercased()
        if codeStarts.contains(where: { lower.hasPrefix($0) }) { score += 2 }
        if lower.hasPrefix("from "), lower.contains(" import ") { score += 2 }  // Python, not "from - …"
        if let last = line.last, ";{}".contains(last) { score += 2 }
        if line.count < 300, commandWithFlag.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            score += 2
        }
        // Markdown tables start with "|", so their pipes don't count as shell pipes.
        if !line.hasPrefix("|"), [" && ", " | ", "=>", "->", "::", "==", "!="].contains(where: { line.contains($0) }) {
            score += 1
        }
    }
    score += rawLines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
    // Only for a few lines or more: "$3,485.74" or a list of email addresses is dense with symbols too.
    let sample = item.prefix(2000)
    let symbols = sample.unicodeScalars.filter { "{}[]();=<>$|&\\_".unicodeScalars.contains($0) }.count
    if lines.count >= 3, Double(symbols) / Double(sample.count) > 0.06 { score += 2 }
    return score >= (lines.count == 1 ? 2 : max(3, lines.count / 2))
}

struct Clip {
    enum Kind { case text, image, files }  // how Alfred stored it
    enum Category { case text, link, code, color, media }  // what the type menu filters by

    let kind: Kind
    let item: String  // the text itself, or Alfred's label for an image or a file list
    let date: Date
    let app: String
    let appPath: String
    let dataHash: String
    // Worked out once when the history loads (off the main thread), so rows and filtering stay fast.
    let title: String
    let category: Category
    let color: NSColor?  // the color a color value names, for its swatch
    let searchKey: [UInt8]  // fold(text + app), searched as raw bytes
    let characters: Int  // for the Information panel; counting a long clipping on every selection was slow
    let words: Int

    init(kind: Kind, item: String, date: Date, app: String, appPath: String, dataHash: String) {
        self.kind = kind
        self.item = item
        self.date = date
        self.app = app
        self.appPath = appPath
        self.dataHash = dataHash
        color = kind == .text ? parseColor(item) : nil
        switch kind {
        case .image, .files: category = .media
        case .text where color != nil: category = .color
        case .text where Clip.isLink(item): category = .link
        case .text where looksLikeCode(item): category = .code
        case .text: category = .text
        }
        searchKey = Array(fold(item + "\n" + app).utf8)
        characters = kind == .text ? item.count : 0
        words = kind == .text ? item.split(whereSeparator: \.isWhitespace).count : 0
        switch kind {
        case .text:
            // Only the first lines are split, so a long clipping doesn't cost a full pass.
            let lines = item.split(maxSplits: 20, omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            let line = lines.first { !$0.allSatisfy(\.isWhitespace) } ?? ""
            title = String(line.trimmingCharacters(in: .whitespaces).prefix(300))
        case .image:
            title = "Image (\(Clip.imageInfo(item).dimensions))"
        case .files:
            let files = Clip.files(listedIn: Clip.dataURL(dataHash))
            let first = files.first?.lastPathComponent ?? item
            title = files.count > 1 ? "\(first) and \(files.count - 1) more" : first
        }
    }

    static func dataURL(_ hash: String) -> URL {
        alfredDatabases.appendingPathComponent("clipboard.alfdb.data").appendingPathComponent(hash)
    }

    static func files(listedIn plist: URL) -> [URL] {
        guard let data = try? Data(contentsOf: plist),
              let paths = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func isLink(_ item: String) -> Bool {
        guard item.utf8.count < 4096 else { return false }
        let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    /// Alfred labels images "Image: 608x917 (2.1 MB)".
    static func imageInfo(_ label: String) -> (dimensions: String, size: String) {
        let parts = label.replacingOccurrences(of: "Image: ", with: "").components(separatedBy: " (")
        let size = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ")")) : ""
        return (parts[0].replacingOccurrences(of: "x", with: "×"), size)
    }

    /// The same thing copied again: Alfred keeps one entry per text, image or file list.
    func isSameItem(as other: Clip) -> Bool {
        kind == other.kind && (kind == .text ? item == other.item : dataHash == other.dataHash)
    }

    var dataURL: URL { Clip.dataURL(dataHash) }
    var files: [URL] { kind == .files ? Clip.files(listedIn: dataURL) : [] }
    var imageInfo: (dimensions: String, size: String) { Clip.imageInfo(item) }

    /// The image under a readable name for dragging, "Clipboard image 2026-10-26 at 05.39.08.tiff":
    /// a hard link to the file Alfred stored, so it takes no space.
    var namedImageFile: URL? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let file = cacheDir.appendingPathComponent("Clipboard image \(stamp.string(from: date)).\(dataURL.pathExtension)")
        if !FileManager.default.fileExists(atPath: file.path),
           (try? FileManager.default.linkItem(at: dataURL, to: file)) == nil {
            try? FileManager.default.copyItem(at: dataURL, to: file)
        }
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Puts the clip back on a pasteboard. Images go back as the exact bytes Alfred stored,
    /// so Alfred sees the same item again instead of recording a near-duplicate.
    func write(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        switch kind {
        case .text:
            pasteboard.setString(item, forType: .string)
        case .image:
            guard let data = try? Data(contentsOf: dataURL) else { return }
            pasteboard.setData(data, forType: dataURL.pathExtension.lowercased() == "png" ? .png : .tiff)
        case .files:
            pasteboard.writeObjects(files as [NSURL])
        }
    }

    /// What a dragged row carries: text as text, an image or a file as the file itself.
    var dragWriter: NSPasteboardWriting? {
        switch kind {
        case .text: return item as NSString
        case .image: return namedImageFile as NSURL?
        case .files: return files.first as NSURL?
        }
    }
}

func withHistory<T>(_ sql: String, _ body: (OpaquePointer?) -> T) -> T? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(historyPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    return body(stmt)
}

/// How many items Alfred has and when the newest was copied; any change means something to reload.
struct HistoryStamp: Equatable {
    var count = 0
    var newest = 0.0
}

func historyStamp() -> HistoryStamp {
    withHistory("select count(*), max(ts) from clipboard") { stmt in
        sqlite3_step(stmt) == SQLITE_ROW
            ? HistoryStamp(count: Int(sqlite3_column_int(stmt, 0)), newest: sqlite3_column_double(stmt, 1)) : HistoryStamp()
    } ?? HistoryStamp()
}

/// The whole history, newest first; or, with `newerThan`, just what Alfred recorded after that time.
func loadClips(newerThan: Double = -.infinity) -> [Clip] {
    let since = newerThan.isFinite ? "where ts > \(newerThan) " : ""
    return withHistory("select item, ts, app, apppath, dataType, dataHash from clipboard \(since)order by ts desc") { stmt in
        func text(_ column: Int32) -> String { sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? "" }
        var clips: [Clip] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kind: Clip.Kind
            switch sqlite3_column_int(stmt, 4) {
            case 1: kind = .image
            case 2: kind = .files
            default: kind = .text
            }
            // Alfred stores seconds since 2001-01-01, which is Foundation's reference date.
            clips.append(Clip(kind: kind, item: text(0),
                              date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1)),
                              app: text(2), appPath: text(3), dataHash: text(5)))
        }
        return clips
    } ?? []
}

/// Drops image links whose original Alfred has deleted (a link count of 1 means ours is the last).
func pruneImageLinks() {
    let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.lastPathComponent.hasPrefix("Clipboard image ") {
        let links = (try? FileManager.default.attributesOfItem(atPath: file.path)[.referenceCount] as? Int) ?? 0
        if links <= 1 { try? FileManager.default.removeItem(at: file) }
    }
}

// MARK: - Formatting

func copiedLabel(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDateInToday(date) { return "Today at \(time)" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday at \(time)" }
    return "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
}

func dayTitle(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
        return date.formatted(.dateTime.weekday(.wide))
    }
    if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
        return date.formatted(.dateTime.month(.wide).day())
    }
    return date.formatted(.dateTime.month(.wide).day().year())
}

func abbreviatingHome(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

// MARK: - Theme

func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
    func make(_ rgba: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(rgba >> 24 & 0xFF) / 255, green: CGFloat(rgba >> 16 & 0xFF) / 255,
                blue: CGFloat(rgba >> 8 & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }
    return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? make(dark) : make(light) }
}

/// The Raycast Light and Raycast Dark themes set up in Alfred.
enum Theme {
    static let window = color(0xF7F7_F8EB, 0x1C1C_1EEB)
    static let border = color(0x0000_001F, 0xFFFF_FF1F)
    static let selection = color(0x0000_001A, 0xFFFF_FF1A)
    static let text = color(0x0000_00E6, 0xFFFF_FFE6)
    static let secondary = color(0x0000_0073, 0xFFFF_FF73)
    static let separator = color(0x0000_0017, 0xFFFF_FF17)
}

// MARK: - Views

class Flipped: NSView {
    override var isFlipped: Bool { true }
}

/// A rounded rectangle in a theme color; redrawn by AppKit when light/dark mode changes.
final class Fill: Flipped {
    let color: NSColor
    let radius: CGFloat
    let stroke: NSColor?

    init(_ color: NSColor, radius: CGFloat = 0, stroke: NSColor? = nil, frame: NSRect = .zero) {
        self.color = color
        self.radius = radius
        self.stroke = stroke
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Inset only when stroking, so the stroke stays inside; a 1pt hairline would vanish otherwise.
        let rect = stroke == nil ? bounds : bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        color.setFill()
        path.fill()
        if let stroke {
            stroke.setStroke()
            path.stroke()
        }
    }
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = Theme.text) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    return field
}

/// Finder-style thumbnail (an image's content, a PDF's first page), or the file's icon when there is none.
func thumbnail(of file: URL, side: CGFloat, completion: @escaping (NSImage) -> Void) {
    let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: side, height: side),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
        DispatchQueue.main.async {
            let icon = NSWorkspace.shared.icon(forFile: file.path)
            icon.size = NSSize(width: side, height: side)
            completion(representation?.nsImage ?? icon)
        }
    }
}

func symbol(_ name: String, size: CGFloat) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
}

/// A small key cap, like the ↩ and ⌘ hints in Raycast's action bar.
func keyCap(_ key: String) -> NSView {
    let text = label(key, size: 11, weight: .medium, color: Theme.secondary)
    text.alignment = .center
    let width = max(20, text.intrinsicContentSize.width + 8)
    let cap = Fill(Theme.selection, radius: 4, frame: NSRect(x: 0, y: 0, width: width, height: 20))
    text.frame = NSRect(x: 0, y: 3, width: width, height: 14)
    cap.addSubview(text)
    return cap
}

final class RowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
    override var isEmphasized: Bool { get { false } set {} }
}

final class ClipCell: NSTableCellView {
    let icon = NSImageView()
    let title = label("", size: 14)
    var file: URL?  // whose thumbnail this cell is waiting for

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = Theme.secondary
        icon.frame = NSRect(x: 18, y: 8, width: 20, height: 20)
        title.frame = NSRect(x: 48, y: 9, width: 300 - 48 - 18, height: 18)
        addSubview(icon)
        addSubview(title)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class HeaderCell: NSTableCellView {
    let title = label("", size: 11, weight: .semibold, color: Theme.secondary)

    init() {
        super.init(frame: .zero)
        title.frame = NSRect(x: 18, y: 4, width: 300 - 36, height: 14)
        addSubview(title)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Preview of the selected clip on top, Raycast's "Information" list below it.
final class DetailView: Flipped {
    let textScroll = NSScrollView()
    let textView = NSTextView()
    let imageView = NSImageView()
    let fileIcon = NSImageView()
    let fileName = label("", size: 13, weight: .medium)
    let info = Flipped()
    var shownFile: URL?
    var appIcons: [String: NSImage] = [:]

    /// Loading an app's icon from disk is slow, and the same few apps come up again and again.
    func appIcon(_ path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let icon = appIcons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        appIcons[path] = icon
        return icon
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.isEditable = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = Theme.text
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textScroll.documentView = textView
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.scrollerStyle = .overlay
        imageView.imageScaling = .scaleProportionallyDown
        fileIcon.imageScaling = .scaleProportionallyDown
        fileName.alignment = .center
        fileName.lineBreakMode = .byTruncatingMiddle
        [textScroll, imageView, fileIcon, fileName, info].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ clip: Clip?) {
        [textScroll, imageView, fileIcon, fileName].forEach { $0.isHidden = true }
        info.subviews.forEach { $0.removeFromSuperview() }
        shownFile = nil
        guard let clip else { return }

        var rows: [(String, String, NSImage?)] = [
            ("Application", clip.app.isEmpty ? "Unknown" : clip.app,
             appIcon(clip.appPath)),
        ]
        switch clip.kind {
        case .text:
            if let color = clip.color {
                let values = colorValues(color)
                rows.append(("Content type", "Color", nil))
                rows.append(("Hex", values.hex, nil))
                rows.append(("RGB", values.rgb, nil))
            } else {
                rows.append(("Content type", clip.category == .link ? "Link" : clip.category == .code ? "Code" : "Text", nil))
                rows.append(("Characters", clip.characters.formatted(), nil))
                rows.append(("Words", clip.words.formatted(), nil))
            }
        case .image:
            let info = clip.imageInfo
            rows.append(("Content type", "Image", nil))
            rows.append(("Dimensions", info.dimensions, nil))
            rows.append(("Image size", info.size, nil))
        case .files:
            let files = clip.files
            let isFolder = (try? files.first?.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            rows.append(("Content type", files.count > 1 ? "\(files.count) files" : isFolder ? "Folder" : "File", nil))
            if let first = files.first {
                rows.append(("Path", abbreviatingHome(first.deletingLastPathComponent().path), nil))
                if let size = try? first.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    rows.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file), nil))
                }
            }
        }
        rows.append(("Copied", copiedLabel(clip.date), nil))

        let rowHeight: CGFloat = 30
        let infoHeight = 36 + CGFloat(rows.count) * rowHeight + 8
        info.frame = NSRect(x: 0, y: bounds.height - infoHeight, width: bounds.width, height: infoHeight)
        info.addSubview(Fill(Theme.separator, frame: NSRect(x: 0, y: 0, width: bounds.width, height: 1)))
        let header = label("Information", size: 12, weight: .semibold, color: Theme.secondary)
        header.frame = NSRect(x: 18, y: 14, width: 200, height: 16)
        info.addSubview(header)
        for (index, (name, value, image)) in rows.enumerated() {
            let y = 36 + CGFloat(index) * rowHeight
            if index > 0 {
                info.addSubview(Fill(Theme.separator, frame: NSRect(x: 18, y: y, width: bounds.width - 36, height: 1)))
            }
            let nameLabel = label(name, size: 12, color: Theme.secondary)
            nameLabel.frame = NSRect(x: 18, y: y + 7, width: 130, height: 16)
            let valueLabel = label(value, size: 12)
            valueLabel.alignment = .right
            valueLabel.lineBreakMode = .byTruncatingMiddle
            valueLabel.sizeToFit()
            let valueWidth = min(valueLabel.frame.width, bounds.width - 36 - 150)
            valueLabel.frame = NSRect(x: bounds.width - 18 - valueWidth, y: y + 7, width: valueWidth, height: 16)
            info.addSubview(nameLabel)
            info.addSubview(valueLabel)
            if let image {
                let icon = NSImageView(image: image)
                icon.frame = NSRect(x: valueLabel.frame.minX - 20, y: y + 7, width: 16, height: 16)
                info.addSubview(icon)
            }
        }

        let preview = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - infoHeight)
        switch clip.kind {
        case .text where clip.color != nil:
            // A large swatch with the value under it, as Raycast shows colors.
            fileIcon.isHidden = false
            fileName.isHidden = false
            let side = min(preview.width - 36, preview.height - 16 - 42, 160)
            fileIcon.frame = NSRect(x: (preview.width - side) / 2, y: 16 + (preview.height - 58 - side) / 2, width: side, height: side)
            fileIcon.image = swatch(clip.color!, side: side, radius: 12)
            fileName.frame = NSRect(x: 18, y: preview.height - 34, width: preview.width - 36, height: 18)
            fileName.stringValue = clip.title
        case .text:
            textScroll.isHidden = false
            textScroll.frame = preview.insetBy(dx: 6, dy: 4)
            textView.frame = NSRect(origin: .zero, size: textScroll.contentSize)
            // Laying out a long clipping takes a while; the pane shows the first couple of thousand characters.
            textView.string = String(clip.item.prefix(2_500))
            textView.font = clip.category == .code ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
            textView.textColor = Theme.text
            textView.scroll(.zero)
        case .image:
            imageView.isHidden = false
            imageView.frame = preview.insetBy(dx: 18, dy: 16)
            imageView.image = NSImage(contentsOf: clip.dataURL)
        case .files:
            fileIcon.isHidden = false
            fileName.isHidden = false
            fileIcon.frame = NSRect(x: 18, y: 16, width: preview.width - 36, height: preview.height - 16 - 42)
            fileName.frame = NSRect(x: 18, y: preview.height - 34, width: preview.width - 36, height: 18)
            fileName.stringValue = clip.title
            fileIcon.image = nil
            guard let file = clip.files.first else { return }
            shownFile = file
            thumbnail(of: file, side: max(fileIcon.frame.width, fileIcon.frame.height)) { [weak self] image in
                if self?.shownFile == file { self?.fileIcon.image = image }
            }
        }
    }
}

// MARK: - Window

final class Panel: NSPanel {
    var onCommandReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    // Esc when something other than the search field has focus (the search field handles its own).
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

func roundedMask(radius: CGFloat) -> NSImage {
    let side = radius * 2 + 1
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

/// Has Alfred run the workflow's "paste" trigger, which presses ⌘V with Alfred's Accessibility
/// permission. Opened without activating Alfred, so the app you were in stays in front and gets it.
func askAlfredToPaste() {
    guard let url = URL(string: "alfred://runtrigger/com.andreisuslov.alfred-clipboard-history/paste/") else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.open(url, configuration: configuration)
}

/// Presses ⌘V in whatever app is in front.
func pressCommandV() {
    let source = CGEventSource(stateID: .combinedSessionState)
    for keyDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: keyDown)
        event?.flags = .maskCommand
        event?.post(tap: .cghidEventTap)
    }
}

final class Controller: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    enum Row {
        case header(String)
        case clip(Int)
    }

    static let size = NSSize(width: 768, height: 480)
    static let listWidth: CGFloat = 300
    static let searchHeight: CGFloat = 56
    static let footerHeight: CGFloat = 40

    let panel: Panel
    let root: Fill
    let search = NSTextField()
    let typeMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    let table = NSTableView()
    let detail: DetailView
    var footerView: NSView?
    var clips: [Clip] = []
    var loadedStamp = HistoryStamp()
    var loading = false
    var selectingFromCode = false
    var rows: [Row] = []
    var thumbnails: [String: NSImage] = [:]
    var target: NSRunningApplication?  // the app ↩ pastes into: whatever was in front when the window opened
    var dragWatch: Timer?

    override init() {
        let size = Controller.size
        let bodyTop = Controller.searchHeight + 1
        let bodyHeight = size.height - bodyTop - Controller.footerHeight - 1
        detail = DetailView(frame: NSRect(x: Controller.listWidth + 1, y: bodyTop,
                                          width: size.width - Controller.listWidth - 1, height: bodyHeight))
        panel = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        root = Fill(Theme.window, radius: 12, stroke: Theme.border, frame: blur.bounds)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true  // drag it by the search bar, footer or preview background
        panel.delegate = self
        panel.onCommandReturn = { [weak self] in self?.use(paste: false) }
        panel.onEscape = { [weak self] in self?.hide() }

        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = roundedMask(radius: 12)
        panel.contentView = blur
        blur.addSubview(root)

        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 18)
        search.textColor = Theme.text
        search.placeholderAttributedString = NSAttributedString(string: "Type to filter entries…", attributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: Theme.secondary,
        ])
        search.delegate = self
        search.frame = NSRect(x: 20, y: 16, width: size.width - 40 - 140, height: 24)
        root.addSubview(search)

        typeMenu.addItems(withTitles: Controller.types.map(\.title))
        typeMenu.isBordered = false
        typeMenu.font = .systemFont(ofSize: 13)
        typeMenu.contentTintColor = Theme.secondary
        typeMenu.target = self
        typeMenu.action = #selector(typeChanged)
        typeMenu.sizeToFit()
        typeMenu.frame = NSRect(x: size.width - 20 - typeMenu.frame.width, y: 16,
                                width: typeMenu.frame.width, height: 24)
        root.addSubview(typeMenu)

        root.addSubview(Fill(Theme.separator, frame: NSRect(x: 0, y: Controller.searchHeight, width: size.width, height: 1)))

        let column = NSTableColumn(identifier: .init("clip"))
        column.width = Controller.listWidth
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        // No .move: dropping a file in Finder must copy it, never take it out of the history.
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: bodyTop, width: Controller.listWidth, height: bodyHeight))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        root.addSubview(scroll)

        root.addSubview(Fill(Theme.separator, frame: NSRect(x: Controller.listWidth, y: bodyTop, width: 1, height: bodyHeight)))
        root.addSubview(detail)
        root.addSubview(Fill(Theme.separator, frame: NSRect(x: 0, y: size.height - Controller.footerHeight - 1,
                                                             width: size.width, height: 1)))

        // Pick up new copies while hidden, so the window opens with them already listed.
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, !self.panel.isVisible else { return }
            self.refreshIfChanged()
        }
    }

    /// Raycast's action bar: where you are on the left, the main keys on the right.
    func footer(width: CGFloat, y: CGFloat) -> NSView {
        let bar = Flipped(frame: NSRect(x: 0, y: y, width: width, height: Controller.footerHeight))
        let icon = NSImageView(image: symbol("doc.on.clipboard", size: 13) ?? NSImage())
        icon.contentTintColor = Theme.secondary
        icon.frame = NSRect(x: 18, y: 11, width: 18, height: 18)
        let title = label("Clipboard History", size: 12, weight: .medium, color: Theme.secondary)
        title.frame = NSRect(x: 42, y: 12, width: 200, height: 16)
        bar.addSubview(icon)
        bar.addSubview(title)

        var x = width - 18
        func place(_ view: NSView, gap: CGFloat = 4) {
            x -= view.frame.width
            view.frame.origin = NSPoint(x: x, y: (Controller.footerHeight - view.frame.height) / 2)
            bar.addSubview(view)
            x -= gap
        }
        func text(_ string: String) -> NSTextField {
            let field = label(string, size: 12, weight: .medium)
            field.sizeToFit()
            return field
        }
        place(keyCap("↩"))
        place(keyCap("⌘"))
        place(text("Copy"), gap: 12)
        place(Fill(Theme.separator, frame: NSRect(x: 0, y: 0, width: 1, height: 16)), gap: 12)
        place(keyCap("↩"))
        place(text(target?.localizedName.map { "Paste to \($0)" } ?? "Paste"))
        return bar
    }

    // MARK: Showing and hiding

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    /// The list is kept ready while the window is hidden, so showing it only has to put it on screen.
    func show() {
        // The app you were in, for "Paste to …" and for handing focus back; taken before this app activates.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != getpid() { target = front }
        refreshIfChanged()
        footerView?.removeFromSuperview()
        footerView = footer(width: Controller.size.width, y: Controller.size.height - Controller.footerHeight)
        root.addSubview(footerView!)

        panel.setFrameOrigin(origin())
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        // Become the active app, as Raycast does. A window of an inactive app keeps the keyboard only
        // until the active app (a browser updating its page, say) takes it back, which lost keystrokes.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(search)
        panel.invalidateShadow()
    }

    /// Closes the window and, unless you clicked into another app (which then has the keyboard
    /// already), hands focus back to the app you were in.
    func hide(returnFocus: Bool = true) {
        dragWatch?.invalidate()
        dragWatch = nil
        panel.orderOut(nil)
        if returnFocus, NSApp.isActive, let target {
            NSApp.yieldActivation(to: target)
            target.activate()
        }
        // Like Raycast, the next opening starts from an empty search at the newest item.
        DispatchQueue.main.async { [weak self] in self?.resetView() }
    }

    func resetView() {
        search.stringValue = ""
        typeMenu.selectItem(at: 0)
        reload()
    }

    /// Reloads only when Alfred has recorded or removed something since the last load. Loading and
    /// indexing thousands of clippings happens off the main thread, so the window never waits for it.
    func refreshIfChanged() {
        guard !loading else { return }
        let stamp = historyStamp()
        guard stamp != loadedStamp else { return }
        // Usually Alfred has only added a copy or two: load just those, right away (about a millisecond).
        if !clips.isEmpty, stamp.newest > loadedStamp.newest {
            let added = loadClips(newerThan: loadedStamp.newest)
            // Copying something again moves Alfred's item to the top, so its older entry goes.
            let kept = clips.filter { old in !added.contains { $0.isSameItem(as: old) } }
            if kept.count + added.count == stamp.count {
                clips = added + kept
                loadedStamp = stamp
                reload()
                return
            }
        }
        // Anything else (the first load, Alfred deleting items) reloads everything in the background.
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = loadClips()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clips = fresh
                self.loadedStamp = stamp
                self.loading = false
                self.reload()
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if dragWatch == nil { hide(returnFocus: false) }
    }

    // MARK: Position

    /// Where the window goes: where you last dragged it, or where Alfred's window appears
    /// (centered, its top about 36% down the screen). Remembered relative to the screen's top center.
    func origin() -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let frame = screen.frame
        let size = Controller.size
        let defaults = UserDefaults.standard
        let fromCenter = defaults.object(forKey: "offsetFromCenter") as? Double ?? -Double(size.width / 2)
        let fromTop = defaults.object(forKey: "offsetFromTop") as? Double ?? Double(frame.height * 0.36)
        let point = NSPoint(x: frame.midX + fromCenter, y: frame.maxY - fromTop - size.height)
        // A position saved on a bigger screen could leave it partly off this one.
        return screen.visibleFrame.contains(NSRect(origin: point, size: size))
            ? point : NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.36 - size.height)
    }

    func windowDidMove(_ notification: Notification) {
        guard panel.isVisible, let frame = panel.screen?.frame else { return }
        UserDefaults.standard.set(Double(panel.frame.minX - frame.midX), forKey: "offsetFromCenter")
        UserDefaults.standard.set(Double(frame.maxY - panel.frame.maxY), forKey: "offsetFromTop")
    }

    // MARK: Paste and copy

    func use(paste: Bool) {
        guard let clip = selectedClip else { return NSSound.beep() }
        clip.write(to: .general)
        hide()
        guard paste, let target else { return }
        whenFrontmost(target, then: askAlfredToPaste)
    }

    /// ⌘V has to reach the app you were in, so wait until it is back in front (a few milliseconds),
    /// giving up after half a second.
    func whenFrontmost(_ app: NSRunningApplication, then action: @escaping () -> Void, until deadline: Date = Date() + 0.5) {
        if NSWorkspace.shared.frontmostApplication == app || Date() > deadline { return action() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { self.whenFrontmost(app, then: action, until: deadline) }
    }

    @objc func doubleClicked() {
        if table.clickedRow >= 0 { use(paste: true) }
    }

    // MARK: Filtering

    /// The type menu, in order; Media is images and copied files.
    static let types: [(title: String, category: Clip.Category?)] = [
        ("All Types", nil), ("Text", .text), ("Links", .link), ("Code", .code), ("Media", .media), ("Colors", .color),
    ]

    func matches(_ clip: Clip, _ query: [UInt8], type: Int) -> Bool {
        if let category = Controller.types[type].category, clip.category != category { return false }
        guard !query.isEmpty else { return true }
        // A plain byte search over the pre-folded text: a few milliseconds for the whole history.
        return clip.searchKey.withUnsafeBytes { key in
            query.withUnsafeBytes { needle in
                memmem(key.baseAddress, key.count, needle.baseAddress, needle.count) != nil
            }
        }
    }

    func reload() {
        let query = Array(fold(search.stringValue.trimmingCharacters(in: .whitespaces)).utf8)
        let type = typeMenu.indexOfSelectedItem
        rows = []
        // Clips are newest first, so a new day starts only when a clip is older than the current day's start;
        // titles are formatted once per day rather than once per clip.
        var dayStart = Date.distantFuture
        for (index, clip) in clips.enumerated() where matches(clip, query, type: type) {
            if clip.date < dayStart {
                dayStart = Calendar.current.startOfDay(for: clip.date)
                rows.append(.header(dayTitle(clip.date)))
            }
            rows.append(.clip(index))
        }
        table.reloadData()
        select(rows.firstIndex { if case .clip = $0 { return true } else { return false } })
    }

    @objc func typeChanged() {
        reload()
        panel.makeFirstResponder(search)
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    // MARK: Selection

    var selectedClip: Clip? {
        guard table.selectedRow >= 0, case .clip(let index) = rows[table.selectedRow] else { return nil }
        return clips[index]
    }

    /// Selects a row from the keyboard or after filtering, and shows its preview once.
    func select(_ row: Int?) {
        selectingFromCode = true
        if let row {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            if case .header = rows[max(row - 1, 0)] { table.scrollRowToVisible(row - 1) }  // keep the day's title in view
        } else {
            table.deselectAll(nil)
        }
        selectingFromCode = false
        detail.show(selectedClip)
    }

    /// Moves the selection by `count` items, skipping day titles and stopping at either end.
    func move(by count: Int) {
        let step = count < 0 ? -1 : 1
        var row = table.selectedRow
        var moved = 0
        var candidate = row + step
        while rows.indices.contains(candidate), moved < abs(count) {
            if case .clip = rows[candidate] {
                row = candidate
                moved += 1
            }
            candidate += step
        }
        if row != table.selectedRow { select(row) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(by: 8)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(by: -8)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)): move(by: -rows.count)
        case #selector(NSResponder.moveToEndOfDocument(_:)): move(by: rows.count)
        // A text field sends Esc as complete: (autocompletion), not cancelOperation:.
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)): hide()
        case #selector(NSResponder.insertNewline(_:)): use(paste: true)
        default: return false
        }
        return true
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 26 }
        return 36
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .clip = rows[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selectingFromCode else { return }  // select(_:) shows the preview itself
        detail.show(selectedClip)
        // After a click, keep typing going to the search field, as in Raycast.
        if panel.firstResponder === table {
            panel.makeFirstResponder(search)
            search.currentEditor()?.selectedRange = NSRange(location: search.stringValue.utf16.count, length: 0)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = tableView.makeView(withIdentifier: .init("header"), owner: nil) as? HeaderCell ?? HeaderCell()
            cell.identifier = .init("header")
            cell.title.stringValue = title
            return cell
        case .clip(let index):
            let cell = tableView.makeView(withIdentifier: .init("clip"), owner: nil) as? ClipCell ?? ClipCell()
            cell.identifier = .init("clip")
            let clip = clips[index]
            cell.title.stringValue = clip.title
            cell.file = nil
            switch clip.kind {
            case .text:
                switch clip.category {
                case .color: cell.icon.image = swatch(clip.color!, side: 18, radius: 4)
                case .link: cell.icon.image = symbol("link", size: 14)
                case .code: cell.icon.image = symbol("chevron.left.forwardslash.chevron.right", size: 13)
                default: cell.icon.image = symbol("text.alignleft", size: 14)
                }
            case .image, .files:
                let file = clip.kind == .image ? clip.dataURL : clip.files.first
                cell.icon.image = file.flatMap { thumbnails[$0.path] }
                if let file, cell.icon.image == nil {
                    cell.file = file
                    thumbnail(of: file, side: 40) { [weak self, weak cell] image in
                        self?.thumbnails[file.path] = image
                        if cell?.file == file { cell?.icon.image = image }
                    }
                }
            }
            return cell
        }
    }

    // MARK: Dragging

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case .clip(let index) = rows[row] else { return nil }
        return clips[index].dragWriter
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        session.animatesToStartingPositionsOnCancelOrFail = false
        // Once the drag leaves the window, fade it out so whatever is underneath (a Finder window,
        // Dropover's shelf) can take the drop. The timer runs in .common so it ticks while dragging.
        let watch = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let outside = !NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false)
            self.panel.alphaValue = outside ? 0 : 1
            self.panel.ignoresMouseEvents = outside
        }
        RunLoop.main.add(watch, forMode: .common)
        dragWatch = watch
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragWatch?.invalidate()
        dragWatch = nil
        if operation.isEmpty && panel.isKeyWindow {
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
        } else {
            hide()
        }
    }
}

// MARK: - Hotkey

/// What ⌃⌘V does; a global so the Carbon callback (a C function) can reach it.
var hotKeyAction: () -> Void = {}

/// Registers ⌃⌘V in this app rather than in Alfred. The key press then reaches this process, which is
/// what lets macOS make it the active app with the keyboard; a request sent from a script is refused.
func registerHotKey() {
    var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        hotKeyAction()
        return noErr
    }, 1, &pressed, nil, nil)
    var hotKey: EventHotKeyRef?
    RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | cmdKey), EventHotKeyID(signature: 0x434C_4950, id: 1),
                        GetApplicationEventTarget(), 0, &hotKey)
}

/// An Edit menu, never shown (the app has no menu bar), so ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z work in the search
/// field: text fields get those shortcuts through the menu.
func editMenu() -> NSMenu {
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    item.submenu = edit
    let menu = NSMenu()
    menu.addItem(item)
    return menu
}

/// Keeps a LaunchAgent that starts the app in the background at login, pointing at wherever the
/// workflow is installed, so ⌃⌘V works right after logging in. Rewritten only when it differs.
func installLoginAgent() {
    let label = Bundle.main.bundleIdentifier ?? "com.andreisuslov.alfred-clipboard-history"
    let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    let file = agents.appendingPathComponent("\(label).plist")
    let agent: NSDictionary = [
        "Label": label,
        "ProgramArguments": ["/usr/bin/open", "-g", "-a", Bundle.main.bundlePath, "--args", "--login"],
        "RunAtLoad": true,
    ]
    if NSDictionary(contentsOf: file) == agent { return }
    try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    agent.write(to: file, atomically: true)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: Controller?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = editMenu()
        installLoginAgent()
        pruneImageLinks()
        controller = Controller()
        controller?.refreshIfChanged()
        hotKeyAction = { [weak self] in self?.controller?.toggle() }
        registerHotKey()
        // At login (the LaunchAgent passes --login) it only starts, ready for ⌃⌘V.
        if !CommandLine.arguments.contains("--login") { controller?.show() }
    }

    /// The workflow's keyword and Home entry run `open ClipHistory.app`. For an app that is already
    /// running, macOS activates it and asks it to reopen, which is when the window shows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.show()
        return false
    }
}

// `ClipHistory --paste` only presses ⌘V. The workflow's "paste" trigger runs it, so the key press
// comes from a process Alfred started and is covered by Alfred's Accessibility permission.
if CommandLine.arguments.contains("--paste") {
    pressCommandV()
    exit(0)
}

// Started through LaunchServices (`open`), so macOS keeps a single copy running.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
